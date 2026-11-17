variable "name" {
  description = "자원 이름 앞에 붙는 접두사입니다."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC 전체 주소 범위입니다."
  type        = string
}

variable "azs" {
  description = "서브넷을 나눌 가용 영역입니다. ALB와 RDS는 최소 2개가 필요합니다."
  type        = list(string)
}

variable "nat_instance_type" {
  description = "사설 서브넷의 외부 통신을 맡는 NAT 인스턴스 사양입니다. ARM(t4g) 계열이어야 합니다."
  type        = string
  default     = "t4g.nano"
}
