# 서비스별 Docker 이미지 저장소입니다. CD가 이미지를 올리고 EC2가 받아서 실행합니다.
variable "name" {
  description = "저장소 이름 앞에 붙는 접두사입니다. 예: stockdrop/account-service"
  type        = string
}

variable "repositories" {
  description = "만들 이미지 저장소 이름 목록입니다."
  type        = list(string)
}

variable "keep_images" {
  description = "저장소마다 남겨 둘 최근 이미지 수입니다. 롤백할 수 있는 범위입니다."
  type        = number
  default     = 20
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)
  name     = "${var.name}/${each.value}"
  # 같은 태그를 덮어쓰지 못하게 해서 어떤 커밋이 배포됐는지 태그로 추적합니다.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep recent images only"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_images
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_urls" {
  description = "서비스 이름별 이미지 저장소 주소입니다."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  value = [for r in aws_ecr_repository.this : r.arn]
}

output "repository_arn_map" {
  description = "서비스 이름별 저장소 ARN입니다. 레포별 배포 역할이 자기 저장소에만 push하도록 제한할 때 씁니다."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}
