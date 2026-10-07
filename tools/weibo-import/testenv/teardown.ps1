# 销毁一次性 Mastodon 测试环境：停止并删除全部容器、网络与数据卷（db/redis/media）。
# -RemoveEnv 同时删除本地生成的 .env（密钥随之丢弃）。
param(
  [switch]$RemoveEnv
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

docker compose down -v --remove-orphans
if ($LASTEXITCODE -ne 0) { throw 'docker compose down 失败' }

if ($RemoveEnv) {
  Remove-Item '.env' -Force -ErrorAction SilentlyContinue
  Write-Host '.env 已删除'
}
Write-Host '测试环境已完全清理（容器、网络、db/redis/media 数据卷）'
