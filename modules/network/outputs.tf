output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}

output "nat_public_ip" {
  description = "사설 서브넷 EC2가 외부로 나갈 때 쓰는 공인 IP입니다."
  value       = aws_eip.nat.public_ip
}

output "data_subnet_cidrs" {
  description = "DB·Kafka·모니터링 EC2의 고정 사설 IP를 계산할 때 사용합니다."
  value       = aws_subnet.data[*].cidr_block
}

output "app_subnet_cidrs" {
  description = "Eureka 고정 IP ENI 주소를 계산할 때 사용합니다."
  value       = aws_subnet.app[*].cidr_block
}

output "nat_instance_id" {
  description = "CloudWatch 상태 검사 알람 대상입니다."
  value       = aws_instance.nat.id
}
