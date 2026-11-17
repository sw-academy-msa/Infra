<#
  고정 역할 EC2(Kafka, Command DB, 모니터링)에 hosts/<역할>/ 파일을 올리고 start.sh를 실행합니다.
  SSH 키 없이 SSM Run Command만 씁니다. 파일은 /opt/stockdrop/<역할>/에 덮어쓰며, /data의 데이터는 지우지 않습니다.
  여러 번 실행해도 됩니다. 순서: kafka → command-db → monitoring → rds
    rds: 일반 RDS의 서비스별 DB·계정을 만듭니다. RDS는 사설망에만 있어 모니터링 EC2에서 실행합니다.

  예: .\hosts\deploy.ps1 -Role kafka
      .\hosts\deploy.ps1 -Role rds -DryRun
  필요: AWS CLI 로그인(aws configure 또는 SSO), terraform apply로 만든 자원, docs/parameters.md의 SSM 값
#>
param(
    [Parameter(Mandatory)][ValidateSet('kafka', 'command-db', 'monitoring', 'rds')][string]$Role,
    [string]$Name = 'stockdrop-prod',
    [string]$Region = 'ap-northeast-2',
    [string]$ParameterPath = '/stockdrop/prod',
    # AWS에 보내지 않고 서버에서 실행할 명령만 출력합니다.
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

# rds는 모니터링 EC2에서 실행합니다. 나머지는 역할 이름의 EC2가 대상입니다.
$target = if ($Role -eq 'rds') { 'monitoring' } else { $Role }
$extraEnv = "NAME=$Name PARAMETER_PATH=$ParameterPath"

if ($DryRun) {
    $instanceId, $privateIp = 'i-dryrun', '10.20.10.40'
    if ($Role -eq 'rds') { $extraEnv += ' RDS_HOST=<rds-endpoint> RDS_SECRET_ARN=<secret-arn>' }
} else {
    # Terraform host 모듈이 붙인 Name 태그로 찾습니다. 같은 역할이 두 대면 잘못된 상태이므로 멈춥니다.
    $found = aws ec2 describe-instances --region $Region `
        --filters "Name=tag:Name,Values=$Name-$target" "Name=instance-state-name,Values=running" `
        --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress]' --output text
    if ($LASTEXITCODE -ne 0) { throw 'EC2 조회에 실패했습니다. aws configure와 리전을 확인하세요.' }
    $rows = @($found -split "`r?`n" | Where-Object { $_.Trim() })
    if ($rows.Count -ne 1) { throw "$Name-$target 실행 중인 EC2가 정확히 1대가 아닙니다: $($rows.Count)대" }
    $instanceId, $privateIp = $rows[0] -split '\s+'

    if ($Role -eq 'rds') {
        # 주소와 Secret ARN만 넘깁니다. 비밀번호 자체는 서버가 Secrets Manager에서 직접 읽습니다.
        $rds = aws rds describe-db-instances --region $Region --db-instance-identifier "$Name-general" `
            --query 'DBInstances[0].[Endpoint.Address,MasterUserSecret.SecretArn]' --output text
        if ($LASTEXITCODE -ne 0) { throw "RDS $Name-general 조회에 실패했습니다." }
        $rdsHost, $rdsSecret = ($rds -split '\s+')
        $extraEnv += " RDS_HOST=$rdsHost RDS_SECRET_ARN=$rdsSecret"
    }
}
Write-Host "대상: $Name-$target ($instanceId, $privateIp) 역할 $Role"

# 줄바꿈을 LF로 바꿔 base64로 보냅니다. Windows에서 편집해도 리눅스 셸 스크립트가 깨지지 않습니다.
$dir = "/opt/stockdrop/$Role"
$commands = @('set -euo pipefail', "mkdir -p $dir")
# 텍스트 구성 파일만 보냅니다. 서버에서 받는 jar나 비밀값 파일은 올리지 않습니다.
$files = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $Role) -File |
    Where-Object { $_.Extension -in @('.yaml', '.yml', '.sh', '.sql', '.json') }
foreach ($file in $files) {
    $text = [IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n"
    $b64 = [Convert]::ToBase64String((New-Object Text.UTF8Encoding $false).GetBytes($text))
    $commands += "echo '$b64' | base64 -d > $dir/$($file.Name)"
}
$commands += "chmod +x $dir/*.sh 2>/dev/null || true"

# /data가 EBS가 아니면 루트 디스크에 쓰게 되므로 멈춥니다(rds는 디스크를 쓰지 않음). 실행은 각 start.sh가 합니다.
if ($Role -ne 'rds') {
    $commands += 'mountpoint -q /data || { echo "/data EBS가 연결되지 않았습니다"; exit 1; }'
}
$commands += "AWS_REGION=$Region PRIVATE_IP=$privateIp $extraEnv bash $dir/start.sh"

if ($DryRun) {
    $commands | ForEach-Object { if ($_.Length -gt 160) { $_.Substring(0, 160) + '...' } else { $_ } }
    return
}

# 따옴표가 섞인 명령을 PowerShell 5.1 인자로 넘기면 깨지므로 JSON 파일로 전달하고 바로 지웁니다.
$params = Join-Path ([IO.Path]::GetTempPath()) "stockdrop-ssm-$([guid]::NewGuid()).json"
try {
    $json = @{ commands = $commands; executionTimeout = @('900') } | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($params, $json, (New-Object Text.UTF8Encoding $false))
    $commandId = aws ssm send-command --region $Region --instance-ids $instanceId `
        --document-name AWS-RunShellScript --comment "stockdrop $Role deploy" `
        --parameters "file://$params" --query 'Command.CommandId' --output text
    if ($LASTEXITCODE -ne 0) { throw 'SSM 명령 전송에 실패했습니다. 인스턴스가 SSM에 등록됐는지 확인하세요.' }
} finally {
    Remove-Item -LiteralPath $params -ErrorAction SilentlyContinue
}

Write-Host "실행 중... (명령 ID $commandId)"
# aws ssm wait는 약 100초에서 끝나므로, 첫 Kafka 기동처럼 오래 걸리는 경우를 위해 15분까지 직접 확인합니다.
$deadline = (Get-Date).AddMinutes(15)
do {
    Start-Sleep -Seconds 5
    $result = aws ssm get-command-invocation --region $Region --command-id $commandId --instance-id $instanceId --output json 2>$null | ConvertFrom-Json
} while ((-not $result -or $result.Status -in @('Pending', 'InProgress', 'Delayed')) -and (Get-Date) -lt $deadline)
if (-not $result) { throw "결과를 받지 못했습니다. 명령 ID $commandId로 콘솔에서 확인하세요." }
Write-Host $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Host $result.StandardErrorContent -ForegroundColor Yellow }
if ($result.Status -ne 'Success') { throw "배포 실패: $($result.Status)" }
Write-Host "완료: $Role" -ForegroundColor Green
