# 운영 절차

모든 명령은 Infra 레포 루트의 PowerShell 기준입니다. EC2 정지·종료, 장애 주입처럼 비용이나 영향이 있는 작업은 자동화하지 않았고, 여기 적힌 순서대로 사람이 실행합니다.

## 배포와 업데이트

| 바꾸는 것 | 방법 | 영향 |
|---|---|---|
| 서비스 이미지 | 서비스 레포 develop → main 머지 → CD가 ECR push → `release/<서비스>` 갱신 → 서버 한 대씩 `stockdrop-deploy --wait <서비스>` | 그 서비스만 서버별로 차례로 재시작. 한 대가 준비 실패하면 거기서 멈춤 |
| 서비스 설정·비밀값 | SSM 값 변경 후 위와 같이 재배포 | 〃 |
| Launch Template(부팅 스크립트, 사양) | `terraform apply` → ASG instance refresh가 절반씩 교체 | 교체 중 풀 용량 절반. 일반 풀은 Eureka가 잠시 한 대 |
| 고정 역할 EC2 구성 | `.\hosts\deploy.ps1 -Role <역할>` | Kafka·DB는 컨테이너 재생성 시 수십 초 중단 |
| Terraform 인프라 | `terraform plan` 검토 → `apply` | plan에 replace·destroy가 있으면 멈추고 원인 확인 |

특정 서비스만 다시 배포:

```powershell
aws ssm send-command --document-name AWS-RunShellScript --targets Key=tag:Pool,Values=general `
  --parameters 'commands=["/usr/local/bin/stockdrop-deploy payment-service"]'
```

### 롤백

- 서비스: CD 실행 요약(Actions → 해당 실행 → Summary)에 이전 release 값이 있습니다. 그 값으로 되돌리고 한 대씩 재배포합니다. ECR 태그는 덮어쓸 수 없어 이전 이미지가 그대로 남아 있습니다(최근 20개).
  ```powershell
  aws ssm put-parameter --name /stockdrop/prod/release/payment-service --type String --value <이전 SHA> --overwrite
  aws ssm send-command --document-name AWS-RunShellScript --targets Key=tag:Project,Values=STOCKDROP Key=tag:Pool,Values=general `
    --max-concurrency 1 --max-errors 0 --parameters 'commands=["/usr/local/bin/stockdrop-deploy --wait payment-service"]'
  ```
- Launch Template: 이전 커밋으로 되돌려 `apply`하면 instance refresh가 다시 교체합니다. 급하면 콘솔에서 진행 중인 refresh를 취소합니다.
- Terraform: 상태 버킷은 버전 관리가 켜져 있어 이전 상태 파일을 되살릴 수 있습니다. 상태를 직접 되돌리는 것은 마지막 수단입니다.

## 서버 수 조정

- 평소에는 CPU 목표 추적(기본 60%)이 풀마다 따로 늘리고 줄입니다. 풀 안의 서버는 같은 컨테이너 묶음을 띄우므로, 구매 풀이 늘면 PurchaseGateway·Order Command·Product Command가 함께 늘어납니다.
- 선착순 시작 시각처럼 짧게 몰리는 경우에는 CPU 증설이 늦습니다. 행사 전에 미리 늘리고, 끝나면 되돌립니다.
  ```powershell
  aws autoscaling set-desired-capacity --auto-scaling-group-name stockdrop-prod-purchase --desired-capacity 4
  ```
- Terraform은 `desired_capacity` 변경을 무시하므로 다음 apply가 이 값을 되돌리지 않습니다. 최소·최대는 변수(`*_min_size`, `*_max_size`)로 바꿉니다.
- 일반 풀이 3대 이상이 되어도 Eureka는 2대입니다(docs/architecture.md).

## Kafka

- **유지보수로 멈출 때**: 먼저 자동 재기동을 끕니다. 끝나면 태그를 지웁니다.
  ```powershell
  $id = (terraform -chdir=envs/prod output -json hosts | ConvertFrom-Json).kafka.instance_id
  aws ec2 create-tags --resources $id --tags Key=AutoRestart,Value=false
  aws ec2 stop-instances --instance-ids $id
  # 작업 후
  aws ec2 start-instances --instance-ids $id
  aws ec2 delete-tags --resources $id --tags Key=AutoRestart
  ```
