variable "name" {
  description = "자원 이름 앞에 붙는 접두사입니다."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "alb_ingress_cidrs" {
  description = "ALB 443/80에 접근을 허용할 주소입니다. 기본은 인터넷 전체입니다."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
