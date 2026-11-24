# 운영 설정값·비밀값 목록 (SSM Parameter Store)

서비스 서버의 `stockdrop-deploy`가 이 경로를 읽어 컨테이너 환경변수와 파일을 만듭니다.
각 서비스의 `application.yaml`, `application-prod.yaml`에서 기본값이 없는 값과, 현재 서버에서 켜 둔 기능 플래그를 기준으로 정리했습니다.

## 입력 스크립트

`scripts/put-parameters.ps1`이 아래 값을 모두 넣습니다. 여러 번 실행해도 되고, 이미 있는 비밀값은 덮어쓰지 않습니다.

```powershell
.\scripts\put-parameters.ps1 -DryRun                             # 넣을 이름만 확인
.\scripts\put-parameters.ps1                                     # apply 전: DB 공통 비밀번호·외부 키 입력
cd envs\prod; terraform output -json > ..\..\tf-output.json; cd ..\..
.\scripts\put-parameters.ps1 -TerraformOutput .\tf-output.json   # apply 뒤: RDS·Redis 주소
Remove-Item .\tf-output.json
```

- 기존 서버 데이터를 옮길 때는 `-EnvRoot <서비스 폴더들이 있는 경로>`를 줍니다. JWT 서명 키·판매자 암호화 키·푸시 암호화 키·VAPID 키·서비스 인증 비밀값을 그 서버의 `.env`, `.keys`에서 그대로 가져옵니다. 다르면 기존 데이터를 복호화하지 못합니다.
- 새로 만드는 값에는 Node.js(키 생성)와 Docker(BCrypt 해시)가 필요합니다.
- 값은 컨테이너 env 파일에 작은따옴표로 감싸 들어갑니다. Compose가 `$`를 변수로 해석해 BCrypt 해시가 깨지는 것을 막기 위해서입니다. 값에 작은따옴표를 넣지 않습니다.

## 규칙

| 경로 | 용도 |
|---|---|
| `/stockdrop/prod/shared/<이름>` | 모든 서비스에 들어가는 공통 값 |
| `/stockdrop/prod/<서비스>/<이름>` | 서비스별 값. shared와 이름이 같으면 이 값이 우선합니다. |
| `/stockdrop/prod/<서비스>/files/<파일명>` | base64로 저장한 파일. 컨테이너의 `/run/secrets/stockdrop/<파일명>`에 읽기 전용으로 붙습니다. |
| `/stockdrop/prod/release/<서비스>` | 배포할 이미지 태그. CD가 갱신합니다. |

- **S** 표시는 `SecureString`, 나머지는 `String`으로 저장합니다.
- 값은 한 줄이어야 합니다. 4KB를 넘으면 Advanced 등급(유료)이 필요합니다.
- 아래 값은 부팅 스크립트가 자동으로 넣으므로 저장하지 않습니다: `SPRING_PROFILES_ACTIVE`, `SERVICE_HOSTNAME`, `SERVICE_PORT`, `SERVER_PORT`, `SERVICE_INSTANCE_ID`, `EUREKA_CLIENT_ENABLED`, `EUREKA_DEFAULT_ZONE`, `KAFKA_BOOTSTRAP_SERVERS`, Eureka의 `EUREKA_HOSTNAME`·`EUREKA_INSTANCE_ID`·`EUREKA_PEER_URL`.
- 도메인은 `stockdrop.cloud`입니다. `<RDS>`는 `terraform output rds`의 endpoint, `<버킷:이름>`은 `terraform output s3_buckets`의 값입니다. Command DB는 내부 DNS `command-db.stockdrop.internal`입니다.

## shared

