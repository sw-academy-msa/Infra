# Kafka EC2가 stopped가 되면 EventBridge → Lambda가 다시 시작합니다.
# 유지보수로 일부러 멈출 때는 인스턴스에 AutoRestart=false 태그를 먼저 붙입니다(docs/operations.md).
# Lambda는 EC2 API만 부르므로 VPC에 넣지 않습니다. NAT 장애와 상관없이 동작합니다.
variable "name" {
  type = string
}

variable "instance_id" {
  description = "재기동 대상 Kafka EC2입니다."
  type        = string
}

variable "alarm_topic_arn" {
  description = "Lambda 실패 알람을 보낼 SNS 주제입니다."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 14
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  function_name = "${var.name}-kafka-restart"
  instance_arn  = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/${var.instance_id}"
}

# 테스트 파일은 넣지 않고 handler.py만 묶습니다.
data "archive_file" "this" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/build/kafka-restart.zip"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = local.function_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# 상태 조회는 리소스로 좁힐 수 없고, 시작은 Kafka 인스턴스 하나로만 제한합니다.
data "aws_iam_policy_document" "this" {
  statement {
    sid       = "Describe"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    sid       = "StartKafkaOnly"
    actions   = ["ec2:StartInstances"]
    resources = [local.instance_arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "kafka-restart"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

resource "aws_lambda_function" "this" {
  function_name    = local.function_name
  role             = aws_iam_role.this.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = { KAFKA_INSTANCE_ID = var.instance_id }
  }

  depends_on = [aws_cloudwatch_log_group.this, aws_iam_role_policy.this]
}

# Kafka 인스턴스의 stopped 이벤트만 받습니다. 다른 EC2의 정지는 이 함수를 깨우지 않습니다.
resource "aws_cloudwatch_event_rule" "this" {
  name        = local.function_name
  description = "Restart Kafka EC2 when it stops"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state         = ["stopped"]
      "instance-id" = [var.instance_id]
    }
  })
}

resource "aws_cloudwatch_event_target" "this" {
  rule = aws_cloudwatch_event_rule.this.name
  arn  = aws_lambda_function.this.arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 4
  }
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.this.arn
}

# 함수가 실패하면(권한 오류, 시작 실패 등) 알립니다. 성공해도 Kafka 프로세스 정상 여부는 별도 알람이 봅니다.
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${local.function_name}-errors"
  alarm_description   = "Kafka 자동 재기동 Lambda 실패"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.this.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
}

output "function_name" {
  value = aws_lambda_function.this.function_name
}
