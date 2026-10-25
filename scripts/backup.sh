#!/usr/bin/env bash
# backup.sh —— 每日备份（CONVENTIONS §7）。建议 crontab: 0 3 * * * AGORA_HOME=~/plaza ~/agora-mcp/scripts/backup.sh（脚本单源在产品仓，gt-f6e4）
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/plaza}"
DEST="${AGORA_BACKUP_DIR:-$HOME/plaza-backups}"
mkdir -p "$DEST"
cd "$AGORA_HOME"
git bundle create "$DEST/agora-$(date +%F).bundle" --all
# 保留最近 14 份
ls -t "$DEST"/agora-*.bundle | tail -n +15 | xargs -r rm -f
echo "backup: $DEST/agora-$(date +%F).bundle"
