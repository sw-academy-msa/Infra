# ---------- CloudWatch 알람 ----------
# AWS가 기본으로 주는 지표(EC2·ALB·RDS·Redis·Lambda)만 여기서 봅니다. 메모리·디스크·Kafka 지연·PostgreSQL 잠금·
# Outbox·Saga는 CloudWatch 기본 지표에 없으므로 Prometheus(Monitoring 레포) 경보가 맡습니다.
# 임계값은 초기 제안값이며 k6 실측 뒤 조정합니다. 알림은 SNS 주제로 보내고, 이메일 구독은 alert_emails로 정합니다.
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

module "kafka_restart" {
  source             = "../../modules/kafka_restart"
  name               = var.name
  instance_id        = module.host["kafka"].instance_id
  alarm_topic_arn    = aws_sns_topic.alerts.arn
  log_retention_days = var.log_retention_days
}

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
  # 고정 역할 EC2와 NAT 인스턴스입니다. ASG 서버는 ALB 대상 수와 Prometheus가 봅니다.
  watched_instances = merge(
    { for k, h in module.host : k => h.instance_id },
    { nat = module.network.nat_instance_id }
  )
}

# 하드웨어 문제(시스템 상태 검사)는 같은 EBS로 다른 호스트에서 다시 띄웁니다. Kafka·DB 데이터 디스크는 그대로 붙습니다.
resource "aws_cloudwatch_metric_alarm" "system_check" {
  for_each            = local.watched_instances
  alarm_name          = "${var.name}-${each.key}-system-check"
  alarm_description   = "${each.key} EC2 시스템 상태 검사 실패. 자동 복구를 시도합니다."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = concat(local.alarm_actions, ["arn:aws:automate:${var.region}:ec2:recover"])
}

resource "aws_cloudwatch_metric_alarm" "instance_check" {
  for_each            = local.watched_instances
  alarm_name          = "${var.name}-${each.key}-instance-check"
  alarm_description   = "${each.key} EC2 인스턴스 상태 검사 실패(OS 응답 없음)"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  for_each            = local.watched_instances
  alarm_name          = "${var.name}-${each.key}-cpu"
  alarm_description   = "${each.key} CPU 10분 평균 80% 초과"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
}

# t4g는 크레딧이 바닥나면 기본 성능으로 묶입니다. 기본 무제한(unlimited) 모드면 추가 요금이 붙습니다.
resource "aws_cloudwatch_metric_alarm" "cpu_credit" {
  for_each            = local.watched_instances
  alarm_name          = "${var.name}-${each.key}-cpu-credit"
  alarm_description   = "${each.key} CPU 크레딧 잔량 부족"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  dimensions          = { InstanceId = each.value }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 30
  comparison_operator = "LessThanThreshold"
  alarm_actions       = local.alarm_actions
}

# ---------- ALB ----------
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  alarm_description   = "ALB 자체 5xx(대상 없음·연결 실패 등) 5분 10건 초과"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = module.alb.arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  for_each            = module.alb.target_group_arn_suffixes
  alarm_name          = "${var.name}-${each.key}-gateway-5xx"
  alarm_description   = "${each.key} Gateway 응답 5xx 5분 20건 초과"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = module.alb.arn_suffix, TargetGroup = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "target_latency" {
  for_each            = module.alb.target_group_arn_suffixes
  alarm_name          = "${var.name}-${each.key}-gateway-latency"
  alarm_description   = "${each.key} Gateway p95 응답 1초 초과"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = module.alb.arn_suffix, TargetGroup = each.value }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "healthy_hosts" {
  for_each            = module.alb.target_group_arn_suffixes
  alarm_name          = "${var.name}-${each.key}-healthy-hosts"
  alarm_description   = "${each.key} 정상 Gateway가 2대 미만"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = module.alb.arn_suffix, TargetGroup = each.value }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 2
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
}

# ---------- RDS ----------
locals {
  rds_alarms = {
    free-storage = { metric = "FreeStorageSpace", stat = "Minimum", op = "LessThanThreshold", threshold = 2147483648, desc = "RDS 여유 공간 2GB 미만" }
    cpu          = { metric = "CPUUtilization", stat = "Average", op = "GreaterThanThreshold", threshold = 80, desc = "RDS CPU 80% 초과" }
    connections  = { metric = "DatabaseConnections", stat = "Maximum", op = "GreaterThanThreshold", threshold = 90, desc = "RDS 연결 수 90 초과" }
    memory       = { metric = "FreeableMemory", stat = "Minimum", op = "LessThanThreshold", threshold = 104857600, desc = "RDS 여유 메모리 100MB 미만" }
  }
  # Redis 지표는 노드별입니다. 복제 그룹 ID 뒤에 -001, -002가 붙습니다.
  redis_nodes = { for i in [1, 2] : format("%03d", i) => "${module.redis.replication_group_id}-${format("%03d", i)}" }
  redis_alarms = {
    memory    = { metric = "DatabaseMemoryUsagePercentage", stat = "Maximum", op = "GreaterThanThreshold", threshold = 80, desc = "Redis 메모리 80% 초과" }
    evictions = { metric = "Evictions", stat = "Sum", op = "GreaterThanThreshold", threshold = 100, desc = "Redis 5분 eviction 100건 초과" }
    cpu       = { metric = "EngineCPUUtilization", stat = "Average", op = "GreaterThanThreshold", threshold = 80, desc = "Redis 엔진 CPU 80% 초과" }
  }
}

resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each            = local.rds_alarms
  alarm_name          = "${var.name}-rds-${each.key}"
  alarm_description   = each.value.desc
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = module.rds.identifier }
  statistic           = each.value.stat
  period              = 300
  evaluation_periods  = 2
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  alarm_actions       = local.alarm_actions
}

# ---------- Redis ----------
resource "aws_cloudwatch_metric_alarm" "redis" {
  for_each = {
    for pair in setproduct(keys(local.redis_alarms), keys(local.redis_nodes)) : "${pair[0]}-${pair[1]}" => {
      alarm = local.redis_alarms[pair[0]]
      node  = local.redis_nodes[pair[1]]
    }
  }
  alarm_name          = "${var.name}-redis-${each.key}"
  alarm_description   = each.value.alarm.desc
  namespace           = "AWS/ElastiCache"
  metric_name         = each.value.alarm.metric
  dimensions          = { CacheClusterId = each.value.node }
  statistic           = each.value.alarm.stat
  period              = 300
  evaluation_periods  = 2
  threshold           = each.value.alarm.threshold
  comparison_operator = each.value.alarm.op
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

# Replica가 Primary를 따라가지 못하면 장애 전환 때 최근 캐시가 사라질 수 있습니다.
resource "aws_cloudwatch_metric_alarm" "redis_replication_lag" {
  alarm_name          = "${var.name}-redis-replication-lag"
  alarm_description   = "Redis 복제 지연 5초 초과"
  namespace           = "AWS/ElastiCache"
  metric_name         = "ReplicationLag"
  dimensions          = { CacheClusterId = local.redis_nodes["002"] }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

output "alerts_topic_arn" {
  description = "알람 SNS 주제입니다. Slack 연동은 AWS Chatbot을 콘솔에서 이 주제에 연결합니다(웹훅을 코드에 넣지 않음)."
  value       = aws_sns_topic.alerts.arn
}
