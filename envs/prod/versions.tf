terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Kafka 재기동 Lambda 코드를 zip으로 묶습니다.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # 버킷 이름은 backend.hcl로 넘깁니다. 잠금은 S3 자체 잠금 파일을 사용합니다.
  backend "s3" {
    key          = "prod/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "STOCKDROP"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}
