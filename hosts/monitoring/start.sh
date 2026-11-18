#!/bin/bash
# 모니터링 EC2에 Monitoring 레포를 받아 Prometheus·Grafana·Alertmanager·exporter를 띄웁니다.
# 비밀값은 SSM에서 읽어 레포의 secrets/(Git 제외 경로)에만 둡니다. 다시 실행하면 최신 레포로 갱신합니다.
# 필요한 SSM 값(SecureString):
#   /stockdrop/prod/shared/MONITORING_SCRAPE_TOKEN (서비스와 같은 값), /stockdrop/prod/monitoring/GRAFANA_PASSWORD
set -euo pipefail
cd "$(dirname "$0")"

: "${AWS_REGION:?AWS_REGION required}"
PREFIX="${PARAMETER_PATH:-/stockdrop/prod}"
# 운영은 Monitoring 레포 main을 씁니다. main 머지 시 CD가 이 스크립트를 다시 실행합니다.
REF="${MONITORING_REF:-main}"
DOMAIN="${INTERNAL_DOMAIN:-stockdrop.internal}"
KAFKA="${KAFKA_BOOTSTRAP:-kafka.$DOMAIN:9092}"
COMMAND_DB_METRICS="${COMMAND_DB_METRICS:-command-db.$DOMAIN:9187}"
KAFKA_JMX="${KAFKA_JMX:-kafka.$DOMAIN:9404}"

secret() {
  local value
  value=$(aws ssm get-parameter --region "$AWS_REGION" --name "$PREFIX/$1" --with-decryption \
    --query Parameter.Value --output text 2>/dev/null) || { echo "SSM 값이 없습니다: $PREFIX/$1" >&2; exit 1; }
  # 서비스의 수집 토큰 검사와 같이 32자 미만은 거부합니다.
  [[ ${#value} -ge "$2" ]] || { echo "${2}자 이상이어야 합니다: $PREFIX/$1" >&2; exit 1; }
  printf '%s' "$value"
}

# 공개 레포라 인증 없이 받습니다. 로컬에서 바뀐 추적 파일이 있어도 원격 상태로 맞춥니다(secrets/는 Git 제외).
command -v git >/dev/null || dnf install -y -q git
if [ -d repo/.git ]; then
  git -C repo fetch -q --depth 1 origin "$REF"
  git -C repo checkout -q -f -B "$REF" FETCH_HEAD
else
  git clone -q --depth 1 --branch "$REF" https://github.com/sw-academy-msa/Monitoring.git repo
fi
echo "Monitoring $REF $(git -C repo rev-parse --short HEAD)"

umask 077
mkdir -p repo/secrets/alertmanager
secret shared/MONITORING_SCRAPE_TOKEN 32 > repo/secrets/scrape-token
secret monitoring/GRAFANA_PASSWORD 12 > repo/secrets/grafana-password
# Prometheus는 nobody(65534), Grafana는 472로 실행됩니다.
chown 65534:65534 repo/secrets/scrape-token && chmod 400 repo/secrets/scrape-token
chown 472:472 repo/secrets/grafana-password && chmod 400 repo/secrets/grafana-password
chmod 755 repo/secrets repo/secrets/alertmanager

# 고정 주소 수집 대상입니다. 서비스 EC2는 Prometheus가 태그로 직접 찾습니다.
umask 022
mkdir -p targets
printf '[{"targets":["%s"],"labels":{"service":"kafka"}}]\n' "$KAFKA_JMX" > targets/kafka-broker.json
printf '[{"targets":["kafka-exporter:9308"],"labels":{"service":"kafka"}}]\n' > targets/kafka-consumer.json
printf '[{"targets":["%s"],"labels":{"service":"command-db"}}]\n' "$COMMAND_DB_METRICS" > targets/postgresql.json
cp repo/prometheus/targets/health.json targets/health.json

mkdir -p /data/prometheus /data/alertmanager /data/grafana
chown 65534:65534 /data/prometheus /data/alertmanager
chown 472:472 /data/grafana

compose() {
  KAFKA_BOOTSTRAP="$KAFKA" docker compose -p stockdrop-monitoring \
    -f repo/compose.yaml -f repo/compose.prod.yaml -f compose.override.yaml "$@"
}
compose config --quiet
compose up -d --wait --remove-orphans
# 설정 파일 내용만 바뀌면 컨테이너가 재생성되지 않으므로 재시작 없이 다시 읽게 합니다(수집이 끊기지 않음).
# Grafana 대시보드는 provisioning이 파일 변경을 주기적으로 다시 읽습니다.
compose kill -s SIGHUP prometheus alertmanager >/dev/null
compose ps --format '{{.Name}} {{.Status}}'
