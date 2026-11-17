# 서비스가 쓰는 S3 버킷입니다. 모두 비공개이며 브라우저는 서비스가 발급한 presigned URL로만 접근합니다.
# 상품·문의 이미지 버킷만 브라우저 업로드용 CORS를 열고, 판매자 증빙 버킷은 서버만 접근합니다.
variable "name" {
  description = "버킷 이름 앞에 붙는 접두사입니다. 계정 ID를 뒤에 붙여 전역에서 겹치지 않게 합니다."
  type        = string
}

variable "browser_origins" {
  description = "presigned URL로 이미지를 올리고 받는 프론트 주소입니다."
  type        = list(string)
}

variable "noncurrent_version_days" {
  description = "덮어쓰거나 지운 이전 버전을 보관하는 일수입니다."
  type        = number
  default     = 30
}

variable "upload_expiration_days" {
  description = "확정되지 않은 임시 업로드를 지우는 일수입니다. 서비스 정리 작업(24시간)이 놓친 파일을 치웁니다."
  type        = number
  default     = 2
}

variable "backup_retention_days" {
  description = "Command DB 백업 파일을 보관하는 일수입니다. 지난 백업은 자동으로 지웁니다."
  type        = number
  default     = 30
}

data "aws_caller_identity" "current" {}

locals {
  # upload_prefix: 브라우저가 올린 뒤 서비스가 확정 경로로 복사하는 임시 경로입니다.
  buckets = {
    seller-certificates = { cors = false, upload_prefix = null, expire_days = null }
    product-images      = { cors = true, upload_prefix = "product-uploads/", expire_days = null }
    inquiry-images      = { cors = true, upload_prefix = "order-inquiry-uploads/", expire_days = null }
    # Command DB pg_dump 백업입니다. 서버만 쓰며 보관 기간이 지나면 지웁니다. 이 버킷은 앱이 쓰지 않습니다.
    command-db-backups = { cors = false, upload_prefix = null, expire_days = var.backup_retention_days }
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets
  bucket   = "${var.name}-${each.key}-${data.aws_caller_identity.current.account_id}"
  tags     = { Purpose = each.key }

  # 판매자 증빙과 이미지 원본이 들어 있어 Terraform에서 실수로 지우지 않도록 막습니다.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACL을 쓰지 않고 버킷 정책과 IAM으로만 권한을 관리합니다.
resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 잘못 덮어쓰거나 지운 파일을 이전 버전에서 되살릴 수 있게 합니다.
resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  rule {
    id     = "cleanup"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
    expiration {
      expired_object_delete_marker = true
    }
  }

  dynamic "rule" {
    for_each = local.buckets[each.key].upload_prefix == null ? [] : [local.buckets[each.key].upload_prefix]
    content {
      id     = "expire-uploads"
      status = "Enabled"
      filter {
        prefix = rule.value
      }
      expiration {
        days = var.upload_expiration_days
      }
    }
  }

  dynamic "rule" {
    for_each = local.buckets[each.key].expire_days == null ? [] : [local.buckets[each.key].expire_days]
    content {
      id     = "expire-backups"
      status = "Enabled"
      filter {}
      expiration {
        days = rule.value
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_cors_configuration" "this" {
  for_each = { for k, b in aws_s3_bucket.this : k => b if local.buckets[k].cors }
  bucket   = each.value.id
  cors_rule {
    allowed_origins = var.browser_origins
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# HTTPS가 아닌 요청은 presigned URL이라도 거부합니다.
data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.this
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  policy   = data.aws_iam_policy_document.tls_only[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

output "bucket_names" {
  description = "버킷 키별 이름입니다. 서비스 버킷은 SSM 설정값에, command-db-backups는 백업 스크립트가 씁니다."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "bucket_arns" {
  value = [for b in aws_s3_bucket.this : b.arn]
}

output "bucket_arn_map" {
  description = "버킷 키별 ARN입니다. IAM이 역할마다 필요한 버킷만 허용할 때 씁니다."
  value       = { for k, b in aws_s3_bucket.this : k => b.arn }
}
