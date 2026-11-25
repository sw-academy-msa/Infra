#!/bin/bash
# 일반 RDS의 서비스별 DB·계정·스키마를 만듭니다. RDS는 사설망에만 있으므로 모니터링 EC2에서 SSM으로 실행합니다.
#   deploy.ps1 -Role rds  (RDS 주소와 마스터 Secret ARN을 찾아 이 스크립트에 넘깁니다)
# 마스터 비밀번호는 Secrets Manager, 서비스 비밀번호는 SSM /<경로>/<서비스>/DB_PASSWORD에서 읽고 화면·인자에 남기지 않습니다.
set -euo pipefail
cd "$(dirname "$0")"

: "${AWS_REGION:?AWS_REGION required}"
: "${RDS_HOST:?RDS_HOST required}"
: "${RDS_SECRET_ARN:?RDS_SECRET_ARN required}"
PREFIX="${PARAMETER_PATH:-/stockdrop/prod}"

# 서비스: DB 이름, 계정(=스키마) 이름입니다. 각 서비스의 DB_URL·DB_USERNAME과 같아야 합니다.
SERVICES="account-service:stockdrop:account
product-query-service:product_query:product_query
order-query-service:orders_query:orders_query
payment-service:payment:payment
ai-service:ai_service:ai
notification-service:notification_service:notification
coupon-service:coupon:coupon"

secret_json=$(aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$RDS_SECRET_ARN" \
  --query SecretString --output text)
MASTER_USER=$(printf '%s' "$secret_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])')
PGPASSWORD=$(printf '%s' "$secret_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
export PGPASSWORD
unset secret_json

# psql 클라이언트는 컨테이너로 씁니다. 비밀번호는 환경변수 이름만 넘겨 명령 인자에 값이 보이지 않습니다.
psql_rds() {
  docker run --rm -i -e PGPASSWORD postgres:17-alpine psql -X -q \
    "host=$RDS_HOST port=5432 dbname=postgres user=$MASTER_USER sslmode=require"
}

failed=0
while IFS=: read -r svc db role; do
  password=$(aws ssm get-parameter --region "$AWS_REGION" --name "$PREFIX/$svc/DB_PASSWORD" --with-decryption \
    --query Parameter.Value --output text 2>/dev/null) || { echo "SSM 값이 없습니다: $PREFIX/$svc/DB_PASSWORD" >&2; failed=1; continue; }
  [[ "$password" =~ ^[A-Za-z0-9_.~-]{20,200}$ ]] || { echo "형식이 맞지 않습니다(영문·숫자 20자 이상): $svc" >&2; failed=1; continue; }
  {
    printf '\\set db %s\n\\set role %s\n\\set password %s\n' "$db" "$role" "$password"
    cat service.sql
  } | psql_rds || { echo "실패: $svc" >&2; failed=1; }
done <<< "$SERVICES"

unset PGPASSWORD password
exit $failed
