# 아키텍처와 구현 대응

설계도 구성 요소마다 어떤 Terraform 리소스와 스크립트로 구현했는지 정리합니다. 경로는 레포 기준입니다.

## 설계도 ↔ 구현

| 설계 구성 | 구현 | 위치 |
|---|---|---|
| VPC, AZ 2개, 공개·app·data 서브넷 | `aws_vpc`, `aws_subnet` 6개, data 전용 라우팅 테이블(기본 경로 없음) | `modules/network` |
| NAT 1개(AZ1, 공유) | NAT 인스턴스 + EIP (설계는 NAT Gateway, README "설계와 다른 점") | `modules/network/nat.tf` |
| S3 Gateway Endpoint | private 라우팅 테이블에 연결 | `modules/network` |
| 공개 ALB, 대상 그룹 2개 | `aws_lb`, `aws_lb_target_group.general/purchase`, Host 규칙 | `modules/alb` |
| ACM, Route 53 | 공개 Zone(생성 또는 재사용), DNS 검증, `api`·`pay` Alias | `envs/prod/dns.tf`, `modules/alb` |
| core(general) 및 query ASG | Launch Template + ASG(min 2, max 변수) + CPU 목표 추적 + lifecycle hook | `modules/pool`, `envs/prod/main.tf` |
| 구매 처리 ASG | 같은 모듈, 구매 서비스 3개 | 〃 |
| Eureka A/B | AZ별 고정 IP ENI 2개 + 내부 DNS `eureka-a/c` | `envs/prod/main.tf` |
| Kafka 단일 EC2 | `modules/host` + `hosts/kafka`(KRaft, 토픽 19개, JMX) | `modules/host`, `hosts/kafka` |
| Command PostgreSQL EC2 | `modules/host` + `hosts/command-db`(초기화, 백업·복원, exporter) | `hosts/command-db` |
| 모니터링 EC2 | `modules/host` + `hosts/monitoring`(Monitoring 레포 + 운영 덮어쓰기) | `hosts/monitoring` |
| RDS PostgreSQL | Single-AZ(비용 때문에 `rds_multi_az=false`, 켜면 Multi-AZ), gp3, 암호화, 마스터 비밀번호 RDS 관리, Parameter Group | `modules/rds`, `hosts/rds` |
| ElastiCache Redis | **기본 꺼짐**(`enable_redis=false`, 쓰는 서비스 없음). 켜면 복제 그룹(Primary+Replica), Multi-AZ, TLS, 사용자 그룹 | `modules/redis`, `scripts/redis-app-user.ps1` |
| S3 | 판매자 증빙, 상품 이미지, 문의 이미지, Command DB 백업 | `modules/s3` |
| ECR | 서비스 8 + Gateway 2 + Eureka 1 | `modules/ecr` |
| EventBridge + Lambda | Kafka stopped 재기동 | `modules/kafka_restart` |
| CloudWatch | 알람(EC2·ALB·RDS·Redis·Lambda), 로그 그룹 보관 기간, SNS 주제 | `envs/prod/alarms.tf` |
| 내부 DNS | Private Zone `stockdrop.internal` | `envs/prod/dns.tf` |
| IAM | EC2 역할 6개(general, query, purchase, command-db, kafka, monitoring) + Lambda 역할 | `modules/iam`, `modules/kafka_restart` |

기본 EC2 9대 외에 추가되는 관리형 리소스: NAT 인스턴스 1대(EC2), Lambda 1개, RDS 1대(Single-AZ). Redis는 기본 꺼짐.

## Eureka 주소 관리

ASG가 서버를 바꾸거나 늘려도 서비스가 Eureka를 찾을 수 있어야 하고, 이전 서버의 종료가 새 주소를 지우면 안 됩니다.

| 방식 | 동작 | 판단 |
|---|---|---|
| **AZ별 고정 IP ENI (선택)** | AZ마다 Eureka 전용 ENI(`10.20.10.10`, `10.20.11.10`)를 미리 만들고, 그 AZ의 일반 풀 서버가 부팅 때 붙입니다. 내부 DNS `eureka-a/c`는 이 고정 IP를 가리킵니다 | 주소가 바뀌지 않아 DNS를 갱신·삭제할 일이 없습니다. "이전 종료 이벤트가 새 값을 지우는" 경쟁이 생기지 않습니다. 추가 Lambda가 없습니다 |
| Route 53 레코드 + lifecycle hook + Lambda | 부팅 때 자기 IP로 레코드를 덮어쓰고, 종료 hook에서 Lambda가 값이 같을 때만 지웁니다 | 경쟁 상태와 조건부 삭제를 직접 구현해야 합니다. JVM DNS 캐시 때문에 클라이언트 반영이 늦습니다 |
| EventBridge + Lambda 목록 관리 | ASG 이벤트마다 Lambda가 Eureka 주소 목록(SSM 등)을 갱신합니다 | 가장 복잡하고, 클라이언트가 바뀐 목록을 다시 읽어야 합니다 |

