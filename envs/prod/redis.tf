# ---------- Redis (ElastiCache) ----------
# 아직 Redis를 쓰는 서비스가 없어 enable_redis로 끕니다. 켜면 알람과 output도 함께 생깁니다.
module "redis" {
  count             = var.enable_redis ? 1 : 0
  source            = "../../modules/redis"
  name              = var.name
  subnet_ids        = module.network.data_subnet_ids
  azs               = var.azs
  security_group_id = module.security.redis_sg_id
  node_type         = var.redis_node_type
  engine_version    = var.redis_engine_version
}

output "redis" {
  description = "서비스 REDIS_HOST에 primary_endpoint를 넣습니다. 앱 사용자는 scripts/redis-app-user.ps1로 만듭니다. 끄면 null입니다."
  value = var.enable_redis ? {
    primary_endpoint = module.redis[0].primary_endpoint
    reader_endpoint  = module.redis[0].reader_endpoint
    user_group_id    = module.redis[0].user_group_id
  } : null
}
