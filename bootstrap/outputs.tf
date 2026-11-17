output "state_bucket" {
  description = "envs/prod/backend.hcl의 bucket 값으로 사용합니다."
  value       = aws_s3_bucket.state.bucket
}
