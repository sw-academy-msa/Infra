#!/bin/bash
# 이 서버 풀의 서비스 컨테이너를 SSM 설정값과 릴리스 태그대로 (다시) 띄웁니다. 비밀값은 출력하지 않으며 set -x를 쓰지 않습니다.
# 부팅 시 전체를 실행하고, CD는 SSM Run Command로 특정 서비스만 다시 배포합니다.
#   stockdrop-deploy                    이 풀의 모든 서비스
#   stockdrop-deploy payment-service    특정 서비스만
# 서비스마다 /etc/stockdrop/compose/<서비스>.yaml을 만들고 docker compose로 띄웁니다. 서로의 준비를 기다리지 않으므로
# Eureka·Gateway·서비스 사이에 순환 대기가 생기지 않습니다. 각 서비스가 Eureka 재시도로 스스로 붙습니다.
#   stockdrop-deploy --wait <서비스>    CD용: 새 컨테이너가 준비될 때까지 기다리고, 실패하면 오류로 끝냄
set -euo pipefail
source /etc/stockdrop/pool.conf

# CD는 서버를 한 대씩 바꾸며, 준비 실패 시 다음 서버로 넘어가지 않도록 오류 코드를 돌려줍니다.
WAIT=0
if [ "${1:-}" = "--wait" ]; then
  WAIT=1
  shift
fi

# 부팅 배포와 CD 배포, 또는 앞선 CD가 아직 도는 중에 들어온 CD가 같은 서버에서 겹치지 않게 순서대로 실행합니다.
exec 9>/run/stockdrop-deploy.lock
flock -w 600 9 || { echo "다른 배포가 10분 넘게 진행 중이라 이번 배포를 건너뜁니다." >&2; exit 1; }