| 이름 | 예 / 설명 |
|---|---|
| `JWT_ISSUER` | `https://api.stockdrop.cloud`. Account가 발급하고 모든 서비스가 같은 값으로 검증합니다. |
| `JWT_AUDIENCE` | `stockdrop-api` |
| `ACCOUNT_JWKS_URI` | `https://api.stockdrop.cloud/.well-known/jwks.json`. Gateway가 Account로 전달하는 고정 주소입니다. |
| `APP_ALLOWED_ORIGINS` | `https://stockdrop-app.vercel.app` (프론트 주소가 더 있으면 쉼표로 추가). Account, Gateway, PurchaseGateway가 씁니다. |
| `MONITORING_SCRAPE_TOKEN` **S** | 32자 이상 임의 문자열. 모니터링 EC2의 `secrets/scrape-token`과 같은 값입니다. |
| `MONITORING_OUTBOX_ENABLED` | `true` (Outbox가 없는 서비스는 무시합니다) |
| `ORDER_SERVICE_SUBJECT` | Order가 다른 서비스를 호출할 때의 주체 이름. Account, ProductCommand, OrderCommand가 같은 값을 씁니다. |
| `NOTIFICATION_SERVICE_SUBJECT` | AI, Notification이 같은 값을 씁니다. |
| `ACCOUNT_WITHDRAWAL_SUBJECT` | 탈퇴 차단 호출 주체. Account, ProductCommand, OrderCommand, Payment가 같은 값을 씁니다. |
| `REDIS_HOST` | `terraform output redis`의 `primary_endpoint`. 장애 전환 뒤에도 같은 이름입니다. |
| `REDIS_PORT` | `6379` |
| `REDIS_SSL_ENABLED` | `true` (전송 암호화가 켜져 있어 TLS 없이는 접속되지 않습니다) |
| `REDIS_USERNAME` | `stockdrop-app` |
| `REDIS_PASSWORD` **S** | 16~128자, 공백·따옴표·@ 없이. 넣은 뒤 `scripts/redis-app-user.ps1`을 실행해야 Redis에 반영됩니다. |

Redis 값은 아직 Redis를 쓰는 서비스가 없어 앱 설정과 이름을 맞추는 단계가 남았습니다. Spring Boot 예시:

```yaml
spring:
  data:
    redis:
      host: ${REDIS_HOST}
      port: ${REDIS_PORT:6379}
      username: ${REDIS_USERNAME}
      password: ${REDIS_PASSWORD}
      ssl:
        enabled: ${REDIS_SSL_ENABLED:true}
      timeout: 2s
```

Redis는 캐시입니다. 재고·주문의 기준은 Command DB이며 Redis가 비어도 동작해야 합니다.

## 서비스별

모든 DB 서비스 공통: `DB_URL`, `DB_USERNAME`, `DB_PASSWORD` **S**

| 서비스 | DB_URL |
|---|---|
| account-service | `jdbc:postgresql://<RDS>:5432/stockdrop` |
| product-query-service | `jdbc:postgresql://<RDS>:5432/product_query` |
| order-query-service | `jdbc:postgresql://<RDS>:5432/orders_query` |
| payment-service | `jdbc:postgresql://<RDS>:5432/payment` |
| ai-service | `jdbc:postgresql://<RDS>:5432/ai_service` |
| notification-service | `jdbc:postgresql://<RDS>:5432/notification_service` |
| product-command-service | `jdbc:postgresql://command-db.stockdrop.internal:5432/product_command` |
| order-command-service | `jdbc:postgresql://command-db.stockdrop.internal:5432/order_command` |

DB 이름은 현재 로컬과 같게 맞췄습니다. 서비스마다 전용 계정을 만듭니다. 비밀번호는 입력 스크립트가 공통 값 하나를 받아 서비스 DB 8개와 Command DB 관리자·지표 계정에 넣습니다(20자 이상, 영문·숫자·`_.~-`만).

### account-service

| 이름 | 값 |
|---|---|
| `JWT_SIGNING_KEY_LOCATION` | `file:/run/secrets/stockdrop/account-signing.jwk` |
| `files/account-signing.jwk` **S** | 서명 키 JWK 파일의 base64. A/B Account가 같은 키를 써야 합니다. |
| `SELLER_DATA_ENCRYPTION_KEY` **S** | 판매자 계좌 등 암호화 키 |
| `ORDER_SERVICE_SECRET_HASH` **S** | Order 서비스 인증 비밀값의 BCrypt 해시 |
| `account.service-auth.clients.notification-service.subject` | shared `NOTIFICATION_SERVICE_SUBJECT`와 같은 값 |
| `account.service-auth.clients.notification-service.secret-hash` **S** | Notification `NOTIFICATION_CLIENT_SECRET`의 BCrypt 해시 |
| `account.service-auth.clients.notification-service.scopes` | `account.notifications.read,ai.personalization.read` |
| `MAIL_HOST`, `MAIL_USERNAME`, `MAIL_FROM` | 메일 발송 계정 |
| `MAIL_PASSWORD` **S** | 메일 앱 비밀번호 |
| `SELLER_CERTIFICATE_BUCKET` | `<버킷:seller-certificates>` |
| `ACCOUNT_SERVICE_AUTH_ENABLED` | `true` |
| `ACCOUNT_WITHDRAWAL_ENABLED` | `true` |
| `ACCOUNT_OUTBOX_PUBLISHER_ENABLED` | `true` |

