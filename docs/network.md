# 네트워크·포트·보안 그룹

## 서브넷과 주소

| 구간 | AZ1 (2a) | AZ2 (2c) | 기본 경로 | 두는 것 |
|---|---|---|---|---|
| public | 10.20.0.0/24 | 10.20.1.0/24 | Internet Gateway | ALB, NAT 인스턴스 |
| app | 10.20.10.0/24 | 10.20.11.0/24 | NAT(AZ1) + S3 엔드포인트 | 일반·구매 풀, Kafka, Command DB, 모니터링 |
| data | 10.20.20.0/24 | 10.20.21.0/24 | **없음** (VPC 내부만) | RDS, Redis |

| 고정 주소 | 내부 DNS | IP |
|---|---|---|
| Eureka A | `eureka-a.stockdrop.internal` | 10.20.10.10 (AZ1 ENI) |
| Eureka C | `eureka-c.stockdrop.internal` | 10.20.11.10 (AZ2 ENI) |
| Command DB | `command-db.stockdrop.internal` | 10.20.10.20 |
| Kafka | `kafka.stockdrop.internal` | 10.20.10.30 |
| 모니터링 | `monitoring.stockdrop.internal` | 10.20.10.40 |

서비스 설정에는 IP 대신 내부 DNS 이름을 씁니다. IP 고정은 EC2를 다시 만들어도 같은 주소를 쓰기 위한 것입니다.

## 서비스 포트 ↔ 보안 그룹 ↔ Eureka 등록

모든 서비스 컨테이너는 `network_mode: host`라 컨테이너 포트 = 호스트 포트 = Eureka 등록 포트입니다(`SERVICE_PORT`=`SERVER_PORT`).
같은 EC2의 컨테이너는 보안 그룹을 공유하므로, 서비스 간 분리는 서비스별 DB 계정과 앱 인증(서비스 토큰, JWT)이 맡습니다.

| 서비스 | 풀 | 호스트 포트 | 들어오는 곳 (보안 그룹 규칙) | Eureka 등록 |
|---|---|---|---|---|
| Gateway | 일반 | 8000 | ALB(`app_from_alb`), 서비스(`app_internal_gateways_eureka`), 모니터링 | `<사설 IP>:8000` |
| PurchaseGateway | 구매 | 8001 | ALB, 서비스, 모니터링 | `<사설 IP>:8001` |
| Eureka | 일반 | 8761 | 서비스, 모니터링 | `<ENI IP>:8761`, peer는 상대 ENI |
| Account | 일반 | 8080 | 서비스(`app_internal_services` 8080~8087), 모니터링 | `<사설 IP>:8080` |
| Product Command | 구매 | 8081 | 〃 | 8081 |
| Product Query | query | 8082 | 〃 | 8082 |
| Order Command | 구매 | 8083 | 〃 | 8083 |
| Payment | query | 8084 | 〃 | 8084 |
| Order Query | query | 8085 | 〃 | 8085 |
| AI | query | 8086 | 〃 | 8086 |
| Notification | 일반 | 8087 | 〃 | 8087 |
| node exporter | 모든 EC2 | 9100 | 모니터링 | - |

`envs/prod/tests`가 풀 안의 호스트 포트 중복을 검사합니다.

## 그 밖의 통신

| 출발 | 도착 | 포트 | 규칙 |
|---|---|---|---|
| 인터넷 | ALB | 443, 80(→443 리다이렉트) | `alb_https`, `alb_http` (`alb_ingress_cidrs`) |
| ALB | 일반·구매 Gateway | 8000, 8001 | `alb_to_gateways` |
| 서비스(app) | RDS | 5432 | `rds_from_app` |
| 모니터링 | RDS | 5432 | `rds_from_monitoring` (DB 초기화·지표) |
| 구매 풀만(purchase) | Command DB | 5432 | `command_db_from_purchase` |
| 모니터링 | Command DB | 9100, 9187 | `command_db_scrape` |
| 서비스(app) | Kafka | 9092 | `kafka_from_app` |
| 모니터링 | Kafka | 9092, 9404, 9100 | `kafka_from_monitoring` |
| 서비스(app) | Redis | 6379(TLS) | `redis_from_app` |
| 관리자 | 모든 EC2 | - | SSM Session Manager(22 포트 없음) |

