# 검증 결과와 남은 일

기준일: 2026-11-17. AWS에는 아무것도 만들거나 바꾸지 않았습니다. 아래 검증은 모두 로컬 Docker와 mock provider로 했습니다.

## 실행한 검증

| 검증 | 도구 | 결과 |
|---|---|---|
| 형식 | `terraform fmt -recursive -check` (1.12.2) | 통과 |
| 문법 | `terraform init -backend=false` + `validate` (bootstrap, envs/prod) | 통과 |
| 요구사항 | `terraform test` (mock provider): EC2 구성, 풀 크기·사양, 컨테이너 8/3개, 포트 중복 없음, Multi-AZ, Eureka 2개, 고정 EC2 위치, data 서브넷 격리, Redis Multi-AZ·TLS·default 사용자 꺼짐 | 3개 run 통과 |
| 정적 분석 | tflint v0.53.0 (`--recursive`) | 경고 0 |
| 셸 | `bash -n`, shellcheck v0.10.0 (warning 이상), 렌더링한 `user_data` 포함 | 9개 스크립트 통과 |
| Lambda | Python unittest 5개(정지→시작, 유지보수 제외, 이미 시작 중, 다른 인스턴스, terminated·없음) | 통과 |
| Compose | `docker compose config` (kafka, command-db, 서비스별 생성 파일) | 통과 |
| PowerShell | 구문 분석, UTF-8 BOM(5.1 한글) | 3개 통과 |
| Kafka 실행 | 로컬 Docker로 브로커 + JMX 기동, `topics.sh` 2회 | healthy, 토픽 19개, 재실행 무변경, JMX 지표 98개 |
| Command DB 실행 | `start.sh` 2회, 네트워크 접속 권한 경계 | 재실행 안전, 틀린 비밀번호·다른 DB·public 스키마 거절, exporter `pg_up 1` |
| Command DB 백업·복원 | `backup.sh` → `restore.sh` 검증 복원 → `--replace` | 행 수 비교 정상, 원본 되돌림 후 소유자 유지·앱 쓰기 가능 |
| RDS 초기화 | 슈퍼유저가 아닌 CREATEROLE·CREATEDB 계정(RDS 마스터와 같은 권한)으로 `hosts/rds/start.sh` 2회 | 서비스 6개 준비, 재실행 안전, 권한 경계 정상 |
| 모니터링 실행 | Monitoring 레포 + 운영 덮어쓰기로 로컬 기동 | 5개 컨테이너 healthy, Kafka 브로커·소비 그룹 수집 up |
| 배포 스크립트 | `deploy.ps1 -DryRun` 4개 역할, base64 전송 해시 비교 | 리눅스에서 원본과 같은 해시로 복원 |

검증 중 찾아 고친 문제: 복원 `--replace`가 실패 시 스키마를 잃던 문제(한 트랜잭션 + 소유자 유지로 수정), RDS 마스터가 `log_statement`·남의 스키마 권한을 바꿀 수 없어 실패하던 문제, ACM 검증 레코드 `for_each` 키가 plan 때 정해지지 않을 수 있던 문제.

## 실행하지 못한 검증과 이유

| 검증 | 이유 | 언제 |
|---|---|---|
| 실제 `terraform plan` | AWS 자격 증명을 쓰지 않았습니다(요청 범위) | 사용자가 README 7)에서 실행 |
| SSM Run Command 왕복, EC2의 SSM·Secrets Manager 읽기 | AWS 자원이 없습니다 | 첫 `deploy.ps1` 실행 |
| ASG 부팅, Eureka ENI 연결, lifecycle hook 완료 | 〃 | apply 후 `verify.ps1`과 operations.md 수동 점검 |
| ACM 발급, HTTPS | 네임서버 변경 전에는 발급되지 않습니다 | 전환일 |
| Kafka 재기동 Lambda 실제 호출 | 〃 | operations.md "Kafka 재기동" 점검 |
| 서비스 컨테이너 실행 | 서비스 이미지가 ECR에 없습니다(CD 미구현). 없는 이미지는 건너뛰고 실행했다고 보고하지 않습니다 | CD 구현 후 |
| 서울 리전 지원 조합 | 조회에 자격 증명이 필요합니다. plan 전에 아래 명령으로 확인합니다 | plan 전 |

