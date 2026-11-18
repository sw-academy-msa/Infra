#!/bin/bash
# Command DB를 띄우고 init.sql로 DB·계정을 맞춥니다. 비밀번호는 SSM에서 읽어 화면·명령 인자·로그에 남기지 않습니다.
# 필요한 SSM 값(SecureString):
#   /stockdrop/prod/command-db/ADMIN_PASSWORD, /stockdrop/prod/command-db/METRICS_PASSWORD
#   /stockdrop/prod/product-command-service/DB_PASSWORD, /stockdrop/prod/order-command-service/DB_PASSWORD
set -euo pipefail
cd "$(dirname "$0")"

: "${AWS_REGION:?AWS_REGION required}"
: "${PRIVATE_IP:?PRIVATE_IP required}"
PREFIX="${PARAMETER_PATH:-/stockdrop/prod}"

secret() {
  local value
  value=$(aws ssm get-parameter --region "$AWS_REGION" --name "$PREFIX/$1" --with-decryption \
    --query Parameter.Value --output text 2>/dev/null) || { echo "SSM 값이 없습니다: $PREFIX/$1" >&2; exit 1; }
  # psql 변수와 파일로 안전하게 넘기도록 문자 종류를 제한합니다. 예: openssl rand -hex 32
  [[ "$value" =~ ^[A-Za-z0-9_.~-]{20,200}$ ]] || { echo "형식이 맞지 않습니다(영문·숫자 20자 이상): $PREFIX/$1" >&2; exit 1; }
  printf '%s' "$value"
}

ADMIN=$(secret command-db/ADMIN_PASSWORD)
METRICS=$(secret command-db/METRICS_PASSWORD)
PRODUCT=$(secret product-command-service/DB_PASSWORD)
ORDERS=$(secret order-command-service/DB_PASSWORD)

# 컨테이너 사용자만 읽을 수 있게 둡니다. postgres 이미지는 uid 70, exporter는 nobody(65534)로 실행됩니다.
umask 077
mkdir -p secrets
printf '%s' "$ADMIN" > secrets/admin-password && chown 70:70 secrets/admin-password && chmod 400 secrets/admin-password
printf '%s' "$METRICS" > secrets/metrics-password && chown 65534:65534 secrets/metrics-password && chmod 400 secrets/metrics-password

# 위 umask 077 때문에 root 전용(700)으로 만들어지면 uid 70(postgres)이 들어가지 못해 초기화가 실패합니다.
# Kafka·모니터링처럼 데이터 폴더를 컨테이너 사용자 소유로 둡니다.
mkdir -p /data/postgres
chown 70:70 /data/postgres
chmod 700 /data/postgres
PRIVATE_IP="$PRIVATE_IP" docker compose up -d --wait

# 비밀번호는 표준 입력의 psql 변수로만 넘깁니다. ps나 셸 기록에 남지 않습니다.
{
  printf '\\set product_password %s\n' "$PRODUCT"
  printf '\\set orders_password %s\n' "$ORDERS"
  printf '\\set metrics_password %s\n' "$METRICS"
  cat init.sql
} | docker exec -i stockdrop-command-postgres psql -X -q -U command_admin -d postgres

unset ADMIN METRICS PRODUCT ORDERS

# 매일 03:30(KST) S3 백업 타이머입니다. 버킷 이름은 Terraform S3 모듈 규칙(<이름>-command-db-backups-<계정>)을 따릅니다.
TOKEN=$(curl -sfX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
ACCOUNT=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document |
  sed -n 's/.*"accountId" *: *"\([0-9]*\)".*/\1/p')
BUCKET="${BACKUP_BUCKET:-${NAME:-stockdrop-prod}-command-db-backups-$ACCOUNT}"
DIR=$(pwd)
umask 022
printf 'AWS_REGION=%s\nBACKUP_BUCKET=%s\n' "$AWS_REGION" "$BUCKET" > /etc/stockdrop-command-db-backup.env
cat > /etc/systemd/system/stockdrop-command-db-backup.service <<UNIT
[Unit]
Description=STOCKDROP Command DB backup to S3
After=docker.service

[Service]
Type=oneshot
EnvironmentFile=/etc/stockdrop-command-db-backup.env
ExecStart=/bin/bash $DIR/backup.sh
UNIT
cat > /etc/systemd/system/stockdrop-command-db-backup.timer <<'UNIT'
[Unit]
Description=Daily STOCKDROP Command DB backup

[Timer]
OnCalendar=*-*-* 18:30:00 UTC
# 서버가 꺼져 있어 놓친 백업은 켜진 뒤 바로 실행합니다.
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now stockdrop-command-db-backup.timer >/dev/null
echo "백업 버킷: $BUCKET (매일 18:30 UTC)"
docker compose ps --format '{{.Name}} {{.Status}}'
