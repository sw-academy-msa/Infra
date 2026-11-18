variable "region" {
  description = "배포 리전입니다."
  type        = string
  default     = "ap-northeast-2"
}

variable "name" {
  description = "자원 이름 앞에 붙는 접두사입니다."
  type        = string
  default     = "stockdrop-prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  description = "ALB와 RDS가 요구하는 최소 2개 가용 영역입니다."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "alb_ingress_cidrs" {
  description = "ALB에 접근을 허용할 주소입니다."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "parameter_path" {
  description = "서비스 비밀값을 둘 SSM Parameter Store 경로입니다."
  type        = string
  default     = "/stockdrop/prod"
}

variable "domain_name" {
  description = "루트 도메인입니다. api.<도메인>, pay.<도메인> 인증서를 발급합니다."
  type        = string
}

variable "hosted_zone_id" {
  description = "이미 있는 Route 53 공개 Hosted Zone ID입니다. 비워 두면 domain_name으로 새로 만듭니다."
  type        = string
  default     = ""
}

variable "internal_domain" {
  description = "VPC 안에서만 쓰는 내부 DNS 이름입니다. 예: kafka.stockdrop.internal"
  type        = string
  default     = "stockdrop.internal"
}

variable "browser_origins" {
  description = "이미지 버킷 CORS에 허용할 프론트 주소입니다. presigned URL 업로드·열람에 씁니다."
  type        = list(string)
  default     = ["https://stockdrop-app.vercel.app", "http://localhost:5173"]
}

variable "enable_https" {
  description = "도메인 네임서버를 Route 53(public_name_servers)으로 바꾼 뒤 true로 바꿉니다."
  type        = bool
  default     = false
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "rds_multi_az" {
  description = "다른 AZ에 동기 대기 DB를 두고 장애 때 자동 전환합니다. 대기 DB는 읽기용이 아닙니다. 비용이 약 2배라 기본은 끕니다(장애 시 수동 복구)."
  type        = bool
  default     = false
}

variable "host_instance_types" {
  description = "단일 EC2 역할별 사양입니다. Kafka는 JVM 힙 때문에 small 이상을 권장합니다."
  type        = map(string)
  default = {
    command-db = "t4g.small"
    kafka      = "t4g.small"
    monitoring = "t4g.small"
  }
}

variable "command_db_volume_size" {
  type    = number
  default = 20
}

variable "kafka_volume_size" {
  type    = number
  default = 20
}

variable "monitoring_volume_size" {
  description = "Prometheus 15일·10GB 보존 상한보다 여유 있게 잡습니다."
  type        = number
  default     = 20
}

variable "general_instance_type" {
  description = "일반 풀 서버 사양입니다. JVM 8개(Eureka 포함)가 함께 뜹니다."
  type        = string
  default     = "t4g.medium"
}

variable "purchase_instance_type" {
  type    = string
  default = "t4g.small"
}

# 증설 상한입니다. 비용이 갑자기 커지지 않도록 기본은 평소 2대 + 일반 1대, 구매 2대까지만 늘립니다.
# 선착순 시작 시각에는 CPU 증설이 늦을 수 있어, 큰 행사 전에는 desired를 미리 올리는 것을 권장합니다(docs/operations.md).
variable "general_min_size" {
  type    = number
  default = 2
}

variable "general_max_size" {
  type    = number
  default = 3
}

variable "purchase_min_size" {
  type    = number
  default = 2
}

variable "purchase_max_size" {
  type    = number
  default = 4
}

variable "cpu_target_percent" {
  description = "두 풀 공통 CPU 목표값입니다. t4g는 CPU 크레딧을 쓰므로 너무 높게 잡지 않습니다."
  type        = number
  default     = 60
}

# 컨테이너 메모리 상한(MB)입니다. 각 이미지는 이 값의 75%를 JVM 힙으로 씁니다. k6 결과를 보고 조정합니다.
variable "general_services" {
  type = list(object({ name = string, port = number, memory_mb = number }))
  default = [
    { name = "eureka", port = 8761, memory_mb = 256 },
    { name = "gateway", port = 8000, memory_mb = 384 },
    { name = "account-service", port = 8080, memory_mb = 512 },
    { name = "product-query-service", port = 8082, memory_mb = 448 },
    { name = "order-query-service", port = 8085, memory_mb = 448 },
    { name = "payment-service", port = 8084, memory_mb = 448 },
    { name = "ai-service", port = 8086, memory_mb = 512 },
    { name = "notification-service", port = 8087, memory_mb = 448 },
  ]
}

variable "purchase_services" {
  type = list(object({ name = string, port = number, memory_mb = number }))
  default = [
    { name = "purchase-gateway", port = 8001, memory_mb = 384 },
    { name = "order-command-service", port = 8083, memory_mb = 640 },
    { name = "product-command-service", port = 8081, memory_mb = 640 },
  ]
}

variable "enable_redis" {
  description = "ElastiCache Redis를 만듭니다. 아직 Redis를 쓰는 서비스가 없어 기본은 끕니다. 캐시를 붙일 때 true로 바꿉니다."
  type        = bool
  default     = false
}

variable "redis_node_type" {
  description = "ElastiCache 노드 사양입니다. Primary와 Replica 2대에 같은 사양이 들어갑니다."
  type        = string
  default     = "cache.t4g.micro"
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

variable "alert_emails" {
  description = "CloudWatch 알람을 받을 이메일입니다. 적용 후 각 주소로 온 확인 메일을 승인해야 받습니다. 비워 두면 구독을 만들지 않습니다."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "Terraform이 만드는 CloudWatch 로그 그룹(Lambda, Redis 등)의 보관 기간입니다."
  type        = number
  default     = 14
}