- **자동 재기동이 해결하지 않는 것**: terminated, EBS 손상, Kafka 프로세스 무응답, 잘못된 설정, 디스크 부족. 이 경우 Prometheus 경보(Kafka 다운·디스크)와 CloudWatch 상태 검사 알람으로 알게 되며 사람이 조치합니다.
- **새 토픽**: `hosts/kafka/topics.sh`에 추가하고 `.\hosts\deploy.ps1 -Role kafka`를 다시 실행합니다. 자동 생성은 꺼져 있습니다.
- 단일 브로커라 Kafka가 멈추면 Outbox 발행이 쌓이고 조회 모델 갱신이 늦어집니다. 다시 뜨면 서비스가 이어서 보냅니다(앱 Outbox 책임).

## Command DB

Command DB EC2가 멈추면 주문·재고 처리가 멈춥니다. Standby와 자동 승격은 없습니다.

### 백업

- 매일 18:30 UTC(03:30 KST)에 `stockdrop-command-db-backup.timer`가 `product_command`, `order_command`를 `pg_dump`해 S3 `command-db-backups` 버킷에 올립니다. 보관은 30일(`backup_retention_days`)입니다.
- 수동 백업: `aws ssm start-session --target <command-db 인스턴스>` 후 `sudo systemctl start stockdrop-command-db-backup`.

### 복원 검증 (정기적으로)

원본을 건드리지 않고 `<db>_restore_check`에 복원해 테이블별 행 수를 비교한 뒤 지웁니다.

```bash
sudo -i
set -a; source /etc/stockdrop-command-db-backup.env; set +a
bash /opt/stockdrop/command-db/restore.sh --list
bash /opt/stockdrop/command-db/restore.sh command-db/2026/11/16/20261116T183000Z product_command
```

### 원본 되돌리기

1. 새 주문·재고 변경이 들어오지 않게 구매 풀의 Command 서비스를 멈춥니다. 서버를 지우지 않고 컨테이너만 멈추는 방법입니다(그동안 `pay.`는 오류를 돌려줍니다).
   ```powershell
   aws ssm send-command --document-name AWS-RunShellScript --targets Key=tag:Pool,Values=purchase `
     --parameters 'commands=["docker compose -f /etc/stockdrop/compose/order-command-service.yaml stop","docker compose -f /etc/stockdrop/compose/product-command-service.yaml stop"]'
   ```
2. Command DB 서버에서 `restore.sh <경로> <db> --replace`를 실행합니다. 한 트랜잭션이라 실패하면 원래 데이터가 그대로 남습니다.
3. `stockdrop-deploy order-command-service product-command-service`로 다시 띄웁니다.

### 디스크·서버 복구

| 상황 | 방법 |
|---|---|
| EC2 하드웨어 문제 | CloudWatch `system-check` 알람이 같은 EBS로 자동 복구(recover)를 시도합니다 |
| EC2를 새로 만들어야 함(같은 AZ) | 데이터 EBS는 `prevent_destroy`라 남습니다. 새 EC2에 같은 EBS를 붙이면 부팅 스크립트가 포맷하지 않고(`blkid`로 기존 파일 시스템 확인) `/data`에 마운트합니다. `deploy.ps1 -Role command-db`가 initdb 없이 기존 데이터로 띄웁니다 |
| AZ1 장애(다른 AZ로 이동) | EBS는 다른 AZ로 자동 이동하지 않습니다. AZ2에서 S3 백업으로 새 DB를 만들거나, EBS 스냅샷에서 AZ2 볼륨을 만들어 붙입니다. 마지막 백업 이후 데이터는 잃습니다 |

Kafka 데이터 EBS도 같은 방식입니다(백업 없음: 조회 모델은 Outbox 재발행·재구축으로 복구).

## RDS·Redis

- RDS Multi-AZ는 Primary 장애 때 대기 DB로 자동 전환합니다(보통 1~2분). 주소(endpoint)는 그대로입니다. 대기 DB는 읽기에 쓰지 않습니다.
- RDS 서비스 계정을 다시 맞추거나 서비스를 추가했으면 `.\hosts\deploy.ps1 -Role rds`를 다시 실행합니다(재실행 안전).
- Redis는 Primary 장애 때 Replica가 승격하며 `primary_endpoint` 이름은 그대로입니다. 캐시이므로 비어도 원본(DB)에서 다시 채웁니다.
- Redis 비밀번호 교체: SSM `shared/REDIS_PASSWORD`를 바꾸고 `.\scripts\redis-app-user.ps1` → 서비스 재배포.

## 배포 후 점검

읽기 전용 점검은 `.\scripts\verify.ps1`이 합니다. 아래는 영향이 있어 수동으로 하는 점검입니다.

| 점검 | 절차 | 기대 결과 |
|---|---|---|
| 컨테이너 재시작 | 서버에서 `docker kill payment-service` | `restart: unless-stopped`로 다시 뜨고 Eureka에 재등록 |
| ASG 교체 | `aws autoscaling terminate-instance-in-auto-scaling-group --instance-id <id> --no-should-decrement-desired-capacity` | 새 서버가 뜨고(일반 풀이면 같은 AZ의 Eureka ENI를 붙임) 대상 그룹 healthy, Prometheus 대상이 새 IP로 바뀜 |
| Kafka 재기동 | `aws ec2 stop-instances --instance-ids <kafka>` | 수 분 안에 Lambda가 다시 시작. 로그 `/aws/lambda/stockdrop-prod-kafka-restart`에 `"action": "start"` |
| 유지보수 제외 | 태그 `AutoRestart=false`를 붙인 뒤 정지 | Lambda 로그에 `"reason": "maintenance"`, 인스턴스는 stopped 유지 |
| DB 백업 복원 | 위 "복원 검증" | 오류 없이 복원, 행 수 출력 |
| C/D 같은 Command DB | 구매 풀 두 서버에서 Order Command 로그의 DB 주소 확인 | 둘 다 `command-db.stockdrop.internal` |
| 일반·구매 분기 | `curl https://api.<도메인>/actuator/health/readiness`, `https://pay.<도메인>/...` | 각각 200, ALB 대상 그룹별 요청 수 증가 |

