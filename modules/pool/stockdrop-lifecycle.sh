#!/bin/bash
# ASG lifecycle hook 처리입니다. Lambda 없이 서버가 IMDS로 자기 상태를 확인하고 직접 완료합니다.
#   stockdrop-lifecycle launched <0|1>  시작 hook: Gateway 준비를 제한 시간만 기다린 뒤 완료
#                                       (Gateway 없는 query 풀은 모든 서비스가 준비돼야 CONTINUE, 아니면 ABANDON)
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
    --lifecycle-hook-name "$1" --instance-id "$(imds instance-id)" --lifecycle-action-result "${2:-CONTINUE}" >/dev/null 2>&1 &&
    echo "lifecycle $1 완료" || echo "lifecycle $1 완료 호출 실패(hook 없음 또는 이미 완료)"
}

case "${1:-}" in
  launched)
    deploy_ok="${2:-0}"
    # Gateway가 없는 풀(query)은 ALB 헬스체크가 없어 EC2 상태만으로는 트래픽 투입을 막지 못합니다.
    # 모든 서비스 readiness가 최대 10분 안에 200이어야 CONTINUE하고, 아니면 ABANDON해 서버를 새로 띄웁니다.
    # 요청마다 5초 제한을 두고, 10분은 요청과 대기 시간을 합친 실제 경과 시간으로 잽니다.
    if [ -z "$GATEWAY_NAME" ]; then
      ready=0
      if [ "$deploy_ok" = 1 ]; then
        deadline=$((SECONDS + 600))
        while :; do
          ready=1
          for entry in $SERVICES; do
            IFS=: read -r svc port _mem <<< "$entry"
            if ! docker inspect "$svc" >/dev/null 2>&1 ||
               ! curl -sf --max-time 5 -o /dev/null "http://127.0.0.1:$port/actuator/health/readiness"; then
              ready=0
            fi
          done
          [ "$ready" = 1 ] && break
          [ "$SECONDS" -ge "$deadline" ] && break
          sleep 10
        done
      fi
      if [ "$ready" = 1 ]; then
        complete launching
      else
        echo "서비스 준비 실패: 시작 hook을 ABANDON합니다." >&2
        complete launching ABANDON
        exit 1
      fi
      exit 0
    fi
    # Gateway 컨테이너가 있을 때만 ALB와 같은 readiness 경로를 최대 10분 확인합니다.
    if [ "$deploy_ok" = 1 ] && docker inspect "$GATEWAY_NAME" >/dev/null 2>&1; then
      for _ in $(seq 1 60); do
        curl -sf --max-time 5 -o /dev/null "http://127.0.0.1:$GATEWAY_PORT/actuator/health/readiness" && { echo "Gateway 준비됨"; break; }
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
