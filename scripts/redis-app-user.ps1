<#
  ElastiCache Redis에 앱 사용자를 만들거나 비밀번호를 SSM 값으로 맞추고, Terraform이 만든 사용자 그룹에 넣습니다.
  비밀번호를 Terraform이 다루지 않게 하려고 apply와 분리했습니다. 여러 번 실행해도 됩니다.

  사전 조건: terraform apply 완료, SSM SecureString /stockdrop/prod/shared/REDIS_PASSWORD (16~128자, 공백·따옴표·@ 없이)
  예: .\scripts\redis-app-user.ps1
#>
param(
    [string]$Name = 'stockdrop-prod',
    [string]$Region = 'ap-northeast-2',
    [string]$ParameterPath = '/stockdrop/prod',
    [string]$UserName = 'stockdrop-app'
)
$ErrorActionPreference = 'Stop'
$groupId = "$Name-cache"
$userId = "$Name-cache-app"

function Invoke-Aws([string[]]$Arguments) {
    $out = & aws @Arguments --region $Region --output json
    if ($LASTEXITCODE -ne 0) { throw "aws $($Arguments[0..1] -join ' ') 실패" }
    if ($out) { return ($out -join "`n") | ConvertFrom-Json }
}

# 명령 인자에 비밀번호가 보이지 않도록 JSON 파일로 넘기고 바로 지웁니다.
function Invoke-AwsWithSecret([string]$Command, [hashtable]$Body) {
    $file = Join-Path ([IO.Path]::GetTempPath()) "stockdrop-redis-$([guid]::NewGuid()).json"
    try {
        [IO.File]::WriteAllText($file, ($Body | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
        & aws elasticache $Command --cli-input-json "file://$file" --region $Region --output json | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "aws elasticache $Command 실패" }
    } finally {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
}

function Wait-Active([scriptblock]$Status, [string]$What) {
    $deadline = (Get-Date).AddMinutes(10)
    while ((& $Status) -ne 'active') {
        if ((Get-Date) -gt $deadline) { throw "$What 이(가) 10분 안에 active가 되지 않았습니다." }
        Start-Sleep -Seconds 10
    }
}

$password = (Invoke-Aws @('ssm', 'get-parameter', '--name', "$ParameterPath/shared/REDIS_PASSWORD", '--with-decryption')).Parameter.Value
if ($password.Length -lt 16 -or $password.Length -gt 128 -or $password -match '[\s"''@]') {
    throw 'REDIS_PASSWORD는 16~128자이며 공백·따옴표·@를 쓸 수 없습니다.'
}

try {
    $existing = $null
    try { $existing = (Invoke-Aws @('elasticache', 'describe-users', '--user-id', $userId)).Users } catch { }
    # 위험 명령(FLUSHALL, CONFIG 등)은 막고 캐시에 필요한 명령만 허용합니다.
    $access = 'on ~* &* +@all -@dangerous'
    if ($existing) {
        Invoke-AwsWithSecret 'modify-user' @{ UserId = $userId; AccessString = $access; AuthenticationMode = @{ Type = 'password'; Passwords = @($password) } }
        Write-Host "사용자 갱신: $userId"
    } else {
        Invoke-AwsWithSecret 'create-user' @{ UserId = $userId; UserName = $UserName; Engine = 'redis'; AccessString = $access; AuthenticationMode = @{ Type = 'password'; Passwords = @($password) } }
        Write-Host "사용자 생성: $userId"
    }
} finally {
    $password = $null
}
Wait-Active { (Invoke-Aws @('elasticache', 'describe-users', '--user-id', $userId)).Users[0].Status } "사용자 $userId"

$group = (Invoke-Aws @('elasticache', 'describe-user-groups', '--user-group-id', $groupId)).UserGroups[0]
if ($group.UserIds -notcontains $userId) {
    Invoke-Aws @('elasticache', 'modify-user-group', '--user-group-id', $groupId, '--user-ids-to-add', $userId) | Out-Null
    Write-Host "그룹에 추가: $groupId"
}
Wait-Active { (Invoke-Aws @('elasticache', 'describe-user-groups', '--user-group-id', $groupId)).UserGroups[0].Status } "그룹 $groupId"
Write-Host "완료: 서비스에는 REDIS_USERNAME=$UserName 과 같은 REDIS_PASSWORD를 넣습니다." -ForegroundColor Green
