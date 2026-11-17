# ---------- Redis (ElastiCache) ----------
module "redis" {
  source            = "../../modules/redis"
  name              = var.name
  subnet_ids        = module.network.data_subnet_ids
  azs               = var.azs
  security_group_id = module.security.redis_sg_id
  node_type         = var.redis_node_type
  engine_version    = var.redis_engine_version
}

output "redis" {
  description = "서비스 REDIS_HOST에 primary_endpoint를 넣습니다. 앱 사용자는 scripts/redis-app-user.ps1로 만듭니다."
  value = {
    primary_endpoint = module.redis.primary_endpoint
    reader_endpoint  = module.redis.reader_endpoint
    user_group_id    = module.redis.user_group_id
  }
}
