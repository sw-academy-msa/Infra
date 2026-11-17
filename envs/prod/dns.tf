# ---------- DNS ----------
# 공개 Zone: hosted_zone_id가 비어 있으면 새로 만들고, 이미 있는 Zone ID를 넣으면 재사용합니다.
# 새로 만든 Zone은 네임서버(output public_name_servers)를 도메인 등록업체에 넣기 전까지 인터넷에서 쓰이지 않습니다.
resource "aws_route53_zone" "public" {
  count   = var.hosted_zone_id == "" ? 1 : 0
  name    = var.domain_name
  comment = "STOCKDROP public zone"

  # Zone을 지우면 네임서버 값이 바뀌어 등록업체 설정을 다시 해야 하므로 삭제를 막습니다.
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_route53_zone" "existing" {
  count        = var.hosted_zone_id == "" ? 0 : 1
  zone_id      = var.hosted_zone_id
  private_zone = false
}

locals {
  public_zone_id      = var.hosted_zone_id == "" ? aws_route53_zone.public[0].zone_id : var.hosted_zone_id
  public_name_servers = var.hosted_zone_id == "" ? aws_route53_zone.public[0].name_servers : data.aws_route53_zone.existing[0].name_servers
}

# 내부 Zone: 이 VPC 안에서만 조회됩니다. 고정 역할 EC2의 주소를 서비스 설정에 IP 대신 이름으로 넣습니다.
resource "aws_route53_zone" "internal" {
  name    = var.internal_domain
  comment = "STOCKDROP private zone"

  vpc {
    vpc_id = module.network.vpc_id
  }
}

resource "aws_route53_record" "host" {
  for_each = local.hosts
  zone_id  = aws_route53_zone.internal.zone_id
  name     = "${each.key}.${var.internal_domain}"
  type     = "A"
  ttl      = 60
  records  = [each.value.ip]
}