### product-command-service

| 이름 | 값 |
|---|---|
| `PRODUCT_OUTBOX_PUBLISHER_ENABLED` | `true` |
| `PRODUCT_AI_CONSUMER_ENABLED` | `true` |
| `PRODUCT_IMAGES_ENABLED` | `true` |
| `PRODUCT_IMAGES_BUCKET` | `<버킷:product-images>` |
| `PRODUCT_IMAGES_REGION` | `ap-northeast-2` |

`*_IMAGES_LOCAL`, `*_IMAGES_ENDPOINT`(`AI_IMAGES_LOCAL` 포함)는 로컬 S3Mock용이라 운영에는 넣지 않습니다. 실수로 넣어도 `stockdrop-deploy`가 걸러 내고 이름만 로그에 남깁니다. 운영은 EC2 인스턴스 역할로 실제 S3에 접속하고, presigned URL도 실제 S3 주소(`https://<버킷>.s3.ap-northeast-2.amazonaws.com/...`)로 만들어집니다. 브라우저 업로드는 버킷 CORS(`browser_origins`)가 허용합니다.

### product-query-service

| 이름 | 값 |
|---|---|
| `QUERY_EVENTS_ENABLED` | `true` |
| `QUERY_IMAGES_ENABLED` | `true` |
| `QUERY_IMAGES_BUCKET` | `<버킷:product-images>` (product-command와 같은 버킷) |
| `QUERY_IMAGES_REGION` | `ap-northeast-2` |

### order-command-service

| 이름 | 값 |
|---|---|
| `ORDER_CHECKOUT_TERMS_VERSION` | `checkout-v1` |
| `ORDER_ACCOUNT_ENABLED`, `ORDER_PRODUCT_ENABLED` | `true` |
| `ORDER_PRODUCT_SERVICE_TOKEN` **S** | Product 내부 호출 토큰 |
| `ORDER_SERVICE_AUTH_ENABLED` | `true` |
| `ORDER_SERVICE_CLIENT_ID` | `order-command-service` |
| `ORDER_SERVICE_CLIENT_SECRET` **S** | Account의 `ORDER_SERVICE_SECRET_HASH`와 짝인 원문 비밀값 |
| `ORDER_OUTBOX_PUBLISHER_ENABLED` | `true` |
| `ORDER_PAYMENT_EVENTS_ENABLED` | `true` |
| `ORDER_IMAGES_ENABLED` | `true` |
| `ORDER_IMAGES_BUCKET` | `<버킷:inquiry-images>` |

현재 서버는 `ORDER_PAYMENT_ENABLED=false`입니다. Kafka 결제 이벤트 방식만 쓰는 상태라면 운영도 넣지 않습니다.

### order-query-service

| 이름 | 값 |
|---|---|
| `ORDER_QUERY_EVENTS_ENABLED` | `true` |

### payment-service

| 이름 | 값 |
|---|---|
| `TOSS_CLIENT_KEY` | 토스 클라이언트 키 (공개 가능) |
| `TOSS_SECRET_KEY` **S** | 토스 시크릿 키 |
| `PAYMENT_TOSS_ENABLED`, `PAYMENT_MESSAGING_ENABLED`, `PAYMENT_PROCESSING_ENABLED`, `PAYMENT_OUTBOX_PUBLISHER_ENABLED` | `true` |

### ai-service

| 이름 | 값 |
|---|---|
| `OPENAI_API_KEY` **S** | OpenAI 키 |
| `OPENAI_VISION_MODEL` | 현재 서버와 같은 모델 이름 |
| `AI_CONSUMER_ENABLED`, `AI_WORKER_ENABLED`, `AI_OUTBOX_PUBLISHER_ENABLED`, `AI_VISION_ENABLED` | `true` |
| `PRODUCT_IMAGES_BUCKET` | `<버킷:product-images>` |
| `PRODUCT_IMAGES_REGION` | `ap-northeast-2` |

GA 추천(`AI_GA_ENABLED`, `GA_BIGQUERY_*`)과 개인화(`AI_PERSONALIZATION_ENABLED`)는 현재 서버에서도 꺼져 있습니다.

