# 일반 DB용 RDS PostgreSQL입니다. account, payment, ai, notification, product_query, orders_query DB를 한 인스턴스에 둡니다.
# 서비스별 DB와 계정은 Terraform이 아니라 최초 1회 SQL로 만듭니다. RDS가 사설망에만 있어 이 PC에서 직접 접속할 수 없기 때문입니다.
variable "name" {
  type = string
}

variable "subnet_ids" {
  description = "RDS를 둘 data 서브넷입니다. 서로 다른 AZ 2개 이상이 필요합니다."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "instance_class" {
  description = "RDS 사양입니다. k6 결과를 보고 조정합니다."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "초기 저장 용량(GB)입니다. max_allocated_storage까지 자동으로 늘어납니다."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  type    = number
  default = 100
}

variable "engine_version" {
  description = "로컬 테스트와 같은 PostgreSQL 17 계열을 사용합니다."
  type        = string
  default     = "17"
}

variable "multi_az" {
  description = "true면 다른 AZ에 동기 대기 DB를 두어 장애 때 자동 전환합니다. 대기 DB는 읽기용이 아닙니다. 비용이 약 2배입니다."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "log_retention_days" {
  description = "CloudWatch로 내보낸 PostgreSQL 로그 보관 기간입니다."
  type        = number
  default     = 14
}

locals {
  identifier = "${var.name}-general"
  # engine_version의 주 버전으로 Parameter Group 계열을 정합니다. 예: 17 → postgres17
  family = "postgres${split(".", var.engine_version)[0]}"
}

# 기본값에서 운영 확인에 필요한 로그만 켭니다. 정적 파라미터가 없어 재부팅 없이 적용됩니다.
resource "aws_db_parameter_group" "this" {
  name   = local.identifier
  family = local.family

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # 1초 넘는 쿼리를 기록합니다.
  }
  parameter {
    name  = "log_lock_waits"
    value = "1"
  }
  parameter {
    name  = "rds.force_ssl"
    value = "1" # 서비스 JDBC는 TLS로만 접속합니다.
    # AWS가 이 값을 pending-reboot로 저장해 같게 맞춥니다. 다르면 plan마다 변경이 반복됩니다.
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# RDS가 로그 그룹을 직접 만들면 보관 기간이 무제한이므로 먼저 만들어 둡니다.
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/${local.identifier}/postgresql"
  retention_in_days = var.log_retention_days
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-general"
  subnet_ids = var.subnet_ids
  tags       = { Name = "${var.name}-general" }
}

resource "aws_db_instance" "this" {
  identifier     = local.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "stockdrop"
  username = "stockdrop_admin"
  # 마스터 비밀번호는 RDS가 Secrets Manager에 만들고 교체합니다. Terraform 상태 파일에 비밀번호가 남지 않습니다.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = var.multi_az
  parameter_group_name   = aws_db_parameter_group.this.name

  enabled_cloudwatch_logs_exports = ["postgresql"]

  backup_retention_period = var.backup_retention_days
  backup_window           = "18:00-19:00"
  maintenance_window      = "sun:19:00-sun:20:00"
  copy_tags_to_snapshot   = true

  # 운영 데이터를 실수로 지우지 않도록 삭제 보호와 마지막 스냅샷을 켭니다.
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-general-final"

  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags       = { Name = "${var.name}-general" }
  depends_on = [aws_cloudwatch_log_group.postgresql]
}

output "identifier" {
  description = "CloudWatch RDS 지표의 DBInstanceIdentifier 차원 값입니다."
  value       = aws_db_instance.this.identifier
}

output "endpoint" {
  description = "서비스 DB_URL의 호스트 부분입니다. 예: jdbc:postgresql://<address>:5432/payment"
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "master_secret_arn" {
  description = "마스터 비밀번호가 저장된 Secrets Manager ARN입니다. 최초 DB·계정 생성에만 사용합니다."
  value       = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
}
