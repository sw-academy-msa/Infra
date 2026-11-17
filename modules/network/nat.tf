# NAT Gateway(월 약 45달러 이상) 대신 소형 EC2로 사설 서브넷의 외부 통신을 처리합니다.
# 한 대라서 이 인스턴스가 멈추면 사설 서브넷의 외부 통신(ECR 이미지 받기, 토스 API 등)이 끊깁니다.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# VPC 내부에서 외부로 나가는 통신만 중계합니다.
resource "aws_security_group" "nat" {
  name        = "${var.name}-nat"
  description = "NAT instance for private subnets"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-nat" }
}

# VPC 내부 트래픽만 받습니다.
resource "aws_vpc_security_group_ingress_rule" "nat_from_vpc" {
  security_group_id = aws_security_group.nat.id
  description       = "From VPC only"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nat_out" {
  security_group_id = aws_security_group.nat.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# NAT도 SSH 없이 Session Manager로만 접속합니다. 장애 때 iptables·라우팅을 확인하는 용도이며 다른 권한은 주지 않습니다.
data "aws_iam_policy_document" "nat_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_partition" "current" {}

resource "aws_iam_role" "nat" {
  name               = "${var.name}-nat"
  description        = "NAT instance (SSM access only)"
  assume_role_policy = data.aws_iam_policy_document.nat_assume.json
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  name = "${var.name}-nat"
  role = aws_iam_role.nat.name
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.nat_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  iam_instance_profile   = aws_iam_instance_profile.nat.name
  # 다른 주소로 가는 패킷을 대신 전달해야 하므로 출발지·목적지 검사를 끕니다.
  source_dest_check = false

  metadata_options {
    http_tokens = "required"
  }

  # 다른 EC2와 같이 암호화된 gp3 루트 디스크를 씁니다. NAT는 데이터를 저장하지 않아 기본 크기(8GB)로 충분합니다.
  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # 재부팅 뒤에도 IP 전달과 주소 변환 규칙이 유지되도록 저장합니다.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y iptables-services
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/90-nat.conf
    sysctl -p /etc/sysctl.d/90-nat.conf
    IFACE=$(ip route show default | awk '{print $5}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    iptables -F FORWARD
    service iptables save
    systemctl enable --now iptables
  EOT

  # AMI 최신값이 바뀌어도 운영 중인 NAT를 자동 교체하지 않습니다.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "${var.name}-nat" }
}

# NAT의 공인 IP를 고정해서 외부 서비스에 허용 IP로 등록할 수 있게 합니다.
resource "aws_eip" "nat" {
  domain   = "vpc"
  instance = aws_instance.nat.id
  tags     = { Name = "${var.name}-nat" }
}
