output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "app_sg_id" {
  value = aws_security_group.app.id
}

output "purchase_sg_id" {
  value = aws_security_group.purchase.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "command_db_sg_id" {
  value = aws_security_group.command_db.id
}

output "kafka_sg_id" {
  value = aws_security_group.kafka.id
}

output "monitoring_sg_id" {
  value = aws_security_group.monitoring.id
}

output "redis_sg_id" {
  value = aws_security_group.redis.id
}
