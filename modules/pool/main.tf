# 서비스 EC2 풀(Launch Template + ASG)입니다. 부팅 스크립트가 SSM 설정과 릴리스 태그로 컨테이너를 띄웁니다.
# 풀 안의 서버는 모두 같은 컨테이너 묶음을 띄우므로, 증설하면 그 묶음 전체가 함께 늘어납니다(서비스 하나만 늘지 않음).
variable "name" {
  type = string
}

variable "pool" {
  description = "Pool 태그 값입니다. Prometheus EC2 서비스 탐색이 이 태그로 대상을 찾습니다. 예: general, query, purchase"
  type        = string
}

variable "subnet_ids" {
  description = "서버를 둘 app 서브넷입니다. 두 AZ를 넣으면 ASG가 AZ별로 고르게 나눕니다."
  type        = list(string)
}

variable "instance_type" {
  type = string
}

variable "security_group_ids" {
  type = list(string)
}

variable "instance_profile" {
  type = string
}

variable "target_group_arns" {
  description = "이 풀의 Gateway를 연결할 ALB 대상 그룹입니다. Gateway가 없는 query 풀은 비워 둡니다."
  type        = list(string)
}

variable "min_size" {
  type = number
}

variable "max_size" {
  type = number
}

variable "desired_capacity" {
  description = "처음 만들 때의 서버 수입니다. 이후에는 증설 정책이 바꾼 값을 Terraform이 되돌리지 않습니다."
  type        = number
}

variable "cpu_target_percent" {
  description = "평균 CPU가 이 값을 넘으면 서버를 늘리고, 충분히 낮으면 줄입니다."
  type        = number
  default     = 60
}

variable "services" {
  description = "이 풀에서 띄울 서비스와 호스트 포트, 컨테이너 메모리(MB)입니다. 위에서부터 순서대로 띄웁니다."
  type = list(object({
    name      = string
    port      = number
    memory_mb = number
  }))
}

variable "gateway_service" {
  default     = null
  nullable    = true
  description = "ALB 대상이 되는 Gateway 서비스 이름입니다. 시작 hook이 이 서비스의 readiness를 확인합니다. 없으면(null) 모든 서비스의 readiness를 확인합니다."
  type        = string
}

variable "region" {
  type = string
}

variable "parameter_path" {
  type = string
}

variable "registry" {
  description = "ECR 레지스트리 주소입니다. 예: <계정>.dkr.ecr.ap-northeast-2.amazonaws.com"
  type        = string
}

variable "repo_prefix" {
  type    = string
  default = "stockdrop"
}

variable "eureka_ips" {
  description = "Eureka 고정 IP 목록입니다. Eureka 노드끼리의 peer 주소로 씁니다."
  type        = list(string)
}

variable "eureka_hosts" {
  description = "Eureka 내부 DNS 이름 목록입니다. 서비스의 EUREKA_DEFAULT_ZONE을 만듭니다."
  type        = list(string)
}

variable "eureka_enis" {
  description = "이 풀이 Eureka를 띄울 때 붙일 고정 ENI(id, AZ, IP)입니다. Eureka가 없는 풀은 비워 둡니다."
  type        = list(object({ id = string, az = string, ip = string }))
  default     = []
}

variable "kafka_bootstrap_servers" {
  type = string
}

variable "health_check_type" {
  description = "서버 교체 기준입니다. 평소 ELB(앱 상태)이며, 앱을 처음 배포하기 전에는 EC2(서버 상태)로 둬야 서버가 반복 교체되지 않습니다."
  type        = string
  default     = "ELB"
  validation {
    condition     = contains(["ELB", "EC2"], var.health_check_type)
    error_message = "ELB 또는 EC2만 쓸 수 있습니다."
  }
}

variable "health_check_grace_seconds" {
  description = "JVM 여러 개가 뜨는 시간을 기다린 뒤 ALB 헬스체크 결과로 서버를 교체합니다."
  type        = number
  default     = 600
}

variable "compose_version" {
  type    = string
  default = "v2.38.2" # host 모듈과 같은 버전입니다.
}

variable "node_exporter_version" {
  type    = string
  default = "v1.9.1"
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  full_name = "${var.name}-${var.pool}"
  gateway   = one([for s in var.services : s if s.name == var.gateway_service])
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region                  = var.region
    parameter_path          = var.parameter_path
    registry                = var.registry
    repo_prefix             = var.repo_prefix
    services                = join(" ", [for s in var.services : "${s.name}:${s.port}:${s.memory_mb}"])
    eureka_ips              = join(" ", var.eureka_ips)
    eureka_hosts            = join(" ", var.eureka_hosts)
    eureka_enis             = join(" ", [for e in var.eureka_enis : "${e.id}:${e.az}:${e.ip}"])
    kafka_bootstrap_servers = var.kafka_bootstrap_servers
    asg_name                = local.full_name
    gateway_name            = try(local.gateway.name, "")
    gateway_port            = try(tostring(local.gateway.port), "")
    compose_version         = var.compose_version
    node_exporter_version   = var.node_exporter_version
    deploy_script           = trimspace(file("${path.module}/stockdrop-deploy.sh"))
    lifecycle_script        = trimspace(file("${path.module}/stockdrop-lifecycle.sh"))
  })
}

