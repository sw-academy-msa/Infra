# Command DB, Kafka, 모니터링처럼 고정 주소와 영속 디스크가 필요한 단일 EC2입니다.
# 데이터 디스크는 인스턴스와 별도 EBS라서 인스턴스를 교체해도 데이터가 남습니다.
# Docker와 Compose만 설치하고, 실제 컨테이너(PostgreSQL, Kafka, Prometheus 등)는 배포 단계에서 띄웁니다.
variable "name" {
  type = string
}

variable "role" {
  description = "Role 태그 값입니다. 예: command-db, kafka, monitoring"
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t4g.small"
}

variable "subnet_id" {
  type = string
}

variable "private_ip" {
  description = "고정 사설 IP입니다. 서비스 설정에 이 주소를 넣으므로 인스턴스를 교체해도 바뀌지 않게 고정합니다."
  type        = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "instance_profile" {
  type = string
}

variable "root_volume_size" {
  type    = number
  default = 20
}

variable "data_volume_size" {
  description = "/data에 붙는 데이터 디스크 크기(GB)입니다."
  type        = number
  default     = 20
}

variable "compose_version" {
  description = "설치할 Docker Compose 플러그인 버전입니다."
  type        = string
  default     = "v2.38.2"
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_subnet" "this" {
  id = var.subnet_id
}

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${var.name}-${var.role}-data", Role = var.role }

  # 데이터 디스크는 Terraform에서 실수로 지우지 않도록 막습니다.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.private_ip
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.instance_profile

  # 컨테이너 안에서도 인스턴스 역할을 쓸 수 있도록 IMDSv2 홉 제한을 2로 둡니다.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  # 데이터 디스크가 붙을 때까지 기다렸다가, 처음이면 포맷하고 /data에 연결합니다.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/compose/releases/download/${var.compose_version}/docker-compose-linux-aarch64" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    SERIAL="${replace(aws_ebs_volume.data.id, "-", "")}"
    for _ in $(seq 1 60); do
      DEV=$(lsblk -dno NAME,SERIAL | awk -v s="$SERIAL" '$2==s {print "/dev/"$1}')
      [ -n "$DEV" ] && break
      sleep 5
    done
    [ -n "$DEV" ] || { echo "data volume not attached"; exit 1; }
    blkid "$DEV" || mkfs.xfs "$DEV"
    mkdir -p /data
    UUID=$(blkid -s UUID -o value "$DEV")
    grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data xfs defaults,nofail 0 2" >> /etc/fstab
    mount -a
  EOT

  # AMI 최신값이 바뀌어도 운영 중인 DB·Kafka 서버를 자동으로 교체하지 않습니다.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = { Name = "${var.name}-${var.role}", Role = var.role }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "instance_id" {
  description = "SSM Session Manager 접속에 사용합니다. 예: aws ssm start-session --target <instance_id>"
  value       = aws_instance.this.id
}
