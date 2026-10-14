#!/usr/bin/env bash
# install-hooks.sh —— 安装防御纵深 hook（hooks 不进版本控制，需此脚本显式安装）
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
HOOK="$AGORA_HOME/.git/hooks/pre-commit"
cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
# 铁律防御纵深：非机械层进程 MUST NOT 提交 log/ 变更
# 机械层提交时携带 AGORA_MECHANICAL=1（post.sh 在持锁段内 export）
if git diff --cached --name-only | grep -q '^log/'; then
  if [[ "${AGORA_MECHANICAL:-}" != "1" ]]; then
    echo "拒绝：log/ 只能由 post.sh 写入（机械层）。如需发帖请用 agora_post。" >&2
    exit 1
  fi
fi
EOF
chmod +x "$HOOK"   # git 只执行有执行位的 hook
echo "installed: $HOOK"
echo "注意：机械层脚本需在 git commit 前 export AGORA_MECHANICAL=1"
