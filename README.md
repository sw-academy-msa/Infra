# STOCKDROP Infra

STOCKDROP 운영 환경(AWS 서울 리전)을 Terraform으로 관리합니다. 서비스 코드와 Dockerfile은 각 서비스 레포에 있습니다.
이 레포는 인프라만 다룹니다. 재고 확보·Saga·Outbox 발행·Kafka 이벤트 처리·Flyway 마이그레이션은 애플리케이션 책임입니다.

## 한눈에 보기

| 구성 | 내용 |
|---|---|
| 입구 | 공개 ALB 1개. `api.<도메인>` → 일반 Gateway, `pay.<도메인>` → 구매 Gateway. ACM 인증서, Route 53 공개 Zone |
| core (general) | ASG 1개, 두 AZ, t4g.medium 2대. Gateway, Eureka, Account, Notification |
| query | ASG 1개, 두 AZ, t4g.medium 2대. Product Query, Order Query, Payment, AI |
| 구매 풀 | ASG 1개, 두 AZ, t4g.medium 2대(최대 변수). 서버마다 PurchaseGateway·Order Command·Product Command 3개 |
| 고정 역할 EC2 | Kafka(t4g.small), Command PostgreSQL(사양 변수), 모니터링(t4g.small). AZ1 app 서브넷, 별도 데이터 EBS |
| 관리형 | RDS PostgreSQL Single-AZ(변수로 Multi-AZ 전환), ElastiCache Redis(기본 꺼짐), S3 4개, ECR 11개, Kafka 재기동 Lambda, CloudWatch 알람 |
| 내부 DNS | `stockdrop.internal` Private Zone: `kafka`, `command-db`, `monitoring`, `eureka-a`, `eureka-c` |

기본 정상 상태 EC2는 9대(core 2 + query 2 + 구매 2 + 고정 3)이고, 이와 별도로 NAT 인스턴스 1대가 있습니다(아래 "설계와 다른 점").
설계도와 리소스의 대응, Eureka 주소 관리 방식 비교는 [docs/architecture.md](docs/architecture.md)에 있습니다.

## 폴더

| 경로 | 역할 |
|---|---|
| `bootstrap/` | Terraform 상태 버킷(버전 관리, 암호화, 공개 차단, HTTPS·같은 계정 전용 정책). 상태는 로컬 파일 |
| `envs/prod/` | 운영 환경 루트 모듈. `main.tf`(네트워크·풀), `dns.tf`, `redis.tf`, `alarms.tf`, `tests/` |
| `modules/network` | VPC, 서브넷 6개, NAT 인스턴스(SSM 전용 역할, 암호화 gp3), 라우팅(data 서브넷은 인터넷 경로 없음), S3 Gateway 엔드포인트 |
| `modules/security` | 보안 그룹과 규칙. 포트 표는 [docs/network.md](docs/network.md) |
| `modules/iam` | EC2 역할 6개(general, query, purchase, command-db, kafka, monitoring) |
| `modules/alb` | ALB, 대상 그룹 2개, ACM DNS 검증, `api`·`pay` Alias |
| `modules/pool` | Launch Template + ASG + CPU 증설 정책 + lifecycle hook, 부팅·배포 스크립트 |
| `modules/host` | 고정 역할 EC2(고정 사설 IP, 데이터 EBS `/data`, 삭제 방지) |
| `modules/rds` | 일반 RDS(Single-AZ 기본, gp3, 암호화, Parameter Group, 로그 보관) |
| `modules/redis` | ElastiCache Redis OSS(`enable_redis=true`일 때만 생성. Multi-AZ, 자동 장애 전환, TLS, 사용자 그룹) |
| `modules/s3` | 판매자 증빙, 상품 이미지, 문의 이미지, Command DB 백업 버킷 |
| `modules/ecr` | 이미지 저장소 11개(태그 덮어쓰기 금지, 스캔, 최근 20개 보관) |
| `modules/kafka_restart` | Kafka stopped → EventBridge → Lambda 재시작(유지보수 태그 제외) |
| `hosts/` | 고정 역할 EC2의 Compose·초기화·백업 스크립트와 `deploy.ps1`(SSM Run Command) |
| `scripts/` | Terraform 밖에서 하는 작업: Redis 앱 사용자, 배포 후 점검 |
| `docs/` | 설정값, 네트워크·포트, 운영(배포·롤백·복구·삭제), 아키텍처, 미정 사항 |

