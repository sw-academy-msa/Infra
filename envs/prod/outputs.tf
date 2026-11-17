output "vpc_id" {
  value = module.network.vpc_id
}

output "subnets" {
  value = {
    public = module.network.public_subnet_ids
    app    = module.network.app_subnet_ids
    data   = module.network.data_subnet_ids
  }
}

output "nat_public_ip" {
  description = "외부 서비스에 허용 IP를 등록해야 할 때 사용하는 출구 IP입니다."
  value       = module.network.nat_public_ip
}

output "security_groups" {
  value = {
    alb        = module.security.alb_sg_id
    app        = module.security.app_sg_id
    purchase   = module.security.purchase_sg_id
    rds        = module.security.rds_sg_id
    command_db = module.security.command_db_sg_id
    kafka      = module.security.kafka_sg_id
    monitoring = module.security.monitoring_sg_id
  }
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "s3_buckets" {
  description = "SSM 설정값 SELLER_CERTIFICATE_BUCKET, PRODUCT_IMAGES_BUCKET, QUERY_IMAGES_BUCKET, ORDER_IMAGES_BUCKET에 넣을 버킷 이름입니다."
  value       = module.s3.bucket_names
}

output "instance_profiles" {
  value = module.iam.instance_profile_names
}

output "rds" {
  value = {
    endpoint          = module.rds.endpoint
    master_secret_arn = module.rds.master_secret_arn
  }
}

output "hosts" {
  description = "Command DB, Kafka, 모니터링 EC2의 내부 DNS 이름, 고정 사설 IP, SSM 접속용 인스턴스 ID입니다."
  value = { for k, h in module.host : k => {
    dns         = local.host_dns[k]
    private_ip  = h.private_ip
    instance_id = h.instance_id
  } }
}

output "alb_dns_name" {
  value = module.alb.dns_name
}

output "alb_target_groups" {
  value = module.alb.target_group_arns
}

output "public_name_servers" {
  description = "도메인 등록업체(가비아)의 네임서버에 넣을 값입니다. 바꾸는 순간 기존 DNS(Cloudflare) 레코드는 더 이상 쓰이지 않습니다."
  value       = local.public_name_servers
}

output "public_zone_id" {
  value = local.public_zone_id
}

output "eureka_ips" {
  description = "Eureka 고정 IP입니다. 서비스에는 부팅 스크립트가 EUREKA_DEFAULT_ZONE으로 넣습니다."
  value       = local.eureka_ips
}

output "asg_names" {
  value = {
    general  = module.general_pool.asg_name
    purchase = module.purchase_pool.asg_name
  }
}