## 삭제

데이터를 지우는 작업이므로 아래 순서를 지키고, 보호 설정은 해당 단계에서만 풉니다. 무분별한 `-target`을 쓰지 않습니다.

1. **앱 서버 정리**: `general_min_size`/`purchase_min_size`를 0으로 바꿔 apply하거나 ASG desired를 0으로 둡니다. 비용이 가장 큰 부분이고 데이터가 없습니다.
2. **RDS**: `terraform destroy` 시 최종 스냅샷 `stockdrop-prod-general-final`이 남습니다. 먼저 `deletion_protection`을 false로 바꿔 apply해야 지워집니다. 스냅샷은 수동으로 지울 때까지 비용이 듭니다.
3. **Command DB·Kafka·모니터링 데이터 EBS**: `prevent_destroy`라 destroy가 멈춥니다. 보존하려면 `terraform state rm 'module.host["command-db"].aws_ebs_volume.data'` 등으로 Terraform 관리에서만 빼고 볼륨은 남깁니다. 지우려면 스냅샷을 먼저 만든 뒤 `prevent_destroy`를 풉니다.
4. **S3 백업·이미지 버킷**: `prevent_destroy`. 보존이 기본입니다. 지우려면 버킷을 비운 뒤(버전 포함) 보호를 풉니다.
5. **공개 Hosted Zone**: `prevent_destroy`. 지우면 네임서버가 바뀌어 등록업체 설정을 다시 해야 합니다.
6. **State 버킷(bootstrap)**: 마지막까지 남깁니다. 다른 모든 상태가 정리된 뒤에만 보호를 풀고 지웁니다.

## 기존 리소스가 있을 때

- Route 53 Zone이 이미 있으면 `hosted_zone_id`로 재사용합니다.
- 같은 이름의 자원(ECR 저장소, S3 버킷 등)이 이미 있으면 새로 만들지 말고 `terraform import`로 가져옵니다. 예: `terraform import 'module.ecr.aws_ecr_repository.this["gateway"]' stockdrop/gateway`. import 전에는 plan에 create가 보이면 apply하지 않습니다.
