#!/bin/bash
# ASG lifecycle hook 처리입니다. Lambda 없이 서버가 IMDS로 자기 상태를 확인하고 직접 완료합니다.
#   stockdrop-lifecycle launched <0|1>  시작 hook: Gateway 준비를 제한 시간만 기다린 뒤 완료
#   stockdrop-lifecycle watch           종료 hook: 종료 예정이면 컨테이너를 정상 종료(Eureka 등록 해제)한 뒤 완료
set -uo pipefail
source /etc/stockdrop/pool.conf

imds() {
  local token
  token=$(curl -sfX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || return 1
  curl -sf -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

complete() {
  aws autoscaling complete-lifecycle-action --region "$REGION" --auto-scaling-group-name "$ASG_NAME" \
    --lifecycle-hook-name "$1" --instance-id "$(imds instance-id)" --lifecycle-action-result CONTINUE >/dev/null 2>&1 &&
    echo "lifecycle $1 완료" || echo "lifecycle $1 완료 호출 실패(hook 없음 또는 이미 완료)"
}

case "${1:-}" in
  launched)
    deploy_ok="${2:-0}"
    # Gateway 컨테이너가 있을 때만 ALB와 같은 readiness 경로를 최대 10분 확인합니다.
    if [ "$deploy_ok" = 1 ] && docker inspect "$GATEWAY_NAME" >/dev/null 2>&1; then
      for _ in $(seq 1 60); do
        curl -sf -o /dev/null "http://127.0.0.1:$GATEWAY_PORT/actuator/health/readiness" && { echo "Gateway 준비됨"; break; }
        sleep 10
      done
    fi
    # 결과와 관계없이 CONTINUE로 넘깁니다. RDS 장애처럼 모든 서버에 공통인 문제로 교체가 반복되지 않게 하고,
    # 실제 트래픽 투입 여부는 ALB 헬스체크가 판단합니다.
    complete launching
    ;;
  watch)
    while true; do
      if [ "$(imds autoscaling/target-lifecycle-state 2>/dev/null)" = "Terminated" ]; then
        echo "종료 예정: 컨테이너 정상 종료"
        # Gateway를 먼저 멈춰 새 요청을 받지 않게 하고, 나머지 서비스는 각자 Eureka에서 등록을 해제하며 종료됩니다.
        for f in /etc/stockdrop/compose/"$GATEWAY_NAME".yaml /etc/stockdrop/compose/*.yaml; do
          [ -f "$f" ] && docker compose -f "$f" stop >/dev/null 2>&1
        done
        complete terminating
        exit 0
      fi
      sleep 5
    done
    ;;
  *)
    echo "사용법: stockdrop-lifecycle launched <0|1> | watch" >&2
    exit 2
    ;;
esac
