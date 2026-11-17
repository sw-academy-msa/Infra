# 1단계 기반 인프라입니다. RDS·ALB·EC2 ASG는 다음 단계에서 이 출력값을 사용해 추가합니다.
locals {
  # Monitoring은 공개 이미지만 쓰므로 저장소를 만들지 않습니다.
  services = [
    "account-service",
    "product-command-service",
    "product-query-service",
    "order-command-service",
    "order-query-service",
    "payment-service",
    "ai-service",
    "notification-service",
    "gateway",
    "purchase-gateway",
    "eureka",
  ]
}

module "network" {
  source   = "../../modules/network"
  name     = var.name
  vpc_cidr = var.vpc_cidr
  azs      = var.azs
}

module "security" {
  source            = "../../modules/security"
  name              = var.name
  vpc_id            = module.network.vpc_id
  alb_ingress_cidrs = var.alb_ingress_cidrs
}

module "ecr" {
  source       = "../../modules/ecr"
  name         = "stockdrop"
  repositories = local.services
}

module "s3" {
  source          = "../../modules/s3"
  name            = var.name
  browser_origins = var.browser_origins
}

module "iam" {
  source                = "../../modules/iam"
  name                  = var.name
  parameter_path        = var.parameter_path
  ecr_repository_arns   = module.ecr.repository_arns
  eureka_eni_arns       = [for e in aws_network_interface.eureka : e.arn]
  bucket_arns           = module.s3.bucket_arn_map
  rds_master_secret_arn = module.rds.master_secret_arn
}

# ---------- 2단계: 데이터 계층과 입구 ----------
module "rds" {
  source            = "../../modules/rds"
  name              = var.name
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.security.rds_sg_id
  instance_class    = var.rds_instance_class
  multi_az          = var.rds_multi_az
}

# 고정 역할 EC2는 AZ1 app 서브넷에 둡니다. data 서브넷은 인터넷 경로가 없어 이미지를 받을 수 없기 때문입니다.
# 서비스 설정에는 IP가 아니라 내부 DNS 이름(<역할>.<internal_domain>)을 넣습니다. IP 고정은 EC2를 다시 만들어도
# 같은 주소를 쓰기 위한 것이며, .10은 Eureka 고정 ENI가 씁니다.
locals {
  host_cidr = module.network.app_subnet_cidrs[0]
  hosts = {
    command-db = { ip = cidrhost(local.host_cidr, 20), sg = module.security.command_db_sg_id, profile = "command-db", size = var.command_db_volume_size }
    kafka      = { ip = cidrhost(local.host_cidr, 30), sg = module.security.kafka_sg_id, profile = "kafka", size = var.kafka_volume_size }
    monitoring = { ip = cidrhost(local.host_cidr, 40), sg = module.security.monitoring_sg_id, profile = "monitoring", size = var.monitoring_volume_size }
  }
  host_dns = { for k, _ in local.hosts : k => "${k}.${var.internal_domain}" }
}

module "host" {
  source             = "../../modules/host"
  for_each           = local.hosts
  name               = var.name
  role               = each.key
  instance_type      = var.host_instance_types[each.key]
  subnet_id          = module.network.app_subnet_ids[0]
  private_ip         = each.value.ip
  security_group_ids = [each.value.sg]
  instance_profile   = module.iam.instance_profile_names[each.value.profile]
  data_volume_size   = each.value.size
}

module "alb" {
  source            = "../../modules/alb"
  name              = var.name
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.public_subnet_ids
  security_group_id = module.security.alb_sg_id
  domain_name       = var.domain_name
  zone_id           = local.public_zone_id
  enable_https      = var.enable_https
}


# ---------- 3단계: 서비스 서버 풀 ----------
data "aws_caller_identity" "current" {}

locals {
  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  kafka    = "${local.host_dns.kafka}:9092"
  # Eureka 주소 관리: AZ마다 고정 IP ENI를 하나씩 두고, 그 AZ의 일반 풀 서버가 부팅 때 붙입니다.
  # 서버가 바뀌어도 IP와 내부 DNS(eureka-<AZ>)가 그대로라 DNS를 고치거나 지울 일이 없습니다.
  # 남은 ENI가 없는 증설 서버(3번째부터)는 Eureka 없이 나머지 서비스만 띄웁니다.
  eureka_nodes = {
    for i, az in var.azs : substr(az, -1, 1) => {
      az        = az
      subnet_id = module.network.app_subnet_ids[i]
      ip        = cidrhost(module.network.app_subnet_cidrs[i], 10)
      host      = "eureka-${substr(az, -1, 1)}.${var.internal_domain}"
    }
  }
  eureka_ips   = [for n in values(local.eureka_nodes) : n.ip]
  eureka_hosts = [for n in values(local.eureka_nodes) : n.host]
}

resource "aws_network_interface" "eureka" {
  for_each        = local.eureka_nodes
  subnet_id       = each.value.subnet_id
  private_ips     = [each.value.ip]
  security_groups = [module.security.app_sg_id]
  description     = "Eureka fixed address ${each.key}"
  tags            = { Name = "${var.name}-eureka-${each.key}", Role = "eureka" }
}

resource "aws_route53_record" "eureka" {
  for_each = local.eureka_nodes
  zone_id  = aws_route53_zone.internal.zone_id
  name     = each.value.host
  type     = "A"
  ttl      = 60
  records  = [each.value.ip]
}

# 일반 풀: 두 AZ에 걸친 ASG 하나입니다. 서버마다 Gateway·Eureka·업무 서비스 6개를 함께 띄웁니다.
module "general_pool" {
  source             = "../../modules/pool"
  name               = var.name
  pool               = "general"
  subnet_ids         = module.network.app_subnet_ids
  instance_type      = var.general_instance_type
  security_group_ids = [module.security.app_sg_id]
  instance_profile   = module.iam.instance_profile_names["general"]
  target_group_arns  = [module.alb.target_group_arns["general"]]
  min_size           = var.general_min_size
  desired_capacity   = var.general_min_size
  max_size           = var.general_max_size
  cpu_target_percent = var.cpu_target_percent
  services           = var.general_services
  gateway_service    = "gateway"
  region             = var.region
  parameter_path     = var.parameter_path
  registry           = local.registry
  eureka_ips         = local.eureka_ips
  eureka_hosts       = local.eureka_hosts
  eureka_enis = [for k, n in local.eureka_nodes : {
    id = aws_network_interface.eureka[k].id
    az = n.az
    ip = n.ip
  }]
  kafka_bootstrap_servers = local.kafka
}

# 구매 풀: 두 AZ에 걸친 ASG 하나입니다. Command DB 접근용 그룹을 추가로 붙입니다.
module "purchase_pool" {
  source                  = "../../modules/pool"
  name                    = var.name
  pool                    = "purchase"
  subnet_ids              = module.network.app_subnet_ids
  instance_type           = var.purchase_instance_type
  security_group_ids      = [module.security.app_sg_id, module.security.purchase_sg_id]
  instance_profile        = module.iam.instance_profile_names["purchase"]
  target_group_arns       = [module.alb.target_group_arns["purchase"]]
  min_size                = var.purchase_min_size
  desired_capacity        = var.purchase_min_size
  max_size                = var.purchase_max_size
  cpu_target_percent      = var.cpu_target_percent
  services                = var.purchase_services
  gateway_service         = "purchase-gateway"
  region                  = var.region
  parameter_path          = var.parameter_path
  registry                = local.registry
  eureka_ips              = local.eureka_ips
  eureka_hosts            = local.eureka_hosts
  kafka_bootstrap_servers = local.kafka
}
