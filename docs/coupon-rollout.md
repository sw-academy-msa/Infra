# 쿠폰 배포 준비와 되돌리기

이 PR은 선언과 문서만 바꿉니다. 운영 apply, SSM 등록, DB 및 토픽 생성은 별도 승인 뒤 실행합니다.

## 배포 순서

1. 승인된 Infra plan에서 coupon-service ECR 및 CD 역할, app SG 8088을 확인합니다. core는 general 풀입니다. general_services로 부팅 시 pool.conf SERVICES가 만들어지며 coupon-service:8088:512가 포함됩니다. 두 서버 컨테이너 상한 합계는 각 2304MiB입니다. 롤링 교체 자동 실행은 없으므로 한 대씩 pool.conf와 compose를 반영하고 available 메모리 및 RDS 연결 수를 확인합니다.
2. DB_PASSWORD를 보안 입력으로 준비한 뒤 hosts/deploy.ps1 -Role rds로 coupon DB, coupon 계정과 coupon 스키마를 만듭니다. 기존 서비스별 DB 절차와 hosts/rds/service.sql을 사용합니다. 업무 테이블은 CouponService Flyway V1이 생성합니다. 배포와 서버 교체를 겹치지 않게 하고 Hikari max 5, minIdle 1을 유지합니다.
3. 승인 뒤 hosts/kafka/topics.sh를 실행합니다. lifecycle 2개, campaign-targets 및 coupon/campaign notifications는 각 3개 파티션이며 각각 같은 파티션 수의 DLT를 둡니다. 회원제 토픽과 DLT는 기존 선언을 재사용합니다. 자동 토픽 생성은 금지합니다.
4. OrderQuery 할인 전 정산 버전, Payment GA OFF, Notification OFF, Account 서비스 클라이언트 등록 순서로 준비합니다.
5. CouponService 이미지를 준비하고 general 서버 두 대에 순차 배포합니다. API, consumer, scheduler, outbox 순으로 켭니다. 초기값은 모두 false입니다. Monitoring develop의 coupon 수집 대상 PR도 배포 승인에 포함해야 합니다.
6. AI 행동 및 lifecycle 소비를 준비한 뒤 OrderCommand lifecycle ON, coupon OFF로 배포합니다. 격리 환경 E2E 후 coupon ON, Gateway coupon ON 및 FE를 반영합니다. GA MP는 동의와 가명 ID 검증 후 별도로 켭니다.

## SSM 이름

접두사는 /stockdrop/prod/입니다. 아래는 이름과 기본값만 기록하며 비밀값은 출력하거나 Git에 저장하지 않습니다.

- coupon-service/DB_URL, DB_USERNAME(coupon), DB_PASSWORD(SecureString)
- coupon-service/SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE(5), SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE(1)
- coupon-service/COUPON_CLIENT_SECRET(SecureString), shared/COUPON_SERVICE_SUBJECT, shared/ORDER_SERVICE_SUBJECT
- coupon-service/COUPON_API_ENABLED, COUPON_CONSUMER_ENABLED, COUPON_SCHEDULER_ENABLED, COUPON_OUTBOX_PUBLISHER_ENABLED: false
- order-command-service/ORDER_COUPON_ENABLED, ORDER_LIFECYCLE_EVENTS_ENABLED: false
- gateway/GATEWAY_COUPON_ENABLED: false
- payment-service/GA_MEASUREMENT_ID, GA_MP_API_SECRET(SecureString), PAYMENT_GA_MP_ENABLED(false), PAYMENT_CLIENT_SECRET(SecureString)
- shared/PAYMENT_SERVICE_SUBJECT, shared/CAMPAIGN_DEMO_ACCOUNT_IDS
- account-service/account.service-auth.clients.coupon-service.subject, secret-hash(SecureString), scopes(account.notifications.read order.coupon.read)
- account-service/account.service-auth.clients.payment-service.subject, secret-hash(SecureString), scopes(ai.personalization.read)
- 기존 order-command 클라이언트 scope에 coupon.lock을 추가합니다. 비밀은 기존 값을 그대로 유지합니다.
- ai-service/AI_BEHAVIOR_EVENTS_ENABLED(false), AI_CAMPAIGN_MODE(OFF)
- notification-service/NOTIFICATION_COUPON_CONSUMER_ENABLED(false), NOTIFICATION_CAMPAIGN_CONSUMER_ENABLED(false)

공유 파라미터는 기존 pool.conf 배포 스크립트에서 각 컨테이너에 주입합니다. 등록은 운영자가 보안 프롬프트나 콘솔에서 합니다. GA API secret은 Measurement Protocol API secrets에서 생성합니다.

## 되돌리기와 검사

AI_CAMPAIGN_MODE=OFF, 캠페인 pause, ORDER_COUPON_ENABLED=false, GATEWAY_COUPON_ENABLED=false 순으로 새 사용을 끕니다. 잠긴 쿠폰이 정리될 때까지 lifecycle, coupon-outcome API, 복구 scheduler와 Outbox는 유지합니다. Payment GA는 PAYMENT_GA_MP_ENABLED=false로 끕니다. 코드 복구는 merge commit revert PR로 하며 DB, receipt, Outbox, 토픽은 보존합니다. OrderQuery itemsAmount 및 Command 복구 API가 있는 버전이 하한입니다.

user_data는 실제 gzip 바이트 수를 계산하는 16384바이트 precondition을 사용합니다. terraform test의 mock provider 검증은 AWS에 접속하지 않습니다. 운영 plan에서는 새 서비스가 포함된 general 두 대의 이 검사가 통과하는지 다시 확인해야 합니다.
