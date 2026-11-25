# 보안 그룹은 필요한 경로만 열고 SSH(22)는 열지 않습니다. 서버 접속은 SSM Session Manager를 씁니다.
# AWS 설명 필드는 한글을 허용하지 않아 영어로 적습니다.
locals {
  ports = {
    gateway          = 8000
    purchase_gateway = 8001
    eureka           = 8761
    postgres         = 5432
    redis            = 6379
    kafka            = 9092
    node_exporter    = 9100
    kafka_jmx        = 9404
    postgres_export  = 9187
  }
  # Account 8080 ~ Coupon 8088 업무 서비스 포트입니다.
  service_from = 8080
  service_to   = 8088
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ALB for api and pay hosts"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
}

# 서비스 EC2 공통 그룹입니다. 일반·구매 풀이 Eureka로 서로 호출하므로 같은 그룹 안에서 업무 포트를 엽니다.
resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "Service instances in general and purchase pools"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-app" }
}

# 구매 풀에만 추가로 붙여서 Command DB 접근을 구매 서비스로 제한합니다.
resource "aws_security_group" "purchase" {
  name        = "${var.name}-purchase"
  description = "Purchase pool marker for Command DB access"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-purchase" }
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "General RDS PostgreSQL"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-rds" }
}

resource "aws_security_group" "redis" {
  name        = "${var.name}-redis"
  description = "ElastiCache Redis OSS cache"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-redis" }
}

# Redis는 캐시입니다. 서비스 EC2에서만 접근하며 TLS와 사용자 인증을 함께 씁니다.
resource "aws_vpc_security_group_ingress_rule" "redis_from_app" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis from services"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports.redis
  to_port                      = local.ports.redis
}

resource "aws_security_group" "command_db" {
  name        = "${var.name}-command-db"
  description = "Command PostgreSQL EC2 for orders and product"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-command-db" }
}

resource "aws_security_group" "kafka" {
  name        = "${var.name}-kafka"
  description = "Kafka broker EC2"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-kafka" }
}

# Grafana·Prometheus 화면은 외부에 열지 않고 SSM 포트 포워딩으로만 봅니다.
resource "aws_security_group" "monitoring" {
  name        = "${var.name}-monitoring"
  description = "Prometheus and Grafana EC2"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-monitoring" }
}

# ---------- ALB ----------
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = toset(var.alb_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# HTTP는 ALB에서 HTTPS로 돌려보내기만 합니다.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each          = toset(var.alb_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "HTTP redirect"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_gateways" {
  for_each                     = toset(["gateway", "purchase_gateway"])
  security_group_id            = aws_security_group.alb.id
  description                  = "To ${each.key}"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports[each.key]
  to_port                      = local.ports[each.key]
}

# ---------- 서비스 EC2 ----------
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  for_each                     = toset(["gateway", "purchase_gateway"])
  security_group_id            = aws_security_group.app.id
  description                  = "${each.key} from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports[each.key]
  to_port                      = local.ports[each.key]
}

resource "aws_vpc_security_group_ingress_rule" "app_internal_services" {
  security_group_id            = aws_security_group.app.id
  description                  = "Internal service calls"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = local.service_from
  to_port                      = local.service_to
}

resource "aws_vpc_security_group_ingress_rule" "app_internal_gateways_eureka" {
  for_each                     = toset(["gateway", "purchase_gateway", "eureka"])
  security_group_id            = aws_security_group.app.id
  description                  = "Internal ${each.key}"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports[each.key]
  to_port                      = local.ports[each.key]
}

# Prometheus가 업무 포트의 /actuator/prometheus와 node exporter를 직접 수집합니다.
resource "aws_vpc_security_group_ingress_rule" "app_scrape_services" {
  security_group_id            = aws_security_group.app.id
  description                  = "Prometheus scrape services"
  referenced_security_group_id = aws_security_group.monitoring.id
  ip_protocol                  = "tcp"
  from_port                    = local.service_from
  to_port                      = local.service_to
}

resource "aws_vpc_security_group_ingress_rule" "app_scrape_misc" {
  for_each                     = toset(["gateway", "purchase_gateway", "eureka", "node_exporter"])
  security_group_id            = aws_security_group.app.id
  description                  = "Prometheus scrape ${each.key}"
  referenced_security_group_id = aws_security_group.monitoring.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports[each.key]
  to_port                      = local.ports[each.key]
}

# 이미지 받기, 토스 API, 메일, Kafka, DB 등으로 나가는 통신입니다.
resource "aws_vpc_security_group_egress_rule" "app_out" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "purchase_out" {
  security_group_id = aws_security_group.purchase.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- 일반 RDS ----------
resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from services"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports.postgres
  to_port                      = local.ports.postgres
}

# 최초 DB·계정 생성 같은 관리 작업과 DB 지표 수집은 모니터링 EC2에서 접속합니다.
resource "aws_vpc_security_group_ingress_rule" "rds_from_monitoring" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL admin and metrics from monitoring"
  referenced_security_group_id = aws_security_group.monitoring.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports.postgres
  to_port                      = local.ports.postgres
}

# ---------- Command DB EC2 ----------
resource "aws_vpc_security_group_ingress_rule" "command_db_from_purchase" {
  security_group_id            = aws_security_group.command_db.id
  description                  = "PostgreSQL from purchase pool"
  referenced_security_group_id = aws_security_group.purchase.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports.postgres
  to_port                      = local.ports.postgres
}

resource "aws_vpc_security_group_ingress_rule" "command_db_scrape" {
  for_each                     = toset(["node_exporter", "postgres_export"])
  security_group_id            = aws_security_group.command_db.id
  description                  = "Prometheus scrape ${each.key}"
  referenced_security_group_id = aws_security_group.monitoring.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports[each.key]
  to_port                      = local.ports[each.key]
}

# DB EC2는 패키지 설치와 백업 업로드를 위해서만 밖으로 나갑니다.
resource "aws_vpc_security_group_egress_rule" "command_db_out" {
  security_group_id = aws_security_group.command_db.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- Kafka EC2 ----------
resource "aws_vpc_security_group_ingress_rule" "kafka_from_app" {
  security_group_id            = aws_security_group.kafka.id
  description                  = "Kafka from services"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports.kafka
  to_port                      = local.ports.kafka
}

# Kafka exporter가 모니터링 EC2에서 브로커에 접속하고, JMX·node 지표를 수집합니다.
resource "aws_vpc_security_group_ingress_rule" "kafka_from_monitoring" {
  for_each                     = toset(["kafka", "kafka_jmx", "node_exporter"])
  security_group_id            = aws_security_group.kafka.id
  description                  = "Monitoring ${each.key}"
  referenced_security_group_id = aws_security_group.monitoring.id
  ip_protocol                  = "tcp"
  from_port                    = local.ports[each.key]
  to_port                      = local.ports[each.key]
}

resource "aws_vpc_security_group_egress_rule" "kafka_out" {
  security_group_id = aws_security_group.kafka.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- 모니터링 EC2 ----------
resource "aws_vpc_security_group_egress_rule" "monitoring_out" {
  security_group_id = aws_security_group.monitoring.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