```powershell
# RDS db.t4g.micro PostgreSQL 17 Multi-AZ 지원
aws rds describe-orderable-db-instance-options --engine postgres --engine-version 17 --db-instance-class db.t4g.micro `
  --query "OrderableDBInstanceOptions[?MultiAZCapable].[EngineVersion,StorageType]" --output text
# ElastiCache Redis OSS 7.1과 cache.t4g.micro
aws elasticache describe-cache-engine-versions --engine redis --query "CacheEngineVersions[].EngineVersion"
aws elasticache describe-reserved-cache-nodes-offerings --cache-node-type cache.t4g.micro --max-items 1
```

## 미입력 값 (배포 전에 필요)

| 값 | 넣는 곳 | 비고 |
|---|---|---|
| AWS 계정·인증 | 실행 PC의 프로필·SSO | 코드에 넣지 않습니다 |
| `domain_name` | `terraform.tfvars` | 예시는 `stockdrop.cloud` |
| `hosted_zone_id` | 〃 | 기존 Zone이 있을 때만 |
| `alert_emails` | 〃 | 비우면 알림 구독 없음 |
| 도메인 네임서버 변경 | 가비아 | 전환일. Cloudflare Tunnel이 끊깁니다 |
| 서비스 비밀값 전체 | SSM (docs/parameters.md) | DB 비밀번호 8개, JWT 키, 토스 키, GPT 키, 메일, 푸시 VAPID, 수집 토큰, Redis, Command DB 관리자·지표, Grafana |
| 서비스 이미지 | ECR + `/release/<서비스>` | CD가 채웁니다 |
| Command DB 사양 | `host_instance_types["command-db"]` | 기본 t4g.small은 임시값입니다 |

## 앱 쪽 확인이 필요한 것

인프라가 가정한 값입니다. 서비스 레포에서 맞는지 확인해야 합니다.

- Gateway 두 개가 `GET /actuator/health/readiness`를 인증 없이 200으로 응답하는지(ALB 헬스체크).
- Eureka 앱이 `EUREKA_HOSTNAME`, `EUREKA_INSTANCE_ID`, `EUREKA_PEER_URL`을 읽는지, 서비스가 `SERVICE_HOSTNAME`·`SERVICE_PORT`·`SERVICE_INSTANCE_ID`로 등록하는지.
- 서비스 이미지가 linux/arm64로 빌드되는지.
- Redis를 쓰는 서비스의 설정 이름(docs/parameters.md 예시)과 TLS.
- Outbox 대기·Saga 미완료 지표: 앱이 `/actuator/prometheus`로 노출해야 Prometheus 경보가 동작합니다. Terraform만으로는 측정할 수 없습니다.

## 모니터링 범위

- CloudWatch 알람(`envs/prod/alarms.tf`): EC2 상태 검사(자동 복구 포함)·CPU·크레딧, ALB 5xx·지연·정상 대상 수, RDS 공간·CPU·연결·메모리, Redis 메모리·eviction·CPU·복제 지연, Lambda 실패.
- Prometheus 경보(Monitoring 레포): 서비스·Gateway 지표, 메모리·디스크(node exporter), Kafka 디스크·소비 지연, PostgreSQL 연결·잠금, Outbox. CloudWatch 기본 지표에 메모리·디스크가 없어서 이쪽이 맡습니다.
- 아직 없는 것: RDS·Redis·ALB·NAT의 CloudWatch 지표를 Grafana로 보는 CloudWatch exporter(알람은 CloudWatch에서 동작). Slack 알림은 AWS Chatbot을 SNS 주제에 콘솔로 연결합니다(웹훅을 코드에 넣지 않음).

## 남은 작업

1. CD: GitHub Actions에서 arm64 이미지 빌드 → ECR push → `/release/<서비스>` 갱신 → SSM 재배포.
2. 위 "앱 쪽 확인" 항목 점검.
3. 사용자가 plan·apply 실행 후 `deploy.ps1` 4개 역할과 `redis-app-user.ps1`, `verify.ps1`.
4. 전환일에 네임서버 변경과 `enable_https = true`.
5. k6로 풀 사양·증설 목표값·알람 임계값 조정.

## Core/query 검증 게이트

코드 검증: terraform fmt/validate 및 mock test를 수행하고 query TG 없음, EC2 health, Eureka ENI 없음, 각 서비스 상한과 IAM을 plan으로 확인합니다. 운영 검증은 코드 검사와 별개이며 완료 전에는 통과로 기록하지 않습니다.

1. ASG/LT, AZ, 이미지 release SHA, 설정 버전, ENI 소유자, api/pay ALB healthy 수를 사전 기록합니다.
2. query가 AZ별 한 대이고 네 서비스가 각 2개 UP인지 두 Eureka에서 확인합니다. 전환 중 기존 general까지 포함하면 각 4개일 수 있습니다.
3. 각 readiness, 공개 업무 GET, DB/Kafka, JWKS, Toss HTTPS 통신, node:9100, 실제 메모리 상한과 OOM 여부를 확인합니다. 유료 AI 분석과 실제 결제는 실행하지 않습니다. 인증 실패 응답만으로 주문 흐름 검증을 완료했다고 판단하지 않습니다.
4. general 한 대에서 네 서비스를 drain한 뒤 registry, gateway 선택 목록, 요청 실패 증가, Kafka projection/outbox lag를 확인하고 다음 한 대로 갑니다.
5. core Eureka는 한 번에 한 대만 재기동하며 peer와 전체 registry 복구 후 다음 노드로 진행합니다. purchase 교체는 pay ALB healthy 2 유지와 주문 흐름을 확인합니다.
6. Prometheus query metrics/blackbox 및 node pool 라벨, 서비스별 replica와 OOM 경보를 확인한 뒤 CD 동결을 해제합니다.


## Core/query 운영 적용 (2026-11-24)

| 단계 | 방법 | 결과 |
|---|---|---|
| query 생성 | query 전용 제한 apply(추가 7) | 두 AZ 2대, 네 서비스 readiness 200, 두 Eureka UP, 업무 GET 200, Kafka 그룹 합류, Toss와 JWKS 도달 |
| general drain | 서버 한 대씩 Eureka OUT_OF_SERVICE, 약 2분 대기 후 compose down | 네 서비스는 query만 UP 2, Gateway 5xx 0, Kafka lag 0, RDS 연결 59 → 37 |
| core 메모리 | 서버 한 대씩 pool.conf와 compose 한도 수정 후 같은 이미지로 재생성 | eureka 384, notification 512, 두 Eureka 등록 22개 일치 |
| general LT | 제한 apply(변경 2), 자동 refresh 없음 | LT v4, 기존 서버 교체 없음 |
| CD 역할 | 네 query 서비스 정책 Pool=query | 서비스 deploy.yaml pool: query(develop 머지) |
| purchase | t4g.medium, rolling refresh 100/150 | pay. readiness 계속 200, TG healthy 항상 2 이상, 5xx 0 |
| query 메모리 | product-query, order-query, payment 512, rolling refresh | 새 서버 컨테이너 한도 512MiB 확인 |

찾아 고친 문제:

- Windows 작업 사본(core.autocrlf)에서 셸 스크립트가 CRLF로 바뀐 채 user_data에 들어가 `stockdrop-lifecycle`이 실행되지 않았습니다(시작 hook 미완료). `.gitattributes`로 LF 고정, user_data에서 CR 제거.
- general user_data가 16410바이트로 EC2 한도 16384바이트를 넘어 LT 생성이 실패했습니다. user_data를 gzip으로 넣고 plan 단계 precondition 추가.
- RDS db.t4g.micro 연결 한도: query 서버가 3대로 겹치고 다른 배포의 컨테이너 교체가 겹치자 `remaining connection slots are reserved`로 서비스 기동과 배포가 실패했습니다. 겹침 중 연결은 약 +12입니다.
- Eureka 256MiB, notification 448MiB 한도에서 컨테이너 OOM 재시작이 반복되었습니다. 384, 512로 상향.
