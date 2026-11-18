<#
  운영 설정값·비밀값을 SSM Parameter Store(/stockdrop/prod)에 넣습니다. 목록과 규칙은 docs/parameters.md입니다.
  여러 번 실행해도 됩니다. 이미 있는 비밀값(SecureString)과 한 번 정한 값(서비스 주체 등)은 덮어쓰지 않고, 일반 설정값만 맞춥니다.
  비밀값은 화면·명령 인자에 남기지 않고 임시 JSON 파일로 넘긴 뒤 바로 지웁니다.

  값을 정하는 순서
    1) SSM에 이미 있으면 그대로 둡니다.
    2) -EnvRoot가 있으면 그 폴더의 서비스별 .env·.keys에서 가져옵니다(기존 서버 데이터를 옮길 때. 암호화 키가 같아야 합니다).
    3) 만들 수 있는 값(토큰·암호화 키·JWT 서명 키·VAPID 키·서비스 인증 비밀값)은 새로 만듭니다.
    4) 외부에서 받은 값(토스·OpenAI·메일)은 입력받습니다. 비워 두면 건너뛰고 마지막에 목록으로 알려 줍니다.
  DB 비밀번호는 실행할 때 한 번 입력받아 서비스 DB 8개와 Command DB 관리자·지표 계정에 같은 값으로 넣습니다.

  RDS·Redis 주소는 terraform apply 뒤에 생깁니다. apply 전에는 그 값만 건너뛰고, apply 뒤 -TerraformOutput으로 다시 실행합니다.

  필요한 것: AWS CLI v2, 새로 만들 값이 있으면 Node.js(키 생성)와 Docker(bcrypt 해시)
  예:
    .\scripts\put-parameters.ps1 -DryRun                              # 무엇을 넣을지 이름만 출력
    .\scripts\put-parameters.ps1                                      # apply 전
    cd envs\prod; terraform output -json > ..\..\tf-output.json; cd ..\..
    .\scripts\put-parameters.ps1 -TerraformOutput .\tf-output.json    # apply 뒤(RDS·Redis 주소)
