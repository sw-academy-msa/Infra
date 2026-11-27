# 공개 ALB입니다. Host 헤더로 api.<도메인>은 일반 Gateway, pay.<도메인>은 구매 Gateway 대상 그룹으로 보냅니다.
# DNS는 Route 53 공개 Hosted Zone입니다. ACM 검증 레코드와 api·pay Alias를 Terraform이 직접 만듭니다.
# 인증서 발급은 도메인 네임서버가 이 Zone을 가리켜야 끝나므로 HTTPS는 두 단계로 켭니다.
#   1) enable_https=false로 적용 → 출력된 name_servers를 도메인 등록업체(가비아)에 입력
#   2) enable_https=true로 다시 적용 → 검증 완료를 기다린 뒤 443 리스너 생성, 80은 HTTPS로 전환
variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "ALB를 둘 공개 서브넷입니다. 서로 다른 AZ 2개 이상이 필요합니다."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "domain_name" {
  description = "루트 도메인입니다. 예: stockdrop.cloud"
  type        = string
}

variable "zone_id" {
  description = "domain_name의 Route 53 공개 Hosted Zone ID입니다."
  type        = string
}

variable "enable_https" {
  description = "네임서버가 Route 53을 가리킨 뒤 true로 바꿉니다. 검증이 끝나야 443 리스너가 생깁니다."
  type        = bool
  default     = false
}

variable "health_check_path" {
  description = "Gateway 기동 여부만 보는 readiness 경로입니다. 메일·DB 검사가 들어간 전체 health를 쓰지 않습니다."
  type        = string
  default     = "/actuator/health/readiness"
}

locals {
  hosts = {
    general  = { host = "api.${var.domain_name}", port = 8000 }
    purchase = { host = "pay.${var.domain_name}", port = 8001 }
  }
}

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.subnet_ids
  security_groups    = [var.security_group_id]
  # Gateway가 받은 X-Forwarded-* 헤더를 제거하므로 잘못된 헤더는 ALB에서 먼저 버립니다.
  drop_invalid_header_fields = true
  idle_timeout               = 60
  tags                       = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "this" {
  for_each    = local.hosts
  name        = "${var.name}-${each.key}"
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"
  # 배포 중 기존 요청이 끝날 시간을 줍니다. Gateway graceful shutdown보다 길게 둡니다.
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.name}-${each.key}" }
}

resource "aws_acm_certificate" "this" {
  domain_name               = local.hosts.general.host
  subject_alternative_names = [local.hosts.purchase.host]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.name}-alb" }
}

# 검증 레코드는 1단계에서 미리 만들어 둡니다. 네임서버가 바뀌면 ACM이 스스로 확인합니다.
# for_each 키는 코드에 정해진 호스트 이름으로 두고, 인증서가 만든 값은 값 쪽에서만 찾습니다(plan 때 키가 정해지도록).
resource "aws_route53_record" "validation" {
  for_each = local.hosts
  zone_id  = var.zone_id
  name     = one([for o in aws_acm_certificate.this.domain_validation_options : o.resource_record_name if o.domain_name == each.value.host])
  type     = one([for o in aws_acm_certificate.this.domain_validation_options : o.resource_record_type if o.domain_name == each.value.host])
  records  = [one([for o in aws_acm_certificate.this.domain_validation_options : o.resource_record_value if o.domain_name == each.value.host])]
  ttl      = 300
  # api·pay가 같은 검증 레코드를 받는 경우가 있어 덮어쓰기를 허용합니다.
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count                   = var.enable_https ? 1 : 0
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# api·pay는 ALB를 가리키는 Alias입니다. Alias 조회는 Route 53 요금이 붙지 않습니다.
resource "aws_route53_record" "host" {
  for_each = local.hosts
  zone_id  = var.zone_id
  name     = each.value.host
  type     = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # HTTPS를 켜면 80은 443으로 돌려보내기만 합니다. 켜기 전에는 등록되지 않은 Host에 404를 돌려줍니다.
  default_action {
    type = var.enable_https ? "redirect" : "fixed-response"

    dynamic "redirect" {
      for_each = var.enable_https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = var.enable_https ? [] : [1]
      content {
        content_type = "application/json"
        status_code  = "404"
        message_body = "{\"success\":false}"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.enable_https ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this[0].certificate_arn

  # 등록되지 않은 Host(직접 ALB 주소 접근 등)는 Gateway로 보내지 않습니다.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      status_code  = "404"
      message_body = "{\"success\":false}"
    }
  }
}

# Host 규칙은 HTTPS를 켜면 443, 켜기 전에는 80 리스너에 붙습니다.
# 메서드·경로 구분은 하지 않습니다. OPTIONS(CORS 사전 요청)도 같은 Gateway로 가서 Gateway가 응답합니다.
resource "aws_lb_listener_rule" "host" {
  for_each     = local.hosts
  listener_arn = var.enable_https ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = each.key == "general" ? 10 : 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  condition {
    host_header {
      values = [each.value.host]
    }
  }
}

output "dns_name" {
  value = aws_lb.this.dns_name
}

output "target_group_arns" {
  description = "general, purchase ASG를 연결할 대상 그룹입니다."
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn }
}

output "arn_suffix" {
  description = "CloudWatch ALB 지표의 LoadBalancer 차원 값입니다."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffixes" {
  description = "CloudWatch 대상 그룹 지표의 TargetGroup 차원 값입니다."
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn_suffix }
}

