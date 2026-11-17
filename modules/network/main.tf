# 공개 서브넷은 ALB와 NAT, app 서브넷은 서비스 EC2와 Kafka·Command DB·모니터링 EC2, data 서브넷은 RDS·Redis를 둡니다.
# NAT는 비용 때문에 AZ1에 하나만 둡니다. AZ2 서버의 외부 통신도 AZ1을 거치므로 AZ1 장애 때 외부 통신이 끊기고,
# AZ 간 전송 요금(GB당 약 0.01달러)이 생길 수 있습니다.
locals {
  az_count = length(var.azs)
  public   = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  app      = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
  data     = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, 20 + i)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name}-public-${var.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.app[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.name}-app-${var.azs[count.index]}", Tier = "app" }
}

resource "aws_subnet" "data" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.data[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.name}-data-${var.azs[count.index]}", Tier = "data" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# 사설 서브넷은 NAT 인스턴스를 거쳐서만 외부로 나갑니다. 외부에서 들어오는 경로는 없습니다.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private-rt" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
}

resource "aws_route_table_association" "app" {
  count          = local.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

# data 서브넷은 RDS·Redis만 두는 격리 구간입니다. 인터넷 기본 경로가 없고 VPC 내부 통신만 됩니다.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-data-rt" }
}

resource "aws_route_table_association" "data" {
  count          = local.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# ECR 이미지 계층과 S3 이미지는 NAT를 거치지 않고 무료 Gateway 엔드포인트로 받습니다.
data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.name}-s3-endpoint" }
}