## 실행 순서

필요한 도구: Terraform 1.10 이상(검증은 1.12.2), AWS CLI v2, PowerShell. 인증은 `aws configure sso` 같은 프로필·SSO로 하고, 키를 코드나 파일에 넣지 않습니다.

```powershell
# 1) AWS 인증 준비
aws configure sso            # 또는 기존 프로필: $env:AWS_PROFILE = "<프로필>"
aws sts get-caller-identity  # 계정 확인

# 2) 필수 변수 확인
cd envs\prod
Copy-Item terraform.tfvars.example terraform.tfvars   # domain_name, alert_emails 등 입력. 이 파일은 커밋하지 않음

# 3) State bootstrap (최초 한 번)
cd ..\..\bootstrap
terraform init
terraform apply              # 출력 state_bucket 확인

# 4) backend 초기화
cd ..\envs\prod
Copy-Item backend.hcl.example backend.hcl            # bucket = state_bucket 값
terraform init -backend-config=backend.hcl
```

5) **앱 이미지 준비·업로드**: ECR 저장소는 6) 이후 apply에서 만들어집니다. 그 전에는 이미지를 올릴 곳이 없으므로,
   처음에는 이미지 없이 apply하고(서비스는 `release` 태그가 없으면 건너뜀) ECR이 생긴 뒤 CD로 올립니다. 순서는 아래 7)~9)에 이어집니다.

```powershell
# 6) 비밀정보 주입 (apply 전): docs/parameters.md의 SSM 값을 넣습니다. Terraform은 이 값을 읽거나 만들지 않습니다.
#    apply 뒤에는 -TerraformOutput으로 한 번 더 실행해 RDS·Redis 주소를 채웁니다.
cd ..\..
powershell -ExecutionPolicy Bypass -File .\scripts\put-parameters.ps1
cd envs\prod

# 7) plan 검토 → 8) apply (사용자가 직접 실행)
terraform plan -out tfplan
terraform apply tfplan
terraform output              # public_name_servers, s3_buckets, redis, hosts 확인

# 9) DB 초기화·앱 이미지·마이그레이션
cd ..\..
.\hosts\deploy.ps1 -Role kafka        # 브로커 + 토픽 19개
.\hosts\deploy.ps1 -Role command-db   # Command DB 계정·스키마 + 매일 백업 타이머
.\hosts\deploy.ps1 -Role monitoring   # Prometheus·Grafana·Alertmanager
.\hosts\deploy.ps1 -Role rds          # 일반 RDS 서비스별 DB·계정(모니터링 EC2에서 실행)
.\scripts\redis-app-user.ps1          # Redis 앱 사용자(enable_redis=true일 때만)
#    이어서 CD(GitHub Actions)가 이미지를 ECR에 올리고 /stockdrop/prod/release/<서비스>를 갱신 → SSM으로 재배포합니다.
#    테이블은 서비스가 뜰 때 각자의 Flyway가 만듭니다.

# 10) 서비스 검증
.\scripts\verify.ps1                  # 읽기 전용 점검. 장애 주입 등은 docs/operations.md의 수동 절차
```

### HTTPS 켜기 (도메인 네임서버 변경 후)

공개 Zone은 Terraform이 만들지만, 인터넷이 이 Zone을 쓰게 하려면 도메인 등록업체(가비아)의 네임서버를 바꿔야 합니다.

1. 첫 apply는 `enable_https = false`입니다. ACM 검증 레코드와 `api`·`pay` Alias가 Zone에 미리 만들어집니다.
2. `terraform output public_name_servers`의 4개 값을 가비아 네임서버에 넣습니다.
   **이 순간 기존 DNS(Cloudflare)는 더 이상 쓰이지 않습니다.** 지금 서버 PC를 공개하는 Cloudflare Tunnel(`api`·`pay`·`img`)도 끊기므로 AWS 전환일에 바꿉니다.
   Cloudflare에 남겨야 할 다른 레코드(메일 등)가 있으면 먼저 Route 53에 옮깁니다.
3. `nslookup -type=NS stockdrop.cloud`로 바뀐 것을 확인한 뒤 `enable_https = true`로 다시 apply합니다. 인증서 발급을 기다린 뒤 443이 열리고 80은 443으로 돌려보냅니다.