TOKEN=$(curl -sfX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
md() { curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
INSTANCE_ID=$(md instance-id)
PRIVATE_IP=$(md local-ipv4)
AZ=$(md placement/availability-zone)
# 부팅 스크립트가 Eureka ENI를 붙였으면 그 주소가 들어 있습니다. 없으면 이 서버는 Eureka를 띄우지 않습니다.
EUREKA_SELF_IP=$(cat /etc/stockdrop/eureka-ip 2>/dev/null || true)
EUREKA_ZONE=$(for h in $EUREKA_HOSTS; do printf 'http://%s:8761/eureka/,' "$h"; done | sed 's/,$//')

retry() {
  local n
  for n in 1 2 3; do "$@" && return 0; echo "재시도 $n/3: $1" >&2; sleep $((n * 10)); done
  return 1
}

retry bash -c "aws ecr get-login-password --region '$REGION' | docker login --username AWS --password-stdin '$REGISTRY' >/dev/null"

param() {
  aws ssm get-parameter --region "$REGION" --name "$1" --query Parameter.Value --output text 2>/dev/null || true
}

# 경로 아래 값을 "이름=값" 줄로 출력합니다. files/ 아래 값은 환경변수가 아니라 파일로 만들므로 건너뜁니다.
# Compose는 env_file 값의 $를 변수로 해석해 bcrypt 해시($2a$12$...)를 깨뜨리므로 작은따옴표로 감싸 그대로 넘깁니다.
env_lines() {
  aws ssm get-parameters-by-path --region "$REGION" --path "$1" \
    --with-decryption --recursive --query 'Parameters[].[Name,Value]' --output text |
    while IFS=$'\t' read -r name value; do
      case "$name" in */files/*) continue ;; esac
      [ -n "$name" ] || continue
      if [[ "$value" == *"'"* ]]; then
        # 작은따옴표가 든 값은 감쌀 수 없습니다. $까지 함께 있으면 값이 바뀔 수 있어 이름만 경고합니다.
        [[ "$value" == *'$'* ]] && echo "경고: 작은따옴표와 \$가 함께 있어 값이 바뀔 수 있습니다: ${name##*/}" >&2
        echo "${name##*/}=$value"
      else
        echo "${name##*/}='$value'"
      fi
    done
}

# <서비스>/files/<파일 이름>의 base64 값을 파일로 풀어 컨테이너의 /run/secrets/stockdrop에 읽기 전용으로 붙입니다.
write_files() {
  local svc=$1 dir=/etc/stockdrop/files/$1
  rm -rf "$dir"
  mkdir -p "$dir"
  aws ssm get-parameters-by-path --region "$REGION" --path "$PARAM_PATH/$svc/files" \
    --with-decryption --query 'Parameters[].[Name,Value]' --output text |
    while IFS=$'\t' read -r name value; do
      [ -n "$name" ] && echo "$value" | base64 -d > "$dir/${name##*/}"
    done
  chmod 755 "$dir"
  find "$dir" -type f -exec chmod 444 {} +
}

# S3Mock(로컬 임시 저장소)용 값은 운영에 들어가면 안 됩니다. 환경변수는 prod 설정 파일보다 우선하므로
# SSM에 실수로 남아 있어도 여기서 빼고, 이름만 로그에 남깁니다(값은 출력하지 않음). 운영은 실제 S3 + 인스턴스 역할입니다.
drop_local_storage() {
  local line name
  while IFS= read -r line; do
    name=${line%%=*}
    if [[ "$name" =~ ^(PRODUCT|QUERY|ORDER|AI)_IMAGES_(ENDPOINT|LOCAL)$ ]]; then
      echo "제외(S3Mock 설정): $1 $name" >&2
      continue
    fi
    printf '%s\n' "$line"
  done
}

# 서비스 하나짜리 Compose 파일입니다. 이미지 태그·메모리·종료 대기 시간만 서비스마다 다릅니다.
write_compose() {
  local svc=$1 image=$2 mem=$3
  mkdir -p /etc/stockdrop/compose
  cat > "/etc/stockdrop/compose/$svc.yaml" <<YAML
name: $svc
services:
  $svc:
    image: $image
    container_name: $svc
    restart: unless-stopped
    # 서비스가 EC2 사설 IP와 호스트 포트로 Eureka에 등록되도록 호스트 네트워크를 씁니다.
    network_mode: host
    mem_limit: ${mem}m
    env_file: /etc/stockdrop/$svc.env
    volumes:
      - /etc/stockdrop/files/$svc:/run/secrets/stockdrop:ro
    # Spring graceful shutdown(기본 30초)과 Eureka 등록 해제가 끝날 시간을 줍니다.
    stop_grace_period: 40s
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
YAML
}

deploy() {
  local svc=$1 port=$2 mem=$3
  local tag
  if [ "$svc" = "eureka" ] && [ -z "$EUREKA_SELF_IP" ]; then
    echo "skip eureka: 이 서버에 Eureka 고정 주소가 없습니다(증설 서버)"
    return
  fi
  tag=$(param "$PARAM_PATH/release/$svc")
  # CD가 아직 이미지를 올리지 않은 서비스는 건너뜁니다. 없는 이미지를 실행했다고 보고하지 않습니다.
  if [ -z "$tag" ] || [ "$tag" = "None" ]; then
    echo "skip $svc: $PARAM_PATH/release/$svc 없음"
    return
  fi

  local env_file=/etc/stockdrop/$svc.env
  umask 077
  # 인프라가 정하는 공통 값을 먼저 쓰고, SSM의 서비스별 값이 같은 이름이면 뒤에서 덮어씁니다.
  {
    echo "SPRING_PROFILES_ACTIVE=prod"
    echo "SERVICE_HOSTNAME=$PRIVATE_IP"
    echo "SERVICE_PORT=$port"
    echo "SERVER_PORT=$port"
    echo "SERVICE_INSTANCE_ID=$svc-$INSTANCE_ID"
    echo "EUREKA_CLIENT_ENABLED=true"
    echo "EUREKA_DEFAULT_ZONE=$EUREKA_ZONE"
    echo "KAFKA_BOOTSTRAP_SERVERS=$KAFKA_BOOTSTRAP_SERVERS"
    if [ "$svc" = "eureka" ]; then
      # Eureka는 고정 ENI 주소로 등록하고, 자기를 뺀 나머지 노드를 peer로 지정합니다.
      echo "EUREKA_HOSTNAME=$EUREKA_SELF_IP"
      echo "EUREKA_INSTANCE_ID=eureka-$AZ"
      for h in $EUREKA_IPS; do
        [ "$h" != "$EUREKA_SELF_IP" ] && echo "EUREKA_PEER_URL=http://$h:8761/eureka/"
      done
    fi
    # 값은 한 줄이어야 합니다. shared 다음에 서비스별 값을 써서 서비스 값이 우선합니다.
    env_lines "$PARAM_PATH/shared"
    env_lines "$PARAM_PATH/$svc"
  } | tac | awk -F= '!seen[$1]++' | tac | drop_local_storage "$svc" > "$env_file"
  write_files "$svc"

  local image="$REGISTRY/$REPO_PREFIX/$svc:$tag"
  retry docker pull -q "$image" >/dev/null
  write_compose "$svc" "$image" "$mem"
  docker compose -f "/etc/stockdrop/compose/$svc.yaml" up -d --remove-orphans >/dev/null
  echo "deployed $svc:$tag"
  if [ "$WAIT" = 1 ]; then wait_ready "$svc" "$port"; fi
}

# ALB·LoadBalancer와 같은 readiness 경로가 200이 될 때까지 최대 3분 기다립니다.
wait_ready() {
  local svc=$1 port=$2
  for _ in $(seq 1 36); do
    if curl -sf -o /dev/null "http://127.0.0.1:$port/actuator/health/readiness"; then
      echo "ready $svc"
      return 0
    fi
    sleep 5
  done
  echo "준비되지 않음: $svc (3분). docker logs $svc로 원인을 확인하세요." >&2
  return 1
}

failed=0
for entry in $SERVICES; do
  IFS=: read -r svc port mem <<< "$entry"
  if [ $# -eq 0 ] || [[ " $* " == *" $svc "* ]]; then
    # 서비스 하나가 실패해도 나머지는 띄웁니다. 실패 여부는 마지막 종료 코드로 알립니다.
    deploy "$svc" "$port" "$mem" || { echo "실패: $svc" >&2; failed=1; }
  fi
done
exit $failed