# 기존 api/pay 인증서를 유지하고 Grafana SNI 인증서를 추가합니다.
variable "monitoring_instance_id" {
  type = string
}
variable "grafana_allowed_cidrs" {
  type    = list(string)
  default = []
  validation {
    condition     = length(var.grafana_allowed_cidrs) <= 3 && alltrue([for c in var.grafana_allowed_cidrs : can(cidrnetmask(c))])
    error_message = "IPv4 CIDR을 최대 3개 지정하세요."
  }
}
resource "aws_lb_target_group" "grafana" {
  name                 = "${var.name}-grafana"
  port                 = 3001
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "instance"
  deregistration_delay = 30
  health_check {
    path                = "/api/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}
resource "aws_lb_target_group_attachment" "grafana" {
  target_group_arn = aws_lb_target_group.grafana.arn
  target_id        = var.monitoring_instance_id
  port             = 3001
}
resource "aws_acm_certificate" "grafana" {
  domain_name       = "grafana.${var.domain_name}"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}
resource "aws_route53_record" "grafana_validation" {
  zone_id = var.zone_id
  name    = one([for o in aws_acm_certificate.grafana.domain_validation_options : o.resource_record_name])
  type    = one([for o in aws_acm_certificate.grafana.domain_validation_options : o.resource_record_type])
  records = [one([for o in aws_acm_certificate.grafana.domain_validation_options : o.resource_record_value])]
  ttl     = 300
}
resource "aws_acm_certificate_validation" "grafana" {
  count                   = var.enable_https ? 1 : 0
  certificate_arn         = aws_acm_certificate.grafana.arn
  validation_record_fqdns = [aws_route53_record.grafana_validation.fqdn]
}
resource "aws_lb_listener_certificate" "grafana" {
  count           = var.enable_https ? 1 : 0
  listener_arn    = aws_lb_listener.https[0].arn
  certificate_arn = aws_acm_certificate_validation.grafana[0].certificate_arn
}
resource "aws_route53_record" "grafana" {
  zone_id = var.zone_id
  name    = "grafana.${var.domain_name}"
  type    = "A"
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
resource "aws_lb_listener_rule" "grafana" {
  count        = var.enable_https ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 30
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
  condition {
    host_header {
      values = ["grafana.${var.domain_name}"]
    }
  }
  dynamic "condition" {
    for_each = length(var.grafana_allowed_cidrs) == 0 ? [] : [var.grafana_allowed_cidrs]
    content {
      source_ip {
        values = condition.value
      }
    }
  }
  depends_on = [aws_lb_listener_certificate.grafana]
}
