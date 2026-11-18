# 설계 요구사항 검사입니다. AWS에 접속하지 않도록 mock provider로 plan만 만듭니다.
# 실행: cd envs/prod; terraform init -backend=false; terraform test
mock_provider "aws" {
  # 계정 ID와 AMI처럼 형식이 정해진 값만 흉내 냅니다.
  mock_data "aws_caller_identity" {
    defaults = { account_id = "000000000000" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-northeast-2", name = "ap-northeast-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-00000000000000000" }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "ap-northeast-2a" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::000000000000:role/mock" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:000000000000:loadbalancer/app/mock/0", arn_suffix = "app/mock/0" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = { arn = "arn:aws:acm:ap-northeast-2:000000000000:certificate/mock", domain_validation_options = [] }
  }
  mock_resource "aws_db_instance" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-northeast-2:000000000000:secret:mock", kms_key_id = "", secret_status = "active" }] }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ap-northeast-2:000000000000:log-group:mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:ap-northeast-2:000000000000:function:mock" }
  }
}

variables {
  domain_name = "example.com"
}

run "plan" {
  command = plan

  # 기본 정상 운영 EC2는 7대입니다: 일반 2 + 구매 2 + Kafka·Command DB·모니터링 3. (NAT 인스턴스는 별도)
  assert {
    condition     = module.general_pool.asg_name != "" && length(module.host) == 3
    error_message = "고정 역할 EC2는 Kafka·Command DB·모니터링 3대여야 합니다."
  }
  assert {
    condition     = var.general_min_size == 2 && var.purchase_min_size == 2
    error_message = "일반·구매 풀 기본 대수는 각각 2대여야 합니다."
  }
  assert {
    condition     = var.general_instance_type == "t4g.medium" && var.purchase_instance_type == "t4g.small"
    error_message = "일반 풀은 t4g.medium, 구매 풀은 t4g.small이어야 합니다."
  }
  assert {
    condition     = var.host_instance_types["kafka"] == "t4g.small" && var.host_instance_types["monitoring"] == "t4g.small"
    error_message = "Kafka·모니터링 EC2는 t4g.small이어야 합니다."
  }
  # 일반 풀 서비스 8개, 구매 풀 서비스 3개입니다.
  assert {
    condition     = length(var.general_services) == 8 && length(var.purchase_services) == 3
    error_message = "일반 풀 컨테이너 8개, 구매 풀 컨테이너 3개여야 합니다."
  }
  # 컨테이너 호스트 포트가 풀 안에서 겹치지 않아야 Eureka 등록 포트와 실제 포트가 같게 유지됩니다.
  assert {
    condition = (
      length(distinct([for s in var.general_services : s.port])) == length(var.general_services) &&
      length(distinct([for s in var.purchase_services : s.port])) == length(var.purchase_services)
    )
    error_message = "풀 안의 서비스 호스트 포트가 겹칩니다."
  }
  # 비용 때문에 RDS는 Single-AZ, Redis는 끈 상태로 시작합니다(2026-11 결정). 바꾸면 이 조건도 함께 바꿉니다.
  assert {
    condition     = !var.rds_multi_az && !var.enable_redis
    error_message = "기본값은 RDS Single-AZ, Redis 끔입니다."
  }
  assert {
    condition     = length(local.eureka_nodes) == 2
    error_message = "Eureka 고정 주소는 AZ마다 하나씩 2개여야 합니다."
  }
  # 고정 역할 EC2는 AZ1 app 서브넷에 둡니다(데이터 서브넷은 인터넷 경로가 없음).
  assert {
    condition     = alltrue([for k, h in local.hosts : startswith(h.ip, "10.20.10.")])
    error_message = "Kafka·Command DB·모니터링은 AZ1 app 서브넷(10.20.10.0/24)에 있어야 합니다."
  }
  assert {
    condition     = length(setintersection(toset(local.eureka_ips), toset([for h in local.hosts : h.ip]))) == 0
    error_message = "Eureka 고정 IP와 고정 역할 EC2 IP가 겹칩니다."
  }
}

run "data_subnet_is_isolated" {
  # mock provider의 apply는 AWS를 부르지 않고 가짜 ID만 만듭니다.
  command = apply

  module {
    source = "../../modules/network"
  }
  variables {
    name     = "test"
    vpc_cidr = "10.20.0.0/16"
    azs      = ["ap-northeast-2a", "ap-northeast-2c"]
  }

  assert {
    condition     = aws_route_table_association.data[0].route_table_id == aws_route_table.data.id
    error_message = "data 서브넷은 인터넷 경로가 없는 전용 라우팅 테이블을 써야 합니다."
  }
  assert {
    condition     = aws_route.private_nat.route_table_id != aws_route_table.data.id
    error_message = "NAT 기본 경로가 data 라우팅 테이블에 들어가면 안 됩니다."
  }
  assert {
    condition     = [for s in aws_subnet.data : s.cidr_block] == ["10.20.20.0/24", "10.20.21.0/24"]
    error_message = "data 서브넷 CIDR이 설계와 다릅니다."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "공개 서브넷도 자동 공인 IP를 주지 않아야 합니다(ALB·NAT만 둡니다)."
  }
  # NAT 인스턴스도 다른 EC2와 같은 기준: SSM 관리, IMDSv2, 암호화된 gp3 루트 디스크.
  assert {
    condition = (
      aws_instance.nat.iam_instance_profile == aws_iam_instance_profile.nat.name &&
      aws_instance.nat.metadata_options[0].http_tokens == "required" &&
      aws_instance.nat.root_block_device[0].encrypted &&
      aws_instance.nat.root_block_device[0].volume_type == "gp3"
    )
    error_message = "NAT 인스턴스는 SSM 역할, IMDSv2, 암호화 gp3 루트 디스크를 써야 합니다."
  }
}

run "redis_is_multi_az_with_tls" {
  command = apply

  module {
    source = "../../modules/redis"
  }
  variables {
    name              = "test"
    subnet_ids        = ["subnet-a", "subnet-c"]
    azs               = ["ap-northeast-2a", "ap-northeast-2c"]
    security_group_id = "sg-0"
  }

  assert {
    condition = (
      aws_elasticache_replication_group.this.num_cache_clusters == 2 &&
      aws_elasticache_replication_group.this.multi_az_enabled &&
      aws_elasticache_replication_group.this.automatic_failover_enabled &&
      aws_elasticache_replication_group.this.transit_encryption_enabled
    )
    error_message = "Redis는 Primary+Replica, Multi-AZ, 자동 장애 전환, TLS여야 합니다."
  }
  assert {
    condition     = aws_elasticache_user.default.access_string == "off -@all"
    error_message = "default 사용자는 꺼져 있어야 합니다."
  }
}
