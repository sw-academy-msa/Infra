# 버킷 이름이 전 세계에서 겹치지 않도록 계정 ID를 붙입니다.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  bucket = "stockdrop-tfstate-${data.aws_caller_identity.current.account_id}"

  # 상태 파일을 잃으면 만든 자원을 Terraform으로 관리할 수 없으므로 실수로 지우지 않게 막습니다.
  lifecycle {
    prevent_destroy = true
  }
}

# 잘못 덮어쓴 상태를 이전 버전으로 되돌릴 수 있게 합니다.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 상태 파일에는 자원 정보가 들어 있으므로 공개 접근을 모두 차단합니다.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 오래된 상태 버전이 계속 쌓이지 않게 90일 뒤 정리합니다.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# 최소 권한: HTTPS가 아닌 접근과 계정 밖 주체의 접근을 거부합니다. 실제 읽기·쓰기 권한은 실행하는 사람의 IAM이 정합니다.
data "aws_iam_policy_document" "state" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
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
  statement {
    sid       = "DenyOtherAccounts"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.state.json
  depends_on = [aws_s3_bucket_public_access_block.state]
}
