#!/bin/bash
# Command DB 백업입니다. DB마다 pg_dump(custom 형식)와 역할 정의(비밀번호 제외)를 S3에 올립니다.
# systemd 타이머(stockdrop-command-db-backup.timer)가 매일 실행하며, 수동 실행도 됩니다. 보관 기간은 S3 수명 주기가 정합니다.
# 같은 AZ 장애에는 EBS 재연결, AZ를 넘는 복구에는 이 백업(또는 EBS 스냅샷)을 씁니다(docs/operations.md).
set -euo pipefail
cd "$(dirname "$0")"
: "${BACKUP_BUCKET:?BACKUP_BUCKET required}"
: "${AWS_REGION:?AWS_REGION required}"

CONTAINER=stockdrop-command-postgres
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
PREFIX="command-db/$(date -u +%Y/%m/%d)/$STAMP"
WORK=$(mktemp -d /data/backup-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# 컨테이너 안에서 관리자 계정으로 덤프합니다(컨테이너 내부 접속은 비밀번호 없이 허용됩니다).
docker exec "$CONTAINER" pg_dumpall -U command_admin --roles-only --no-role-passwords > "$WORK/roles.sql"
for db in product_command order_command; do
  docker exec "$CONTAINER" pg_dump -U command_admin -d "$db" --format=custom --compress=6 > "$WORK/$db.dump"
  # 덤프가 읽히는지 바로 확인합니다. 깨진 파일을 정상 백업으로 올리지 않습니다.
  docker exec -i "$CONTAINER" pg_restore --list < "$WORK/$db.dump" > /dev/null
done
(cd "$WORK" && sha256sum ./*.dump roles.sql > SHA256SUMS)

aws s3 cp --region "$AWS_REGION" --recursive --only-show-errors "$WORK" "s3://$BACKUP_BUCKET/$PREFIX/"
echo "백업 완료: s3://$BACKUP_BUCKET/$PREFIX/ ($(du -sh "$WORK" | cut -f1))"