동작과 제한:

- **교체**: 인스턴스 refresh는 기존 서버를 먼저 종료합니다. 종료되면 ENI가 풀리고, 새 서버가 최대 3분 기다렸다가 붙입니다. 그동안 Eureka는 다른 AZ의 한 대만 남습니다. 서비스는 두 주소를 모두 알고 있어 남은 쪽으로 붙습니다.
- **증설(3대 이상)**: 남은 ENI가 없으므로 3번째 서버부터는 Eureka 없이 나머지 7개 서비스만 띄웁니다. Eureka는 항상 2대이고, 서버 수를 늘리지 않습니다.
- **한 AZ에 몰린 경우**: ENI는 자기 AZ에서만 붙습니다. ASG의 AZ 재조정 전까지 두 서버가 같은 AZ에 있으면 Eureka가 한 대만 뜹니다.
- **등록 주소**: 서비스는 EC2 기본 사설 IP + 호스트 포트(`--network host`), `<서비스>-<인스턴스 ID>` instance-id로 등록합니다. Eureka 자신은 ENI 고정 IP로 등록하고 상대 노드를 peer로 둡니다.
- **호출 선택**: 구매 Gateway는 Eureka 목록에서 Spring Cloud LoadBalancer로 정상 Order Command를 고릅니다. 같은 서버의 인스턴스에 고정되지 않습니다. Eureka는 요청을 중계하지 않습니다.
- **종료 시 등록 해제**: 종료 lifecycle hook을 서버가 IMDS로 감지해 컨테이너를 정상 종료합니다. Spring이 Eureka 등록을 해제한 뒤 hook을 완료합니다. 응답이 없으면 2분 뒤 종료합니다.

## 데이터 소유권

| 데이터 | 저장 위치 | 쓰는 서비스 | 비고 |
|---|---|---|---|
| 상품·옵션·재고·문의·FAQ 원본, Product Outbox | Command DB `product_command` / `product` 스키마 | Product Command | 재고 확보·확정·해제와 동시성 제어는 앱 |
| 주문·배송 원본, Saga 상태·재시도, Order Outbox, 멱등 이력 | Command DB `order_command` / `orders` 스키마 | Order Command | Saga 조율은 앱 |
| 회원·판매자·배송지·관심·동의 | RDS `stockdrop` / `account` | Account | |
| 상품 조회 모델 | RDS `product_query` | Product Query | Kafka 이벤트로 갱신 |
| 주문 조회 모델 | RDS `orders_query` | Order Query | Kafka 이벤트로 갱신 |
| 결제·환불·정산 | RDS `payment` | Payment | |
| AI 분석·추천 | RDS `ai_service` / `ai` | AI | |
| 알림 | RDS `notification_service` / `notification` | Notification | |
| 캐시 | Redis | 일반 풀 서비스 | 재고 원본이 아닙니다 |
| 이미지·증빙 원본 | S3 | Account, Product Command·Query, AI, Order Command | presigned URL |

Command 원본(product, orders)과 그 Outbox는 RDS에 다시 만들지 않습니다. RDS는 Single-AZ라 AZ 장애 때는 자동 전환되지 않고 스냅샷·시점 복구로 되살립니다(`rds_multi_az=true`로 바꾸면 대기 DB가 생기며, 대기 DB는 읽기 조회에 쓰지 않습니다).

## Core/query 역할 분리

`module.general_pool`과 `Pool=general`은 core의 물리 식별자로 유지합니다. gateway, eureka, account-service, notification-service를 각각 2복제합니다. `module.query_pool`은 query 역할로 product-query-service, order-query-service, payment-service, ai-service를 각각 2복제하고 Eureka 내부 DNS를 공유합니다. payment는 승인과 상태 변경도 담당합니다. 풀 이름은 읽기 전용 권한을 뜻하지 않습니다.

세 풀은 기본 t4g.medium 각각 2대이며 고정 역할 EC2 3대와 합해 9대입니다(NAT 별도). core 한 대의 컨테이너 상한 합은 1728MiB, query는 2112MiB, purchase는 1664MiB입니다. OS/Docker/JVM native 여유와 실제 RSS를 별도로 관측합니다. coupon은 이번 배치에 포함하지 않습니다. query launch hook은 네 서비스 readiness를 모두 확인하고 실패하면 ABANDON합니다.