PostgreSQL, Redis, Kafka, Eureka, Grafana는 어느 것도 0.0.0.0/0에 열려 있지 않습니다. Grafana(3001)·Prometheus(9095)는 모니터링 EC2의 127.0.0.1에만 열려 SSM 포트 포워딩으로 봅니다.
서비스 간 실제 호출(예: Order Command → Product Command, Order Command → Payment Kafka 명령)은 모두 app 보안 그룹 안에서 이뤄집니다.

## ALB 라우팅

| 우선순위 | 조건 | 대상 |
|---|---|---|
| 10 | Host `api.<도메인>` | 일반 Gateway 대상 그룹(8000) |
| 20 | Host `pay.<도메인>` | 구매 Gateway 대상 그룹(8001) |
| 기본 | 그 밖의 Host(ALB 주소 직접 접근 등) | 404 고정 응답 |

- 메서드·경로로 나누지 않습니다. 어떤 API가 구매 쪽인지는 프론트가 주소로 정합니다(현재 `vercel.json`: `/api/*` → `api.`, `/pg/*` → `pay.`).
- OPTIONS(CORS 사전 요청)도 같은 Gateway로 가서 Gateway의 CORS 설정이 응답합니다. 두 Gateway가 같은 `APP_ALLOWED_ORIGINS`, `JWT_ISSUER`, `JWT_AUDIENCE`, `ACCOUNT_JWKS_URI`(SSM `shared`)를 읽어 기준이 같습니다.
- 헬스체크: 두 대상 그룹 모두 `GET /actuator/health/readiness` → 200. Gateway의 readiness는 Gateway 자신의 준비만 보고 하위 서비스나 RDS 상태는 넣지 않습니다. 그래서 RDS 같은 공통 의존성 장애로 모든 서버가 교체되는 일이 없습니다. 하위 서비스 상태는 Prometheus·Blackbox가 따로 봅니다.

## 이미지 레지스트리

| 이미지 | 위치 | 받는 경로 |
|---|---|---|
| 서비스 8, Gateway 2, Eureka | ECR `stockdrop/<이름>` (태그 덮어쓰기 금지, push 시 스캔, 최근 20개 보관) | S3 Gateway 엔드포인트(이미지 계층) + NAT(인증 API) |
| Kafka `apache/kafka:4.1.0`, PostgreSQL `postgres:17-alpine`, Prometheus·Grafana·exporter | Docker Hub·Quay(공개, 고정 버전) | NAT |

공개 이미지는 모두 linux/arm64 manifest가 있는 고정 버전입니다. 서비스 이미지도 CD에서 arm64로 빌드해야 합니다.

## Query 풀 통신

query는 기존 app SG를 공유하며 private app subnet의 AZ a/c에 배치합니다. 새 TG, 공개 IP, 고정 ENI는 없습니다. API ALB는 기존 general TG의 gateway:8000으로만 연결합니다. query의 8082/8085/8084/8086은 기존 app SG 내부 통신과 monitoring SG의 수집 규칙을 사용합니다. node-exporter는 monitoring SG에서 9100으로 수집합니다.

query도 `eureka-a.stockdrop.internal`, `eureka-c.stockdrop.internal`:8761을 사용하며 Account/JWKS:8080, Kafka:9092, RDS:5432와 필요한 외부 HTTPS(Toss 포함)에 접근합니다. Command DB 접근은 purchase SG에만 허용합니다. query 런타임 역할에는 Eureka ENI attach 권한을 부여하지 않습니다. 새 ENI나 DNS 이름을 만들어 Eureka 위치를 바꾸지 않습니다.
