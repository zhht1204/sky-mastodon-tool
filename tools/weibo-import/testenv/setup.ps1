# 初始化一次性 Mastodon 4.6.2 测试容器（幂等，可重复运行）。
# 产物：随机密钥 .env、已迁移数据库、本地测试账号、运行中的 web/sidekiq。
# 用完执行 teardown.ps1 销毁全部容器与数据卷。
# 用法：powershell -ExecutionPolicy Bypass -File setup.ps1 [-Account importer]
param(
  [string]$Account = 'importer'
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function New-Hex([int]$Chars) {
  $bytes = [byte[]]::new([int]($Chars / 2))
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

if (-not (Test-Path '.env')) {
  Write-Host '[1/7] 生成 .env（随机密钥，已被 gitignore）'
  $raw = Get-Content '.env.example' -Raw
  $raw = $raw -replace '__DB_PASS__', (New-Hex 32)
  $raw = $raw -replace '__SECRET_KEY_BASE__', (New-Hex 128)
  $raw = $raw -replace '__OTP_SECRET__', (New-Hex 128)
  Set-Content -Path '.env' -Value $raw -NoNewline
} else {
  Write-Host '[1/7] .env 已存在，跳过生成'
}

Write-Host '[2/7] 启动 db / redis ...'
docker compose up -d db redis | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'docker compose up db redis 失败' }

Write-Host '[3/7] 等待 db / redis 健康检查 ...'
$deadline = (Get-Date).AddSeconds(180)
do {
  Start-Sleep -Seconds 3
  $dbId = docker compose ps -q db
  $rdId = docker compose ps -q redis
  $dbState = if ($dbId) { docker inspect --format '{{.State.Health.Status}}' $dbId } else { 'missing' }
  $rdState = if ($rdId) { docker inspect --format '{{.State.Health.Status}}' $rdId } else { 'missing' }
  if ((Get-Date) -gt $deadline) { throw "db/redis 健康检查超时（db=$dbState redis=$rdState）" }
} while ($dbState -ne 'healthy' -or $rdState -ne 'healthy')
Write-Host '      db / redis healthy'

Write-Host '[4/7] rails db:prepare（建库 + 迁移，可能需要数分钟）...'
docker compose run --rm -T web bundle exec rails db:prepare
if ($LASTEXITCODE -ne 0) { throw 'rails db:prepare 失败' }

Write-Host '[5/7] 生成 VAPID 密钥 ...'
$vapid = docker compose run --rm -T web bundle exec rails mastodon:webpush:generate_vapid_key
if ($LASTEXITCODE -eq 0 -and $vapid -match 'VAPID_PRIVATE_KEY=(\S+)') {
  $priv = $Matches[1]
  $pub = if ($vapid -match 'VAPID_PUBLIC_KEY=(\S+)') { $Matches[1] } else { '' }
  $raw = Get-Content '.env' -Raw
  $raw = $raw -replace '__VAPID_PRIVATE_KEY__', $priv
  $raw = $raw -replace '__VAPID_PUBLIC_KEY__', $pub
  Set-Content -Path '.env' -Value $raw -NoNewline
  Write-Host '      VAPID 密钥已写入 .env'
} else {
  Write-Warning 'VAPID 生成失败，保留占位符（通常不影响 Rails 启动，仅影响 Web Push）'
}

Write-Host "[6/7] 创建本地测试账号 $Account ..."
docker compose run --rm -T web bin/tootctl accounts create $Account --email "$Account@weibo-import.test"
if ($LASTEXITCODE -ne 0) { Write-Warning '账号创建失败（如已存在可忽略）' }

Write-Host '[7/7] 启动 web / sidekiq 并等待健康 ...'
docker compose up -d web sidekiq | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'docker compose up web sidekiq 失败' }
$ok = $false
$deadline = (Get-Date).AddSeconds(300)
while (-not $ok) {
  Start-Sleep -Seconds 5
  if ((Get-Date) -gt $deadline) { throw 'web 健康检查超时；用 docker compose logs web 排查' }
  try {
    $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:46500/health' -UseBasicParsing -TimeoutSec 5
    if ($resp.StatusCode -eq 200) { $ok = $true }
  } catch { }
}

Write-Host ''
Write-Host '完成：隔离测试实例已就绪'
Write-Host '  地址:  http://127.0.0.1:46500/health'
Write-Host "  账号:  $Account（本地账号，供 weibo_import.rb --account 使用）"
Write-Host '  清理:  powershell -ExecutionPolicy Bypass -File teardown.ps1   (down -v，销毁全部数据卷)'