### notification-service

| 이름 | 값 |
|---|---|
| `NOTIFICATION_CLIENT_SECRET` **S** | 알림 서비스 인증 비밀값 |
| `VAPID_PUBLIC_KEY`, `VAPID_SUBJECT` | 웹 푸시 공개키와 연락처 |
| `VAPID_PRIVATE_KEY` **S** | 웹 푸시 개인키 |
| `PUSH_ENCRYPTION_KEY` **S** | 구독 정보 암호화 키 |
| `WEB_PUSH_ENABLED`, `NOTIFICATION_CONSUMER_ENABLED`, `NOTIFICATION_BUSINESS_CONSUMER_ENABLED`, `NOTIFICATION_PRODUCT_ALERT_ENABLED`, `NOTIFICATION_WORKER_ENABLED` | `true` |

### gateway, purchase-gateway, eureka

shared 값만 사용합니다. 서비스별로 넣을 값이 없습니다.

## S3 버킷

`modules/s3`가 만드는 비공개 버킷 3개입니다. 서비스 EC2 역할(app)이 이 버킷만 읽고 쓸 수 있습니다.

| 버킷 | 쓰는 서비스 | 브라우저 CORS |
|---|---|---|
| `seller-certificates` | account-service | 없음 (서버만 접근) |
| `product-images` | product-command, product-query, ai | `browser_origins`에서 PUT, GET, HEAD |
| `inquiry-images` | order-command | `browser_origins`에서 PUT, GET, HEAD |

- 브라우저는 서비스가 발급한 presigned URL로만 올리고 받습니다. 공개 읽기는 없습니다.
- 임시 업로드 경로(`product-uploads/`, `order-inquiry-uploads/`)는 2일 뒤 자동 삭제됩니다.
- 버전 관리가 켜져 있어 지우거나 덮어쓴 파일은 30일 동안 이전 버전으로 남습니다.

## 단일 EC2 (hosts/deploy.ps1)

서버가 직접 읽습니다. 모두 SecureString이며 `openssl rand -hex 32`처럼 영문·숫자로 만듭니다(Command DB 값은 20자 이상, 영문·숫자·`_.~-`만).

| 경로 | 쓰는 곳 |
|---|---|
| `/stockdrop/prod/command-db/ADMIN_PASSWORD` | Command DB 관리자(`command_admin`). 최초 초기화 때만 적용됩니다. |
| `/stockdrop/prod/command-db/METRICS_PASSWORD` | DB 지표 수집 전용 계정(`metrics`, `pg_monitor` 권한만) |
| `/stockdrop/prod/product-command-service/DB_PASSWORD` | 서비스와 같은 값. Command DB의 `product` 계정 비밀번호가 됩니다. |
| `/stockdrop/prod/order-command-service/DB_PASSWORD` | 서비스와 같은 값. Command DB의 `orders` 계정 비밀번호가 됩니다. |
| `/stockdrop/prod/shared/MONITORING_SCRAPE_TOKEN` | 서비스와 같은 값. Prometheus의 `secrets/scrape-token`이 됩니다. |
| `/stockdrop/prod/monitoring/GRAFANA_PASSWORD` | Grafana `admin` 비밀번호(12자 이상) |

Command DB의 `DB_USERNAME`은 product-command-service가 `product`, order-command-service가 `orders`입니다.

## 풀 및 메모리 변수

`general_services`는 core 네 서비스, `query_services`는 query 네 서비스입니다. Eureka memory_mb=384, AI memory_mb=768이며 나머지 상한은 README 표를 따릅니다. `query_instance_type=t4g.medium`, `query_min_size=2`, `query_max_size=3`, `purchase_instance_type=t4g.medium`입니다. `pool_health_check_type`은 general/purchase에 적용되며 query는 EC2로 고정합니다.

서비스 SSM 경로와 release 경로는 이동 전후 동일합니다. eureka_hosts를 공유하고 query의 eureka_enis는 빈 목록입니다. `ACCOUNT_JWKS_URI`나 Eureka 주소가 localhost 또는 이전 인스턴스 IP를 가리키는 override는 이동 전에 비밀값을 출력하지 않는 검사로 확인합니다. 메모리 변경은 user_data와 LT 버전을 바꾸지만 기존 컨테이너 상한을 바꾸지는 않습니다. general의 automatic_instance_refresh=false이므로 별도 승인한 유지보수가 필요합니다.