#>
param(
    [string]$AwsProfile = 'stockdrop',
    [string]$Region = 'ap-northeast-2',
    [string]$ParameterPath = '/stockdrop/prod',
    [string]$Name = 'stockdrop-prod',
    [string]$Domain = 'stockdrop.cloud',
    [string]$FrontendOrigins = 'https://stockdrop-app.vercel.app',
    [string]$EnvRoot,
    [string]$TerraformOutput,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$env:AWS_PROFILE = $AwsProfile
$awsCommand = Get-Command aws -ErrorAction SilentlyContinue
$script:Aws = if ($awsCommand) { $awsCommand.Source } else { 'C:\Program Files\Amazon\AWSCLIV2\aws.exe' }
if (-not (Test-Path $script:Aws) -and -not $awsCommand) { throw 'AWS CLI를 찾을 수 없습니다.' }

function Invoke-Aws([string[]]$Arguments) {
    $out = & $script:Aws @Arguments --region $Region --output json
    if ($LASTEXITCODE -ne 0) { throw "aws $($Arguments[0..1] -join ' ') 실패" }
    if ($out) { return ($out -join "`n") | ConvertFrom-Json }
}

# ---------- 현재 SSM 상태 ----------
$account = (Invoke-Aws @('sts', 'get-caller-identity')).Account
Write-Host "계정 $account, 리전 $Region, 경로 $ParameterPath$(if ($DryRun) { ' (DryRun: 저장하지 않음)' })"
$existing = @{}
foreach ($p in @(Invoke-Aws @('ssm', 'get-parameters-by-path', '--path', $ParameterPath, '--recursive'))) {
    foreach ($item in $p.Parameters) { $existing[$item.Name] = $item }
}

$script:Added = New-Object System.Collections.Generic.List[string]
$script:Updated = New-Object System.Collections.Generic.List[string]
$script:Missing = New-Object System.Collections.Generic.List[string]

# 명령 인자에 값이 보이지 않도록 JSON 파일로 넘기고 바로 지웁니다.
function Set-Parameter([string]$Key, [string]$Value, [string]$Type, [bool]$Overwrite) {
    $full = "$ParameterPath/$Key"
    # 같은 실행에서 뒤의 값이 앞에서 정한 값(서비스 주체 등)을 읽을 수 있게 기록합니다. 비밀값은 기록하지 않습니다.
    $existing[$full] = [pscustomobject]@{ Name = $full; Type = $Type; Value = $(if ($Type -eq 'String') { $Value } else { $null }) }
    if ($DryRun) { return }
    $file = Join-Path ([IO.Path]::GetTempPath()) "stockdrop-ssm-$([guid]::NewGuid()).json"
    try {
        $body = @{ Name = $full; Value = $Value; Type = $Type; Overwrite = $Overwrite; Tier = 'Standard' }
        [IO.File]::WriteAllText($file, ($body | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
        & $script:Aws ssm put-parameter --cli-input-json "file://$file" --region $Region --output json | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "저장 실패: $full" }
    } finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
}

function Test-Exists([string]$Key) { return $existing.ContainsKey("$ParameterPath/$Key") }

# 일반 설정값: 없으면 넣고, 다르면 맞춥니다.
function Set-Config([string]$Key, [string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { $script:Missing.Add($Key); return }
    $current = $existing["$ParameterPath/$Key"]
    if ($current -and $current.Type -eq 'String' -and $current.Value -eq $Value) { return }
    if ($current -and $current.Type -ne 'String') { Write-Warning "$Key 는 $($current.Type)로 있어 그대로 둡니다."; return }
    Set-Parameter $Key $Value 'String' ([bool]$current)
    if ($current) { $script:Updated.Add($Key) } else { $script:Added.Add($Key) }
}

# 한 번 정하면 바꾸지 않는 값: 없을 때만 $Producer로 만들어 넣습니다.
function Set-Once([string]$Key, [scriptblock]$Producer, [string]$Type = 'SecureString') {
    if (Test-Exists $Key) { return }
    $value = & $Producer
    if ([string]::IsNullOrEmpty($value)) { $script:Missing.Add($Key); return }
    Set-Parameter $Key $value $Type $false
    $script:Added.Add($Key)
}

function Get-Stored([string]$Key) {
    $item = $existing["$ParameterPath/$Key"]
    if (-not $item) { return $null }
    if ($item.Type -eq 'String') { return $item.Value }
    return (Invoke-Aws @('ssm', 'get-parameter', '--name', "$ParameterPath/$Key", '--with-decryption')).Parameter.Value
}

# ---------- 기존 .env (데이터를 옮길 때) ----------
$folders = @{
    'account-service' = 'AccountService'; 'product-command-service' = 'ProductCommandService'
    'product-query-service' = 'ProductQueryService'; 'order-command-service' = 'OrderCommandService'
    'order-query-service' = 'OrderQueryService'; 'payment-service' = 'PaymentService'
    'ai-service' = 'AIService'; 'notification-service' = 'NotificationService'
}
$envCache = @{}
function Get-EnvValue([string]$Service, [string]$Key) {
    if (-not $EnvRoot) { return $null }
    if (-not $envCache.ContainsKey($Service)) {
        $map = @{}
        $file = Join-Path (Join-Path $EnvRoot $folders[$Service]) '.env'
        if (Test-Path $file) {
            foreach ($line in [IO.File]::ReadAllLines($file)) {
                if ($line -match '^\s*([^#=\s][^=]*?)\s*=\s*(.*)$') {
                    $map[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
                }
            }
        }
        $envCache[$Service] = $map
    }
    $value = $envCache[$Service][$Key]
    if ([string]::IsNullOrEmpty($value)) { return $null }
    return $value
}
function Get-KeyFile([string]$Service, [string]$File) {
    if (-not $EnvRoot) { return $null }
    $path = Join-Path (Join-Path (Join-Path $EnvRoot $folders[$Service]) '.keys') $File
    if (Test-Path $path) { return [IO.File]::ReadAllBytes($path) }
    return $null
}

# ---------- 값 만들기 ----------
function New-Hex([int]$Bytes) {
    $b = New-Object byte[] $Bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return ([BitConverter]::ToString($b) -replace '-', '').ToLower()
}
function New-Base64Key {
    $b = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return [Convert]::ToBase64String($b)
}
function Invoke-Node([string]$Code) {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw '키를 새로 만들려면 Node.js가 필요합니다.' }
    $out = $Code | & node -
    if ($LASTEXITCODE -ne 0) { throw '키 생성 실패' }
    return ($out -join '').Trim()
}
# Account가 읽는 형식: kid가 있는 2048비트 RSA 개인키 JWK
function New-SigningJwk {
    return Invoke-Node @'
const c = require('crypto');
const { privateKey } = c.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = privateKey.export({ format: 'jwk' });
process.stdout.write(JSON.stringify({ ...jwk, kid: c.randomUUID(), alg: 'RS256', use: 'sig' }));
'@
}
# Web Push VAPID: 공개키는 비압축 P-256 점(65바이트), 개인키는 32바이트. 둘 다 base64url
function New-VapidPair {
    $json = Invoke-Node @'
const c = require('crypto');
const { privateKey } = c.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const j = privateKey.export({ format: 'jwk' });
const pub = Buffer.concat([Buffer.from([4]), Buffer.from(j.x, 'base64url'), Buffer.from(j.y, 'base64url')]).toString('base64url');
process.stdout.write(JSON.stringify({ publicKey: pub, privateKey: j.d }));
'@
    return $json | ConvertFrom-Json
}
# Account는 서비스 비밀값을 BCrypt 해시로만 가집니다. 비밀값은 명령 인자가 아니라 환경변수로 컨테이너에 넘깁니다.
# (PowerShell 파이프는 끝에 CR을 붙여 해시가 원문과 달라지므로 쓰지 않습니다)
function New-BcryptHash([string]$Secret) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'BCrypt 해시를 만들려면 Docker가 필요합니다.' }
    $env:STOCKDROP_BCRYPT_INPUT = $Secret
    try { $out = & docker run --rm -e STOCKDROP_BCRYPT_INPUT httpd:2.4-alpine sh -c 'printf "%s" "$STOCKDROP_BCRYPT_INPUT" | htpasswd -niBC 12 svc' }
    finally { Remove-Item Env:STOCKDROP_BCRYPT_INPUT -ErrorAction SilentlyContinue }
    if ($LASTEXITCODE -ne 0) { throw 'BCrypt 해시 생성 실패' }
    $hash = (($out -join '').Trim() -split ':', 2)[1]
    if ($hash -notmatch '^\$2[aby]\$12\$[./A-Za-z0-9]{53}$') { throw 'BCrypt 해시 형식이 올바르지 않습니다.' }
    return $hash
}
function Read-Secret([string]$Prompt) {
    if ($DryRun) { return 'dry-run' }
    $secure = Read-Host -AsSecureString $Prompt
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Read-Plain([string]$Prompt, [string]$Default) {
    if ($DryRun) { return $Default }
    $value = Read-Host "$Prompt$(if ($Default) { " [$Default]" })"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

# 서비스 인증 비밀값(원문)과 Account의 BCrypt 해시는 짝이라 함께 정합니다.
function Set-ClientPair([string]$SecretKey, [string]$HashKey, [string]$EnvService, [string]$EnvSecretName, [string]$EnvHashName) {
    $hasSecret = Test-Exists $SecretKey; $hasHash = Test-Exists $HashKey
    if ($hasSecret -and $hasHash) { return }
    if ($hasSecret -ne $hasHash) {
        Write-Warning "$SecretKey 와 $HashKey 중 하나만 있습니다. 짝이 맞지 않으면 서비스 인증이 실패하니 둘 다 지우고 다시 실행하세요."
        return
    }
    $secret = Get-EnvValue $EnvService $EnvSecretName
    $hash = Get-EnvValue 'account-service' $EnvHashName
    if (-not ($secret -and $hash)) {
        if ($DryRun) { $secret = 'dry-run'; $hash = 'dry-run' }
        else { $secret = New-Hex 24; $hash = New-BcryptHash $secret }
    }
    Set-Parameter $SecretKey $secret 'SecureString' $false; $script:Added.Add($SecretKey)
    Set-Parameter $HashKey $hash 'SecureString' $false; $script:Added.Add($HashKey)
}

# ---------- DB 비밀번호 ----------
$dbKeys = @('account-service', 'product-query-service', 'order-query-service', 'payment-service', 'ai-service',
    'notification-service', 'product-command-service', 'order-command-service' | ForEach-Object { "$_/DB_PASSWORD" }) +
    @('command-db/ADMIN_PASSWORD', 'command-db/METRICS_PASSWORD')
$needDb = @($dbKeys | Where-Object { -not (Test-Exists $_) })
$dbPassword = $null
if ($needDb.Count -gt 0) {
    if ($DryRun) { $dbPassword = 'dry-run-password-0000000' }
    else {
        # RDS·Command DB 초기화 스크립트와 같은 규칙입니다(접속 문자열·SQL에서 깨지지 않는 문자만).
        while ($true) {
            $first = Read-Secret 'DB 공통 비밀번호 (20자 이상, 영문·숫자·_.~- 만)'
            if ($first -notmatch '^[A-Za-z0-9_.~-]{20,200}$') { Write-Warning '형식이 맞지 않습니다.'; continue }
            if ((Read-Secret '한 번 더 입력') -ne $first) { Write-Warning '두 값이 다릅니다.'; continue }
            $dbPassword = $first; break
        }
    }
}
foreach ($key in $dbKeys) { Set-Once $key { $dbPassword } }

# ---------- Terraform 출력(apply 뒤) ----------
$tf = $null
if ($TerraformOutput) { $tf = [IO.File]::ReadAllText((Resolve-Path $TerraformOutput)) | ConvertFrom-Json }
$rdsHost = if ($tf) { ($tf.rds.value.endpoint -split ':')[0] } else { $null }
$redisHost = if ($tf) { $tf.redis.value.primary_endpoint } else { $null }
function Get-Bucket([string]$Purpose) { return "$Name-$Purpose-$account" }

# ---------- shared ----------
Set-Config 'shared/JWT_ISSUER' "https://api.$Domain"
Set-Config 'shared/JWT_AUDIENCE' 'stockdrop-api'
Set-Config 'shared/ACCOUNT_JWKS_URI' "https://api.$Domain/.well-known/jwks.json"
Set-Config 'shared/APP_ALLOWED_ORIGINS' $FrontendOrigins
Set-Config 'shared/MONITORING_OUTBOX_ENABLED' 'true'
Set-Config 'shared/REDIS_PORT' '6379'
Set-Config 'shared/REDIS_SSL_ENABLED' 'true'
Set-Config 'shared/REDIS_USERNAME' 'stockdrop-app'
Set-Once 'shared/MONITORING_SCRAPE_TOKEN' { $v = Get-EnvValue 'account-service' 'MONITORING_SCRAPE_TOKEN'; if ($v) { $v } else { New-Hex 32 } }
Set-Once 'shared/REDIS_PASSWORD' { New-Hex 32 }
Set-Once 'shared/ORDER_SERVICE_SUBJECT' { $v = Get-EnvValue 'account-service' 'ORDER_SERVICE_SUBJECT'; if ($v) { $v } else { [guid]::NewGuid().ToString() } } 'String'
Set-Once 'shared/NOTIFICATION_SERVICE_SUBJECT' { $v = Get-EnvValue 'notification-service' 'NOTIFICATION_SERVICE_SUBJECT'; if ($v) { $v } else { [guid]::NewGuid().ToString() } } 'String'
Set-Once 'shared/ACCOUNT_WITHDRAWAL_SUBJECT' { $v = Get-EnvValue 'account-service' 'ACCOUNT_WITHDRAWAL_SUBJECT'; if ($v) { $v } else { [guid]::NewGuid().ToString() } } 'String'
# Redis를 끈 상태(enable_redis=false)면 output이 null이라 주소를 넣지 않습니다.
if ($redisHost) { Set-Config 'shared/REDIS_HOST' $redisHost } elseif (-not $tf) { $script:Missing.Add('shared/REDIS_HOST (apply 뒤, Redis를 켠 경우만)') }

# ---------- 서비스별 DB 접속 ----------
$databases = [ordered]@{
    'account-service' = @('stockdrop', 'account', 'rds'); 'product-query-service' = @('product_query', 'product_query', 'rds')
    'order-query-service' = @('orders_query', 'orders_query', 'rds'); 'payment-service' = @('payment', 'payment', 'rds')
    'ai-service' = @('ai_service', 'ai', 'rds'); 'notification-service' = @('notification_service', 'notification', 'rds')
    'product-command-service' = @('product_command', 'product', 'command'); 'order-command-service' = @('order_command', 'orders', 'command')
}
foreach ($svc in $databases.Keys) {
    $db, $user, $kind = $databases[$svc]
    Set-Config "$svc/DB_USERNAME" $user
    if ($kind -eq 'command') { Set-Config "$svc/DB_URL" "jdbc:postgresql://command-db.stockdrop.internal:5432/$db" }
    elseif ($rdsHost) { Set-Config "$svc/DB_URL" "jdbc:postgresql://${rdsHost}:5432/$db" }
    else { $script:Missing.Add("$svc/DB_URL (apply 뒤)") }
}

# ---------- 단일 EC2 ----------
Set-Once 'monitoring/GRAFANA_PASSWORD' { New-Hex 12 }

# ---------- account-service ----------
Set-Config 'account-service/JWT_SIGNING_KEY_LOCATION' 'file:/run/secrets/stockdrop/account-signing.jwk'
Set-Once 'account-service/files/account-signing.jwk' {
    $bytes = Get-KeyFile 'account-service' 'account-signing.jwk'
    if (-not $bytes) { $bytes = if ($DryRun) { [byte[]](1) } else { [Text.Encoding]::UTF8.GetBytes((New-SigningJwk)) } }
    [Convert]::ToBase64String($bytes)
}
Set-Once 'account-service/SELLER_DATA_ENCRYPTION_KEY' {
    $v = Get-EnvValue 'account-service' 'SELLER_DATA_ENCRYPTION_KEY'
    if (-not $v) { $raw = Get-KeyFile 'account-service' 'seller-data.key'; if ($raw) { $v = [Convert]::ToBase64String($raw) } }
    if ($v) { $v } else { New-Base64Key }
}
Set-ClientPair 'order-command-service/ORDER_SERVICE_CLIENT_SECRET' 'account-service/ORDER_SERVICE_SECRET_HASH' `
    'order-command-service' 'ORDER_SERVICE_CLIENT_SECRET' 'ORDER_SERVICE_SECRET_HASH'
# Notification의 서비스 인증 등록입니다. 키 이름에 하이픈이 있어 Spring 속성 이름 그대로 넣습니다.
$notifyClient = 'account.service-auth.clients.notification-service'
Set-ClientPair 'notification-service/NOTIFICATION_CLIENT_SECRET' "account-service/$notifyClient.secret-hash" `
    'notification-service' 'NOTIFICATION_CLIENT_SECRET' "$notifyClient.secret-hash"
$notifySubject = if ($DryRun -and -not (Test-Exists 'shared/NOTIFICATION_SERVICE_SUBJECT')) { 'dry-run' } else { Get-Stored 'shared/NOTIFICATION_SERVICE_SUBJECT' }
Set-Config "account-service/$notifyClient.subject" $notifySubject
Set-Config "account-service/$notifyClient.scopes" 'account.notifications.read,ai.personalization.read'
Set-Config 'account-service/SELLER_CERTIFICATE_BUCKET' (Get-Bucket 'seller-certificates')
Set-Config 'account-service/ACCOUNT_SERVICE_AUTH_ENABLED' 'true'
Set-Config 'account-service/ACCOUNT_WITHDRAWAL_ENABLED' 'true'
Set-Config 'account-service/ACCOUNT_OUTBOX_PUBLISHER_ENABLED' 'true'
if (-not (Test-Exists 'account-service/MAIL_PASSWORD')) {
    $mailUser = Get-EnvValue 'account-service' 'MAIL_USERNAME'
    if (-not $mailUser) { $mailUser = Read-Plain '메일 발송 계정(예: 이름@gmail.com, 비우면 건너뜀)' '' }
    if ($mailUser) {
        Set-Config 'account-service/MAIL_HOST' (Read-Plain '메일 서버' 'smtp.gmail.com')
        Set-Config 'account-service/MAIL_USERNAME' $mailUser
        Set-Config 'account-service/MAIL_FROM' $mailUser
        Set-Once 'account-service/MAIL_PASSWORD' { $v = Get-EnvValue 'account-service' 'MAIL_PASSWORD'; if ($v) { $v } else { Read-Secret '메일 앱 비밀번호' } }
    } else { $script:Missing.Add('account-service/MAIL_*') }
}

# ---------- product-command-service ----------
Set-Config 'product-command-service/PRODUCT_OUTBOX_PUBLISHER_ENABLED' 'true'
Set-Config 'product-command-service/PRODUCT_AI_CONSUMER_ENABLED' 'true'
Set-Config 'product-command-service/PRODUCT_IMAGES_ENABLED' 'true'
Set-Config 'product-command-service/PRODUCT_IMAGES_BUCKET' (Get-Bucket 'product-images')
Set-Config 'product-command-service/PRODUCT_IMAGES_REGION' $Region

# ---------- product-query-service ----------
Set-Config 'product-query-service/QUERY_EVENTS_ENABLED' 'true'
Set-Config 'product-query-service/QUERY_IMAGES_ENABLED' 'true'
Set-Config 'product-query-service/QUERY_IMAGES_BUCKET' (Get-Bucket 'product-images')
Set-Config 'product-query-service/QUERY_IMAGES_REGION' $Region

# ---------- order-command-service ----------
Set-Config 'order-command-service/ORDER_CHECKOUT_TERMS_VERSION' 'checkout-v1'
Set-Config 'order-command-service/ORDER_ACCOUNT_ENABLED' 'true'
Set-Config 'order-command-service/ORDER_PRODUCT_ENABLED' 'true'
Set-Once 'order-command-service/ORDER_PRODUCT_SERVICE_TOKEN' { $v = Get-EnvValue 'order-command-service' 'ORDER_PRODUCT_SERVICE_TOKEN'; if ($v) { $v } else { New-Hex 32 } }
Set-Config 'order-command-service/ORDER_SERVICE_AUTH_ENABLED' 'true'
Set-Config 'order-command-service/ORDER_SERVICE_CLIENT_ID' 'order-command-service'
Set-Config 'order-command-service/ORDER_OUTBOX_PUBLISHER_ENABLED' 'true'
Set-Config 'order-command-service/ORDER_PAYMENT_EVENTS_ENABLED' 'true'
Set-Config 'order-command-service/ORDER_IMAGES_ENABLED' 'true'
Set-Config 'order-command-service/ORDER_IMAGES_BUCKET' (Get-Bucket 'inquiry-images')

# ---------- order-query-service ----------
Set-Config 'order-query-service/ORDER_QUERY_EVENTS_ENABLED' 'true'

# ---------- payment-service ----------
foreach ($flag in 'PAYMENT_TOSS_ENABLED', 'PAYMENT_MESSAGING_ENABLED', 'PAYMENT_PROCESSING_ENABLED', 'PAYMENT_OUTBOX_PUBLISHER_ENABLED') {
    Set-Config "payment-service/$flag" 'true'
}
if (-not (Test-Exists 'payment-service/TOSS_CLIENT_KEY')) {
    $v = Get-EnvValue 'payment-service' 'TOSS_CLIENT_KEY'; if (-not $v) { $v = Read-Plain '토스 클라이언트 키(비우면 건너뜀)' '' }
    Set-Config 'payment-service/TOSS_CLIENT_KEY' $v
}
Set-Once 'payment-service/TOSS_SECRET_KEY' { $v = Get-EnvValue 'payment-service' 'TOSS_SECRET_KEY'; if ($v) { $v } else { Read-Secret '토스 시크릿 키(비우면 건너뜀)' } }

# ---------- ai-service ----------
foreach ($flag in 'AI_CONSUMER_ENABLED', 'AI_WORKER_ENABLED', 'AI_OUTBOX_PUBLISHER_ENABLED', 'AI_VISION_ENABLED') {
    Set-Config "ai-service/$flag" 'true'
}
Set-Config 'ai-service/PRODUCT_IMAGES_BUCKET' (Get-Bucket 'product-images')
Set-Config 'ai-service/PRODUCT_IMAGES_REGION' $Region
if (-not (Test-Exists 'ai-service/OPENAI_VISION_MODEL')) {
    $v = Get-EnvValue 'ai-service' 'OPENAI_VISION_MODEL'; if (-not $v) { $v = Read-Plain 'OpenAI 비전 모델 이름(비우면 앱 기본값)' '' }
    if ($v) { Set-Config 'ai-service/OPENAI_VISION_MODEL' $v }
}
Set-Once 'ai-service/OPENAI_API_KEY' { $v = Get-EnvValue 'ai-service' 'OPENAI_API_KEY'; if ($v) { $v } else { Read-Secret 'OpenAI API 키(비우면 건너뜀)' } }

# ---------- notification-service ----------
foreach ($flag in 'WEB_PUSH_ENABLED', 'NOTIFICATION_CONSUMER_ENABLED', 'NOTIFICATION_BUSINESS_CONSUMER_ENABLED',
    'NOTIFICATION_PRODUCT_ALERT_ENABLED', 'NOTIFICATION_WORKER_ENABLED') {
    Set-Config "notification-service/$flag" 'true'
}
Set-Once 'notification-service/PUSH_ENCRYPTION_KEY' { $v = Get-EnvValue 'notification-service' 'PUSH_ENCRYPTION_KEY'; if ($v) { $v } else { New-Base64Key } }
# VAPID 공개키·개인키는 짝입니다. 기존 브라우저 구독을 살리려면 기존 키를 옮겨야 합니다.
$hasPub = Test-Exists 'notification-service/VAPID_PUBLIC_KEY'; $hasPriv = Test-Exists 'notification-service/VAPID_PRIVATE_KEY'
if (-not ($hasPub -and $hasPriv)) {
    if ($hasPub -ne $hasPriv) { Write-Warning 'VAPID 공개키·개인키 중 하나만 있습니다. 둘 다 지우고 다시 실행하세요.' }
    else {
        $pub = Get-EnvValue 'notification-service' 'VAPID_PUBLIC_KEY'; $priv = Get-EnvValue 'notification-service' 'VAPID_PRIVATE_KEY'
        if (-not ($pub -and $priv)) {
            if ($DryRun) { $pub = 'dry-run'; $priv = 'dry-run' } else { $pair = New-VapidPair; $pub = $pair.publicKey; $priv = $pair.privateKey }
        }
        Set-Parameter 'notification-service/VAPID_PUBLIC_KEY' $pub 'String' $false; $script:Added.Add('notification-service/VAPID_PUBLIC_KEY')
        Set-Parameter 'notification-service/VAPID_PRIVATE_KEY' $priv 'SecureString' $false; $script:Added.Add('notification-service/VAPID_PRIVATE_KEY')
    }
}
if (-not (Test-Exists 'notification-service/VAPID_SUBJECT')) {
    $v = Get-EnvValue 'notification-service' 'VAPID_SUBJECT'; if (-not $v) { $v = Read-Plain 'VAPID 연락처(mailto:주소)' "mailto:admin@$Domain" }
    Set-Config 'notification-service/VAPID_SUBJECT' $v
}

# ---------- 결과(이름만) ----------
Write-Host ''
Write-Host "추가 $($script:Added.Count)개, 변경 $($script:Updated.Count)개$(if ($DryRun) { ' (DryRun: 실제로 저장하지 않음)' })"
$script:Added | ForEach-Object { Write-Host "  + $_" }
$script:Updated | ForEach-Object { Write-Host "  ~ $_" }
if ($script:Missing.Count -gt 0) {
    Write-Host '비어 있어 건너뛴 값(나중에 다시 실행해 채웁니다):'
    $script:Missing | ForEach-Object { Write-Host "  - $_" }
}
Write-Host ''
Write-Host "Grafana 관리자 비밀번호 확인: aws ssm get-parameter --name $ParameterPath/monitoring/GRAFANA_PASSWORD --with-decryption --query Parameter.Value --output text"
