#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 侧安装器：把 tools/weibo-import/install 树复制到目标 Mastodon 目录。
    默认 dry-run（只打印将要复制的文件清单），加 -Execute 才真正复制。

.DESCRIPTION
    目标目录优先级：-Destination 参数 > 环境变量 MASTODON_DIR。
    未提供目标目录时退化为“只打印源树清单 + 用法说明”（退出码 0），方便 rake install 预览。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File deploy/install.ps1
    # dry-run：$env:MASTODON_DIR 已设置时预览复制计划

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File deploy/install.ps1 -Destination /srv/mastodon -Execute
    # 真实复制到 /srv/mastodon（通常目标是共享给 Linux 主机的路径或中转目录）
#>
param(
    [string]$Source = (Join-Path $PSScriptRoot '..\tools\weibo-import\install'),
    [string]$Destination = $env:MASTODON_DIR,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Error "源目录不存在: $Source"
    exit 1
}
$srcRoot = (Resolve-Path -LiteralPath $Source).Path

if ([string]::IsNullOrWhiteSpace($Destination)) {
    Write-Host "未指定目标目录（-Destination 或环境变量 MASTODON_DIR）。仅打印源树清单。"
    Write-Host ""
    Write-Host "源树（将被原样复制到 <MASTODON_DIR>/ 下）："
    Get-ChildItem -LiteralPath $srcRoot -Recurse -File | ForEach-Object {
        Write-Host ("  " + $_.FullName.Substring($srcRoot.Length).TrimStart('\', '/'))
    }
    Write-Host ""
    Write-Host "用法: powershell -File deploy/install.ps1 -Destination <MASTODON_DIR> [-Execute]"
    exit 0
}

$destRoot = [System.IO.Path]::GetFullPath($Destination)
$dryRun = -not $Execute

Write-Host ("模式   : " + $(if ($dryRun) { "DRY-RUN（仅预览，不写入）" } else { "EXECUTE（真实复制）" }))
Write-Host ("源     : $srcRoot")
Write-Host ("目标   : $destRoot")
if (-not (Test-Path -LiteralPath $destRoot)) {
    if ($dryRun) {
        Write-Host "注意   : 目标目录当前不存在（dry-run 继续；-Execute 时会报错）"
    } else {
        Write-Error "目标目录不存在: $destRoot"
        exit 1
    }
}

$files = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File)
if ($files.Count -eq 0) { Write-Warning "源树为空，无可复制文件。" }

foreach ($f in $files) {
    $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
    $target = Join-Path $destRoot $rel
    Write-Host ("  {0,-55} -> {1}" -f $rel, $target)
    if (-not $dryRun) {
        $dir = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $target -Force
    }
}

Write-Host ""
Write-Host ("共 {0} 个文件。{1}" -f $files.Count, $(if ($dryRun) { "确认无误后追加 -Execute 才会真正复制。" } else { "复制完成。请到实例侧校验文件为 LF 换行后再执行。" }))
exit 0
