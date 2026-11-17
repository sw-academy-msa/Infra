# ElastiCache Redis OSS 캐시입니다. 재고 원본이 아니며 Command DB가 최종 기준입니다.
# Primary 1 + Replica 1을 서로 다른 AZ에 두고 Primary 장애 때 자동으로 승격합니다.
# 인증은 사용자 그룹(RBAC)입니다. Terraform은 기본 사용자를 막아 둔 그룹만 만들고, 비밀번호가 있는 앱 사용자는
# scripts/redis-app-user.ps1이 SSM 값으로 만들어 그룹에 넣습니다. 그래서 비밀번호가 Terraform 상태에 남지 않습니다.
variable "name" {
  type = string
}

variable "subnet_ids" {
  description = "Redis를 둘 data 서브넷입니다. 서로 다른 AZ 2개가 필요합니다."
  type        = list(string)
}

variable "azs" {
  description = "Primary와 Replica를 둘 AZ 순서입니다. 첫 번째가 처음 Primary입니다."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "engine_version" {
  description = "Redis OSS 버전입니다. 7.1이 ElastiCache의 마지막 Redis OSS 계열입니다."
  type        = string
  default     = "7.1"
}

variable "node_type" {
  description = "노드 사양입니다. 캐시 사용량을 본 뒤 조정합니다."
  type        = string
  default     = "cache.t4g.micro"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

locals {
  id = "${var.name}-cache"
}

resource "aws_elasticache_subnet_group" "this" {
  name       = local.id
  subnet_ids = var.subnet_ids
}

# 그룹에는 default 사용자가 반드시 있어야 합니다. 비밀번호 없이 접속해도 아무 명령도 못 하게 꺼 둡니다.
resource "aws_elasticache_user" "default" {
  user_id       = "${local.id}-default"
  user_name     = "default"
  engine        = "redis"
  access_string = "off -@all"

  authentication_mode {
    type = "no-password-required"
  }
}

resource "aws_elasticache_user_group" "this" {
  user_group_id = local.id
  engine        = "redis"
  user_ids      = [aws_elasticache_user.default.user_id]

  # 앱 사용자는 스크립트가 추가합니다. 다음 apply가 그 사용자를 빼지 않도록 목록 변경은 무시합니다.
  lifecycle {
    ignore_changes = [user_ids]
  }
}

resource "aws_cloudwatch_log_group" "slow" {
  name              = "/aws/elasticache/${local.id}/slow-log"
  retention_in_days = var.log_retention_days
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.id
  description          = "STOCKDROP cache"
  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  port                 = 6379

  # 클러스터 모드를 쓰지 않는 Primary 1 + Replica 1 구성입니다.
  num_cache_clusters          = 2
  preferred_cache_cluster_azs = slice(var.azs, 0, 2)
  automatic_failover_enabled  = true
  multi_az_enabled            = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.security_group_id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  user_group_ids             = [aws_elasticache_user_group.this.user_group_id]

  snapshot_retention_limit   = 1
  snapshot_window            = "17:00-18:00"
  maintenance_window         = "sun:19:00-sun:20:00"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.slow.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }
}

output "primary_endpoint" {
  description = "쓰기·읽기용 주소입니다. 장애 전환 후에도 같은 이름이 새 Primary를 가리킵니다."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint" {
  value = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "user_group_id" {
  value = aws_elasticache_user_group.this.user_group_id
}

output "replication_group_id" {
  description = "CloudWatch ElastiCache 지표의 ReplicationGroupId 차원 값입니다."
  value       = aws_elasticache_replication_group.this.id
}