resource "aws_launch_template" "this" {
  name          = local.full_name
  image_id      = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.instance_type
  # 작업 사본이 CRLF여도 서버 스크립트에 CR이 들어가지 않게 제거합니다.
  user_data              = base64encode(replace(local.user_data, "\r", ""))
  update_default_version = true

  iam_instance_profile {
    name = var.instance_profile
  }

  # 컨테이너가 호스트 네트워크로 IMDS를 쓰므로 홉 제한은 2로 둡니다. IMDSv2만 허용합니다.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # 공인 IP 없이 app 서브넷에만 둡니다. 보안 그룹은 여기에만 지정합니다(최상위와 함께 쓰면 AWS가 거부).
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = var.security_group_ids
    delete_on_termination       = true
    device_index                = 0
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = local.full_name, Pool = var.pool }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = local.full_name, Pool = var.pool }
  }
}

resource "aws_autoscaling_group" "this" {
  name                      = local.full_name
  vpc_zone_identifier       = var.subnet_ids
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  target_group_arns         = var.target_group_arns
  health_check_type         = var.health_check_type
  health_check_grace_period = var.health_check_grace_seconds
  default_instance_warmup   = var.health_check_grace_seconds
  wait_for_capacity_timeout = var.wait_for_capacity_timeout
  # 오래된 Launch Template 서버부터 줄여, 줄일 때 최신 설정 서버가 남게 합니다.
  termination_policies = ["OldestLaunchTemplate", "Default"]

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  # 시작 hook: 부팅 스크립트가 컨테이너를 띄우고 완료합니다. 응답이 없으면 제한 시간(기본 15분) 뒤 실패로 보고 새로 띄웁니다.
  initial_lifecycle_hook {
    name                 = "launching"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    heartbeat_timeout    = var.launch_hook_timeout_seconds
    default_result       = "ABANDON"
  }

  # 종료 hook: 서버가 컨테이너를 정상 종료(Eureka 등록 해제)한 뒤 완료합니다. 응답이 없어도 2분 뒤 종료합니다.
  initial_lifecycle_hook {
    name                 = "terminating"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
    heartbeat_timeout    = 120
    default_result       = "CONTINUE"
  }

  # Launch Template이 바뀌면 한 대를 먼저 추가로 띄운 뒤 한 대씩 교체합니다(정상 100% 유지, 최대 150%). 같은 설정의 서버는 건너뜁니다.
  # general은 Eureka ENI 때문에 끕니다(automatic_instance_refresh = false).
  dynamic "instance_refresh" {
    for_each = var.automatic_instance_refresh ? [1] : []
    content {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = 100
        max_healthy_percentage = 150
        instance_warmup        = var.health_check_grace_seconds
        skip_matching          = true
      }
    }
  }

  # 증설 정책이 바꾼 서버 수를 다음 apply가 되돌리지 않습니다. 수를 직접 바꾸려면 콘솔·CLI로 조정합니다.
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # Prometheus EC2 서비스 탐색은 Project·Pool 태그로 대상을 찾습니다.
  tag {
    key                 = "Project"
    value               = "STOCKDROP"
    propagate_at_launch = true
  }

  tag {
    key                 = "Pool"
    value               = var.pool
    propagate_at_launch = true
  }
}

# 평균 CPU 기준으로 이 풀만 따로 늘리고 줄입니다. 축소 때는 종료 hook과 ALB 등록 해제 지연으로 요청을 비웁니다.
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.full_name}-cpu"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_percent
  }
}

output "asg_name" {
  value = aws_autoscaling_group.this.name
}

output "asg_arn" {
  value = aws_autoscaling_group.this.arn
}

variable "launch_hook_timeout_seconds" {
  description = "시작 hook 제한 시간(초)입니다. 이미지 받기와 컨테이너 기동, readiness 대기(최대 10분)를 모두 담아야 합니다."
  type        = number
  default     = 900
}

variable "wait_for_capacity_timeout" {
  description = "ASG를 만들거나 바꿀 때 Terraform이 InService 서버 수를 기다리는 시간입니다."
  type        = string
  default     = "10m"
}

variable "automatic_instance_refresh" {
  description = "Launch Template이 바뀔 때 자동 instance refresh 여부입니다. Eureka 고정 ENI가 있는 general은 한 대씩 유지보수 절차로 교체하므로 끕니다."
  type        = bool
  default     = true
}