이미 Route 53 Zone이 있으면 `hosted_zone_id`에 넣어 재사용합니다(새로 만들지 않음).

## CD (develop → main 머지 시 자동 배포)

서비스 레포 11개에는 짧은 `.github/workflows/deploy.yaml`만 있고, 실제 작업은 이 레포의 공통 워크플로 `.github/workflows/deploy-service.yaml`이 합니다.

```
서비스 레포 main push(develop → main 머지)
  → arm64 러너(ubuntu-24.04-arm)에서 docker build
  → OIDC로 레포 전용 역할(stockdrop-prod-deploy-<서비스>) 받기
  → ECR push (태그 = 커밋 SHA)
  → SSM /stockdrop/prod/release/<서비스> = SHA
  → SSM Run Command: 해당 풀 서버에서 stockdrop-deploy --wait <서비스>를 한 대씩 실행
     (새 컨테이너 readiness가 3분 안에 200이 아니면 실패로 멈추고 다음 서버는 건드리지 않음)
```

| 레포 | 서비스 | 풀 |
|---|---|---|
| AccountService, NotificationService, GeneralGateway, Eureka | account-service 등 | general |
| ProductQueryService, OrderQueryService, PaymentService, AIService | product-query-service 등 | query |
| ProductCommandService, OrderCommandService, PurchaseGateway | product-command-service 등 | purchase |

- **권한:** 역할은 레포마다 하나예요. 그 레포의 **main 브랜치**에서 실행될 때만 받을 수 있고, 자기 ECR 저장소, 자기 release 태그, 자기 풀 서버에만 접근해요(`envs/prod/cicd.tf`).
- **AWS 적용 전:** 조직 변수 `AWS_ACCOUNT_ID`가 없으면 이미지 빌드까지만 확인하고 끝나요.
- **롤백:** SSM `release/<서비스>`를 이전 SHA로 바꾸고 `stockdrop-deploy <서비스>`를 재실행해요(docs/operations.md). 또는 이전 커밋을 main에 되돌려 다시 배포해요.

GitHub 쪽 준비(사람이 설정):
1. 이 Infra 레포가 다른 레포에서 호출될 수 있어야 해요. 공개 레포면 그대로 되고, 비공개면 Settings → Actions → Access에서 "Accessible from repositories in the organization"을 켜요.
2. `terraform apply` 뒤 조직(sw-academy-msa) Settings → Variables → Actions에 `AWS_ACCOUNT_ID`를 추가해요. 비밀값이 아니라 변수예요.
3. 서비스 레포마다 main 브랜치 보호(PR 필수)를 켜요. 배포 역할이 main을 믿기 때문이에요.
4. arm64 러너는 공개 레포에서 무료예요. 비공개 레포라면 유료 러너가 필요해요.

첫 배포 순서: `terraform apply` → `AWS_ACCOUNT_ID` 등록 → Eureka → Gateway 2개 → 나머지 서비스 순으로 main 머지(또는 Actions에서 CD 수동 실행).

## 설정값과 비밀값

서비스 설정과 비밀값은 SSM Parameter Store `/stockdrop/prod` 아래에 둡니다. 서버가 부팅·배포 때 인스턴스 역할로 읽고, Terraform 상태·User Data·출력·Git에는 들어가지 않습니다.
RDS 마스터 비밀번호는 RDS가 Secrets Manager에서 관리합니다. Redis 앱 비밀번호도 Terraform 밖(`scripts/redis-app-user.ps1`)에서 넣습니다.
전체 목록: [docs/parameters.md](docs/parameters.md)

## 설계와 다른 점과 이유

| 항목 | 설계 | 구현 | 이유 |
|---|---|---|---|
| NAT | NAT Gateway 1개 | NAT 인스턴스(t4g.nano) 1개 | 월 약 7달러 대 45달러+전송량. 결정에 따라 유지. NAT 인스턴스가 멈추면 사설 서브넷의 외부 통신(이미지 받기, 토스·메일 API)이 끊깁니다 |
| ALB 분기 | 경로+메서드 | Host(`api.`/`pay.`) | 프론트와 운영 서버가 이미 서브도메인 구조. 규칙이 API 목록과 묶이지 않음([docs/network.md](docs/network.md)) |
| RDS DB 구조 | 한 DB에 스키마 6개 | 서비스별 DB 6개 | 각 서비스의 기존 `DB_URL`(로컬과 같은 DB 이름)을 그대로 쓰기 위해서 |
| 환경 | dev | prod | 결정에 따라 유지 |

