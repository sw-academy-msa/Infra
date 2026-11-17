# 루트(envs/prod)와 같은 버전 범위입니다. 모듈만 따로 쓰더라도 호환되지 않는 버전이 선택되지 않게 합니다.
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
