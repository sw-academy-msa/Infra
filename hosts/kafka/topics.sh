#!/bin/bash
# 운영 Kafka 토픽을 미리 만듭니다. 이미 있는 토픽은 건너뛰고 설정·데이터를 바꾸지 않습니다.
# 토픽 목록은 각 서비스 코드의 발행·구독 이름과 로컬 Initialize-*Topics.ps1을 기준으로 합니다.
set -euo pipefail

CONTAINER="${KAFKA_CONTAINER:-stockdrop-kafka}"
BOOTSTRAP="127.0.0.1:9092"
DLT_RETENTION_MS=2592000000 # 실패 메시지는 원인 조사를 위해 30일 보관합니다.
MEMBERSHIP_RETENTION_MS=7776000000 # 회원제 원본 이벤트는 대사와 재처리를 위해 90일 보관합니다.

create() {
  local topic="$1" partitions="$2"
  shift 2
  local configs=()
  for c in "$@"; do configs+=(--config "$c"); done
  docker exec -e KAFKA_OPTS= "$CONTAINER" /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" \
    --create --if-not-exists --topic "$topic" --partitions "$partitions" --replication-factor 1 \
    ${configs[@]+"${configs[@]}"}
}

# 상품·주문·결제는 구매 풀 2대가 나눠 소비하도록 2개 파티션, 큰 상품 메시지를 위해 4 MiB입니다.
for t in \
  stockdrop.product.public.v1 \
  stockdrop.product.inquiries.v1 \
  stockdrop.product.published.v1 \
  stockdrop.orders.private.v1 \
  stockdrop.orders.inquiries.private.v1 \
  stockdrop.payment.commands.private.v1 \
  stockdrop.payment.results.private.v1; do
  create "$t" 2 max.message.bytes=4194304
done

# 소비 실패 메시지 보관용입니다. ProductQuery, OrderQuery, Payment, OrderCommand가 씁니다.
for t in \
  stockdrop.product.public.v1.DLT \
  stockdrop.product.inquiries.v1.DLT \
  stockdrop.orders.private.v1.DLT \
  stockdrop.orders.inquiries.private.v1.DLT \
  stockdrop.payment.commands.private.v1.DLT \
  stockdrop.payment.results.private.v1.DLT; do
  create "$t" 2 max.message.bytes=4194304 retention.ms="$DLT_RETENTION_MS"
done

# AI 분석·추천과 알림은 로컬과 같이 3개 파티션입니다.
for t in \
  stockdrop.product.analysis-requested.v1 \
  stockdrop.ai.product-analyzed.v1 \
  stockdrop.ai.recommendation-candidates.v1 \
  stockdrop.notifications.account.v1 \
  stockdrop.notifications.product.v1 \
  stockdrop.notifications.order.v1; do
  create "$t" 3
done

# 회원제 명령과 결과는 Account와 Payment가 계정 단위 키로 주고받습니다. 본문은 16KiB 이하입니다.
for t in \
  stockdrop.membership.commands.private.v1 \
  stockdrop.membership.events.private.v1; do
  create "$t" 2 retention.ms="$MEMBERSHIP_RETENTION_MS"
  create "$t.DLT" 2 retention.ms="$DLT_RETENTION_MS"
done

# 회원제 알림은 다른 알림 토픽과 같은 3개 파티션이며 Notification 전용 소비자가 DLT를 씁니다.
create stockdrop.notifications.membership.v1 3 retention.ms="$MEMBERSHIP_RETENTION_MS"
create stockdrop.notifications.membership.v1.DLT 3 retention.ms="$DLT_RETENTION_MS"

# 쿠폰 연동은 16KiB 계약이며 DLT와 유한 재시도 소비자를 사용합니다.
create stockdrop.orders.lifecycle.v1 2 retention.ms="$MEMBERSHIP_RETENTION_MS"
create stockdrop.orders.lifecycle.v1.DLT 2 retention.ms="$DLT_RETENTION_MS"
for t in stockdrop.ai.campaign-targets.v1 stockdrop.notifications.coupon.v1 stockdrop.notifications.campaign.v1; do
  create "$t" 3 retention.ms="$MEMBERSHIP_RETENTION_MS"
  create "$t.DLT" 3 retention.ms="$DLT_RETENTION_MS"
done

echo "--- 현재 토픽"
docker exec -e KAFKA_OPTS= "$CONTAINER" /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --describe \
  | grep -E '^Topic:' | awk '{print $2, $6, $8}' | sort