NAT는 AZ1에 하나만 있습니다. AZ2 서버의 외부 통신도 AZ1을 거치므로 AZ1 장애 때 외부 통신이 끊기고, AZ 간 전송 요금(GB당 약 0.01달러)이 생길 수 있습니다.
이미지 계층과 S3는 무료 S3 Gateway 엔드포인트로 받아 NAT를 거치지 않습니다.

## 삭제 보호

- RDS: `deletion_protection`, 삭제 시 최종 스냅샷(`stockdrop-prod-general-final`).
- `prevent_destroy`: Kafka·Command DB·모니터링 데이터 EBS, S3 버킷 4개, 공개 Hosted Zone, 상태 버킷.
- 정리 절차는 [docs/operations.md](docs/operations.md)의 "삭제"를 따릅니다. 보호를 먼저 풀어야 하며 무분별한 `-target`을 쓰지 않습니다.

## 비용 참고 (서울 리전 대략치, 월)

| 자원 | 대략 |
|---|---|
| core·query·구매 풀 t4g.medium 6대 + EBS | 190달러 (분리 전 일반 medium 2대 + 구매 small 2대는 95달러) |
| Kafka·Command DB·모니터링 t4g.small 3대 + EBS | 50달러 |
| RDS db.t4g.micro Single-AZ + 20GB | 24달러 |
| ElastiCache Redis | 0달러 (기본 꺼짐, 켜면 2노드 약 37달러) |
| ALB (기본 + 공인 IP) | 25달러~ |
| NAT 인스턴스 + 고정 IP | 7달러 |
| Route 53 Zone 2개, Secrets Manager, Lambda, CloudWatch 알람 약 50개 | 6달러 |
| ECR·S3 | 저장량에 따라 |

합계 약 305~315달러입니다(공인 IPv4 요금 포함, core/query 분리와 구매 풀 medium 상향 반영). 증설 시 서버 수만큼 늘고, 정확한 값은 AWS 요금 계산기로 확인합니다.

## 검증

로컬과 CI는 AWS에 접속하지 않습니다: `terraform fmt -check`, `validate`, `test`(mock provider), `tflint`, shellcheck, Lambda 단위 테스트, Compose 검사.
실제 `plan` 결과는 AWS 자격 증명이 있어야 만들 수 있습니다. 지금까지의 검증 결과는 [docs/verification.md](docs/verification.md)에 있습니다.

## Core/query 풀 분리 (2026-11)

물리 `general`은 core 역할을 유지합니다. ASG, LT, TG, ENI 이름과 Terraform 주소를 바꾸지 않습니다. query는 ALB 대상 그룹 없이 EC2 health를 사용하며 두 AZ에 기본 2대를 둡니다. 아래 값은 목표 구성이고 운영 적용 여부는 작업 보고서로 확인합니다.

| Pool | 사양 및 기본 대수 | 서비스와 컨테이너 한도(MiB) |
|---|---|---|
| general (core) | t4g.medium 2 | eureka 384, gateway 384, account-service 512, notification-service 512 |
| query | t4g.medium 2 | product-query-service 512, order-query-service 512, payment-service 512, ai-service 768 |
| purchase | t4g.medium 2 | purchase-gateway 384, order-command-service 640, product-command-service 640 |

query 시작 hook은 Gateway가 없어 네 서비스 readiness가 모두 200이어야 CONTINUE합니다. 따라서 query 풀을 처음 만들기 전에 네 서비스의 `release/<서비스>` 값과 ECR 이미지가 있어야 합니다(운영은 이미 있음). 새 환경에서는 CD로 이미지를 먼저 올리거나 `query_min_size`를 0으로 두고 시작합니다. 시작 hook은 25분, Terraform 대기는 30분입니다.

일반 core는 고정 Eureka ENI 때문에 자동 instance refresh를 끕니다. query와 purchase는 min healthy 100%, max healthy 150%로 2대 기준 한 대를 추가한 뒤 한 대씩 교체합니다. [이동과 되돌리기](docs/operations.md#corequery-이동-절차)를 따릅니다.
