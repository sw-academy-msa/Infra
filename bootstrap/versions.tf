# 원격 상태 버킷을 만드는 최초 설정입니다. 자기 자신의 상태는 로컬 파일로 둡니다.
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "STOCKDROP"
      ManagedBy = "terraform"
    }
  }
}
