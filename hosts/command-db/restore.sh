#!/bin/bash
# Command DB 백업 복원입니다. 기본은 "검증 복원"으로, 원본을 건드리지 않고 <db>_restore_check에 복원해
# 테이블별 행 수를 원본과 비교한 뒤 검증용 DB를 지웁니다.
#   restore.sh <S3 경로> <db>                 검증 복원 (예: command-db/2026/11/16/20261116T183000Z product_command)
#   restore.sh <S3 경로> <db> --replace       원본 DB를 백업 시점으로 되돌림. 구매 풀 서비스를 먼저 멈춰야 합니다.
#   restore.sh --list                         최근 백업 목록
set -euo pipefail
: "${BACKUP_BUCKET:?BACKUP_BUCKET required}"
: "${AWS_REGION:?AWS_REGION required}"
CONTAINER=stockdrop-command-postgres

if [ "${1:-}" = "--list" ]; then
  aws s3 ls --region "$AWS_REGION" --recursive "s3://$BACKUP_BUCKET/command-db/" | grep SHA256SUMS | tail -20
  exit 0
fi

SRC="${1:?S3 경로가 필요합니다}"
DB="${2:?DB 이름이 필요합니다(product_command 또는 order_command)}"
MODE="${3:-check}"
case "$DB" in product_command) OWNER=product ;; order_command) OWNER=orders ;; *) echo "알 수 없는 DB: $DB" >&2; exit 2 ;; esac

WORK=$(mktemp -d /data/restore-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
aws s3 cp --region "$AWS_REGION" --only-show-errors "s3://$BACKUP_BUCKET/$SRC/$DB.dump" "$WORK/"
aws s3 cp --region "$AWS_REGION" --only-show-errors "s3://$BACKUP_BUCKET/$SRC/SHA256SUMS" "$WORK/"
(cd "$WORK" && grep -E "[ *]./$DB.dump$" SHA256SUMS | sha256sum -c --quiet)

psql_admin() { docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U command_admin "$@"; }
counts() {
  # 업무 스키마 테이블의 정확한 행 수입니다. 통계 추정값을 쓰지 않습니다.
  psql_admin -d "$1" -tA <<'SQL'
SELECT string_agg(format('%s=%s', t, n), ' ' ORDER BY t) FROM (
  SELECT c.oid::regclass::text AS t,
         (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from %s', c.oid::regclass), false, true, '')))[1]::text AS n
  FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
  WHERE c.relkind = 'r' AND s.nspname IN ('product', 'orders')) x;
SQL
}

if [ "$MODE" = "--replace" ]; then
  echo "원본 $DB를 백업 시점으로 되돌립니다. 10초 안에 Ctrl+C로 취소할 수 있습니다."
  sleep 10
  psql_admin -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB' AND pid <> pg_backend_pid();" >/dev/null
  # 관리자로 복원하되 덤프에 기록된 소유자(product·orders)를 그대로 되살립니다. 앱 계정은 스키마를 만들 권한이 없기 때문입니다.
  # 한 트랜잭션으로 실행해 중간에 실패하면 지운 객체까지 모두 원래대로 돌아갑니다.
  docker exec -i "$CONTAINER" pg_restore -U command_admin -d "$DB" --clean --if-exists --single-transaction --exit-on-error < "$WORK/$DB.dump"
  owner=$(psql_admin -d "$DB" -tA -c "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname IN ('product', 'orders')")
  [ "$owner" = "$OWNER" ] || { echo "복원 후 스키마 소유자가 $OWNER가 아닙니다: $owner" >&2; exit 1; }
  echo "복원 완료: $DB(소유자 $OWNER). 구매 풀 서비스를 다시 시작하세요."
  exit 0
fi

CHECK="${DB}_restore_check"
psql_admin -d postgres -c "DROP DATABASE IF EXISTS $CHECK;" -c "CREATE DATABASE $CHECK TEMPLATE template0;"
docker exec -i "$CONTAINER" pg_restore -U command_admin -d "$CHECK" --single-transaction --exit-on-error < "$WORK/$DB.dump"
restored=$(counts "$CHECK")
current=$(counts "$DB")
psql_admin -d postgres -c "DROP DATABASE $CHECK;"
echo "백업 시점 행 수: ${restored:-(테이블 없음)}"
echo "현재 원본 행 수: ${current:-(테이블 없음)}"
echo "검증 복원 성공: 덤프가 오류 없이 복원되었습니다. 행 수 차이는 백업 이후 변경분입니다."
