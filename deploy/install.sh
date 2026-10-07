#!/usr/bin/env bash
# Linux 侧安装器（rsync 等价物）：把 tools/weibo-import/install 树复制到目标 Mastodon 目录。
# 用法:
#   ./install.sh [目标目录] [--execute]
#   MASTODON_DIR=/srv/mastodon ./install.sh            # dry-run 预览
#   MASTODON_DIR=/srv/mastodon ./install.sh "" --execute   # 真复制
# 默认 dry-run（rsync --dry-run），追加 --execute 才真正写入。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${SCRIPT_DIR}/../tools/weibo-import/install" && pwd)"
DEST="${1:-${MASTODON_DIR:-}}"
EXECUTE="${2:-}"

if [ -z "$DEST" ]; then
  echo "错误: 未指定目标目录（第 1 个参数或环境变量 MASTODON_DIR）" >&2
  exit 1
fi

RSYNC_ARGS=(-av --checksum --delete=false)
if [ "$EXECUTE" != "--execute" ]; then
  RSYNC_ARGS+=(--dry-run)
  echo "[dry-run] 仅预览，不写入；追加 --execute 真正复制。"
else
  echo "[execute] 真实复制: $SRC/ -> $DEST/"
fi

exec rsync "${RSYNC_ARGS[@]}" "$SRC/" "$DEST/"
