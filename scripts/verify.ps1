<#
  배포 후 읽기 전용 점검입니다. 자원을 바꾸거나 멈추지 않고, 조회·GET·SSM 읽기 명령만 실행합니다.
  비밀값은 출력하지 않습니다(DB_URL 같은 주소만 봅니다). 장애 주입·교체 점검은 docs/operations.md의 수동 절차를 따릅니다.

  예: .\scripts\verify.ps1
  필요: AWS CLI 로그인, terraform apply 완료, envs/prod에서 terraform output이 되는 상태
#>
param(
    [string]$Region = 'ap-northeast-2',
    [string]$Name = 'stockdrop-prod'
)
$ErrorActionPreference = 'Stop'
$script:failures = 0

function Report([string]$Check, [bool]$Ok, [string]$Detail = '') {
    $mark = if ($Ok) { 'OK  ' } else { $script:failures++; 'FAIL' }
    Write-Host ("[{0}] {1} {2}" -f $mark, $Check, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

function Invoke-Aws([string[]]$Arguments) {
    $out = & aws @Arguments --region $Region --output json
    if ($LASTEXITCODE -ne 0) { throw "aws $($Arguments[0..1] -join ' ') 실패" }
    return ($out -join "`n") | ConvertFrom-Json
}

# 읽기 명령만 SSM으로 실행하고 출력을 돌려줍니다.
function Invoke-Ssm([string]$InstanceId, [string[]]$Commands) {
    $file = Join-Path ([IO.Path]::GetTempPath()) "stockdrop-verify-$([guid]::NewGuid()).json"
    try {
        [IO.File]::WriteAllText($file, (@{ commands = $Commands } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
        $id = (Invoke-Aws @('ssm', 'send-command', '--instance-ids', $InstanceId, '--document-name', 'AWS-RunShellScript',
                '--comment', 'stockdrop verify (read-only)', '--parameters', "file://$file")).Command.CommandId
    } finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 36; $i++) {
        Start-Sleep -Seconds 5
        $r = & aws ssm get-command-invocation --region $Region --command-id $id --instance-id $InstanceId --output json 2>$null | ConvertFrom-Json
        if ($r -and $r.Status -notin @('Pending', 'InProgress', 'Delayed')) { return $r.StandardOutputContent.Trim() }
    }
    return ''
}

function Get-PoolInstances([string]$Pool) {
    $asg = (Invoke-Aws @('autoscaling', 'describe-auto-scaling-groups', '--auto-scaling-group-names', "$Name-$Pool")).AutoScalingGroups[0]
    return @($asg.Instances | Where-Object { $_.LifecycleState -eq 'InService' } | ForEach-Object { $_.InstanceId })
}

$out = terraform -chdir=envs/prod output -json | ConvertFrom-Json
$hosts = $out.hosts.value

# 1) ASG와 대상 그룹
$general = Get-PoolInstances 'general'
$purchase = Get-PoolInstances 'purchase'
Report 'ASG 일반 InService' ($general.Count -ge 2) "$($general.Count)대"
Report 'ASG 구매 InService' ($purchase.Count -ge 2) "$($purchase.Count)대"
foreach ($tg in $out.alb_target_groups.value.PSObject.Properties) {
    $health = (Invoke-Aws @('elbv2', 'describe-target-health', '--target-group-arn', $tg.Value)).TargetHealthDescriptions
    $healthy = @($health | Where-Object { $_.TargetHealth.State -eq 'healthy' }).Count
    Report "대상 그룹 $($tg.Name) healthy" ($healthy -ge 2) "$healthy/$(@($health).Count)"
}

# 2) DNS와 HTTPS (네임서버 변경 후에만 의미 있음)
$zone = $out.public_zone_id.value
$apex = (Invoke-Aws @('route53', 'get-hosted-zone', '--id', $zone)).HostedZone.Name.TrimEnd('.')
foreach ($sub in 'api', 'pay') {
    $url = "https://$sub.$apex/actuator/health/readiness"
    try {
        $code = (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 10).StatusCode
        Report "$sub readiness" ($code -eq 200) $url
    } catch {
        Report "$sub readiness" $false "$url ($($_.Exception.Message)) - 네임서버·enable_https 확인"
    }
}

# 3) Eureka 등록 주소: 서비스마다 등록된 인스턴스 주소:포트
if ($general.Count -gt 0) {
    $apps = Invoke-Ssm $general[0] @(
        "curl -sf -H 'Accept: application/json' http://localhost:8761/eureka/apps | python3 -c 'import json,sys; [print(a[""name""], *sorted(i[""ipAddr""]+"":""+str(i[""port""][""$""]) for i in a[""instance""])) for a in json.load(sys.stdin)[""applications""][""application""]]'"
    )
    Report 'Eureka 등록' ([bool]$apps) $(if ($apps) { "`n$apps" } else { '응답 없음(이 서버에 Eureka가 없을 수 있음)' })
}

# 4) Kafka 토픽
$topics = Invoke-Ssm $hosts.kafka.instance_id @("docker exec -e KAFKA_OPTS= stockdrop-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list | grep -c '^stockdrop\.'")
Report 'Kafka 토픽 수' ($topics -eq '19') "$topics개 (기대 19)"

# 5) 접속 주소: 구매 풀은 Command DB, 조회 서비스는 RDS (주소만 확인, 비밀번호는 보지 않음)
if ($purchase.Count -gt 0) {
    foreach ($id in $purchase) {
        $url = Invoke-Ssm $id @("grep -h '^DB_URL=' /etc/stockdrop/order-command-service.env /etc/stockdrop/product-command-service.env 2>/dev/null | sort -u")
        Report "구매 서버 $id DB" ($url -match 'command-db\.') ($url -replace "`n", ' ')
    }
}
if ($general.Count -gt 0) {
    $url = Invoke-Ssm $general[0] @("grep -h '^DB_URL=' /etc/stockdrop/product-query-service.env /etc/stockdrop/order-query-service.env 2>/dev/null | sort -u")
    Report '조회 서비스 DB' ($url -match '\.rds\.amazonaws\.com') ($url -replace "`n", ' ')
}

# 6) Prometheus 수집 대상: job별 up/전체
$targets = Invoke-Ssm $hosts.monitoring.instance_id @(
    "curl -sf http://127.0.0.1:9095/api/v1/targets | python3 -c 'import json,sys,collections as c; ts=json.load(sys.stdin)[""data""][""activeTargets""]; all=c.Counter(t[""labels""][""job""] for t in ts); up=c.Counter(t[""labels""][""job""] for t in ts if t[""health""]==""up""); [print(k, str(up[k])+""/""+str(all[k])) for k in sorted(all)]'"
)
Report 'Prometheus 대상' ([bool]$targets) $(if ($targets) { "`n$targets" } else { '응답 없음' })

# 7) S3 presigned URL: 없는 키를 서명해 인터넷에서 요청하면 403이 아니라 404여야 합니다(서명·버킷 정책 정상).
$bucket = $out.s3_buckets.value.'product-images'
$signed = & aws s3 presign "s3://$bucket/verify/does-not-exist-$([guid]::NewGuid()).txt" --region $Region --expires-in 60
try {
    Invoke-WebRequest -UseBasicParsing -Uri $signed -TimeoutSec 10 | Out-Null
    Report 'S3 presigned GET' $false '없는 키인데 200이 왔습니다'
} catch {
    $status = [int]$_.Exception.Response.StatusCode
    Report 'S3 presigned GET' ($status -eq 404) "HTTP $status (기대 404)"
}

Write-Host ''
if ($script:failures -eq 0) { Write-Host '모든 점검 통과' -ForegroundColor Green } else { Write-Host "실패 $($script:failures)건" -ForegroundColor Red; exit 1 }
