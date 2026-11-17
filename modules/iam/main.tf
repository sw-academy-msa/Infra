# EC2 역할별 권한입니다. 장기 AWS 키를 서버에 두지 않고 인스턴스 역할로만 접근하며, AdministratorAccess는 쓰지 않습니다.
# 역할: general(일반 풀), purchase(구매 풀), command-db, kafka, monitoring.
# 리소스로 좁힐 수 없는 API(ecr:GetAuthorizationToken, ec2:Describe*)만 "*"를 쓰고, 나머지는 ARN으로 제한합니다.
variable "name" {
  description = "자원 이름 앞에 붙는 접두사입니다."
  type        = string
}

variable "parameter_path" {
  description = "서비스가 읽을 SSM Parameter Store 경로입니다. 예: /stockdrop/prod"
  type        = string
}

variable "ecr_repository_arns" {
  description = "서비스 EC2가 이미지를 받을 ECR 저장소입니다."
  type        = list(string)
}

variable "eureka_eni_arns" {
  description = "일반 풀 서버가 부팅 때 스스로 붙이는 Eureka 고정 IP ENI입니다."
  type        = list(string)
}

variable "bucket_arns" {
  description = "S3 모듈의 버킷 키별 ARN입니다(seller-certificates, product-images, inquiry-images, command-db-backups)."
  type        = map(string)
}

variable "rds_master_secret_arn" {
  description = "RDS 마스터 비밀번호 Secret입니다. 모니터링 EC2가 RDS DB·계정 초기화 때만 읽습니다."
  type        = string
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  arn_prefix = "arn:${data.aws_partition.current.partition}"
  account    = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  parameter  = "${local.arn_prefix}:ssm:${local.region}:${local.account}:parameter${var.parameter_path}"
  roles = {
    general    = "General pool service instances"
    purchase   = "Purchase pool service instances"
    command-db = "Command PostgreSQL instance"
    kafka      = "Kafka broker instance"
    monitoring = "Prometheus and Grafana instance"
  }
  # 풀별로 읽고 쓰는 서비스 버킷입니다. 판매자 증빙은 Account(일반), 문의 이미지는 OrderCommand(구매)만 씁니다.
  pool_buckets = {
    general  = ["seller-certificates", "product-images"]
    purchase = ["product-images", "inquiry-images"]
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each           = local.roles
  name               = "${var.name}-${each.key}"
  description        = each.value
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# 모든 EC2는 SSH 키 없이 Session Manager로 접속합니다.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each   = aws_iam_role.this
  role       = each.value.name
  policy_arn = "${local.arn_prefix}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  for_each = aws_iam_role.this
  name     = each.value.name
  role     = each.value.name
}

# ---------- 서비스 풀(general, purchase) ----------
data "aws_iam_policy_document" "pool" {
  for_each = local.pool_buckets

  # 한 서버에 여러 서비스가 함께 뜨므로 환경 경로 전체를 읽습니다. 서비스 간 분리는 앱 계정·인증이 맡습니다.
  statement {
    sid       = "ReadParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.parameter, "${local.parameter}/*"]
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = var.ecr_repository_arns
  }
  # 자기 풀 ASG의 lifecycle hook만 완료합니다.
  statement {
    sid       = "CompleteLifecycle"
    actions   = ["autoscaling:CompleteLifecycleAction"]
    resources = ["${local.arn_prefix}:autoscaling:${local.region}:${local.account}:autoScalingGroup:*:autoScalingGroupName/${var.name}-${each.key}"]
  }
  # 버킷 확인(HeadBucket)과 없는 파일을 404로 받으려면 ListBucket이 필요합니다. presigned URL도 이 범위 안에서만 동작합니다.
  statement {
    sid       = "ServiceBuckets"
    actions   = ["s3:ListBucket"]
    resources = [for k in each.value : var.bucket_arns[k]]
  }
  statement {
    sid       = "ServiceObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for k in each.value : "${var.bucket_arns[k]}/*"]
  }

  # 일반 풀만 정해진 Eureka ENI를 STOCKDROP 인스턴스에 붙일 수 있습니다.
  dynamic "statement" {
    for_each = each.key == "general" ? [1] : []
    content {
      sid       = "AttachEurekaEni"
      actions   = ["ec2:AttachNetworkInterface"]
      resources = var.eureka_eni_arns
    }
  }
  dynamic "statement" {
    for_each = each.key == "general" ? [1] : []
    content {
      sid       = "AttachToProjectInstances"
      actions   = ["ec2:AttachNetworkInterface"]
      resources = ["${local.arn_prefix}:ec2:${local.region}:${local.account}:instance/*"]
      condition {
        test     = "StringEquals"
        variable = "aws:ResourceTag/Project"
        values   = ["STOCKDROP"]
      }
    }
  }
}

resource "aws_iam_role_policy" "pool" {
  for_each = local.pool_buckets
  name     = "${each.key}-runtime"
  role     = aws_iam_role.this[each.key].name
  policy   = data.aws_iam_policy_document.pool[each.key].json
}

# ---------- Command DB: 자기 계정 비밀번호 읽기, 백업 버킷 쓰기 ----------
data "aws_iam_policy_document" "command_db" {
  statement {
    sid     = "ReadDbPasswords"
    actions = ["ssm:GetParameter"]
    resources = [
      "${local.parameter}/command-db/*",
      "${local.parameter}/product-command-service/DB_PASSWORD",
      "${local.parameter}/order-command-service/DB_PASSWORD",
    ]
  }
  statement {
    sid       = "BackupBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arns["command-db-backups"]]
  }
  # 백업 올리기와 복원용 내려받기만 합니다. 지우기는 수명 주기 정책이 합니다.
  statement {
    sid       = "BackupObjects"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${var.bucket_arns["command-db-backups"]}/*"]
  }
}

resource "aws_iam_role_policy" "command_db" {
  name   = "command-db-runtime"
  role   = aws_iam_role.this["command-db"].name
  policy = data.aws_iam_policy_document.command_db.json
}

# Kafka EC2는 SSM 접속(ssm_core) 외에 AWS 권한이 필요 없습니다. 이미지는 공개 레지스트리에서 NAT로 받습니다.

# ---------- 모니터링 ----------
data "aws_iam_policy_document" "monitoring" {
  # Prometheus EC2 서비스 탐색과 CloudWatch 지표 읽기는 리소스로 좁힐 수 없습니다.
  statement {
    sid       = "DiscoverInstances"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
    resources = ["*"]
  }
  statement {
    sid       = "ReadCloudWatchMetrics"
    actions   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics", "tag:GetResources"]
    resources = ["*"]
  }
  # 수집 토큰·Grafana 비밀번호, 그리고 RDS 초기화 때 서비스별 DB 비밀번호를 읽습니다.
  statement {
    sid     = "ReadParameters"
    actions = ["ssm:GetParameter"]
    resources = [
      "${local.parameter}/shared/MONITORING_SCRAPE_TOKEN",
      "${local.parameter}/monitoring/*",
      "${local.parameter}/*/DB_PASSWORD",
    ]
  }
  statement {
    sid       = "ReadRdsMasterSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.rds_master_secret_arn]
  }
}

resource "aws_iam_role_policy" "monitoring" {
  name   = "monitoring-runtime"
  role   = aws_iam_role.this["monitoring"].name
  policy = data.aws_iam_policy_document.monitoring.json
}

output "instance_profile_names" {
  description = "역할별 EC2 인스턴스 프로필 이름입니다."
  value       = { for k, p in aws_iam_instance_profile.this : k => p.name }
}

output "role_arns" {
  value = { for k, r in aws_iam_role.this : k => r.arn }
}
