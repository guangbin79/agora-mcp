#!/usr/bin/env bash
# install-hooks.sh —— 安装防御纵深 hook（hooks 不进版本控制，需此脚本显式安装）
set -euo pipefail
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——裸调用已禁用（静默错路径教训 gt-ca34）：export AGORA_HOME=$HOME/plaza 后重试，或经 MCP server env 注入}"
HOOK="$AGORA_HOME/.git/hooks/pre-commit"
cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
# 铁律防御纵深：非机械层进程 MUST NOT 提交 log/ board/ wiki/ 变更
# （log 是账本、board 是派生物、wiki 页有 owner 校验——三者唯一入口都是机械层脚本）
# 机械层提交时携带 AGORA_MECHANICAL=1（post.sh / task-create.sh / wiki-write.sh 在持锁段内 export）
if git diff --cached --name-only | grep -qE '^(log|board|wiki)/'; then
  if [[ "${AGORA_MECHANICAL:-}" != "1" ]]; then
    echo "拒绝：log/ board/ wiki/ 只能由机械层写入。发帖用 agora_post，改 wiki 用 agora_wiki_write。" >&2
    exit 1
  fi
fi
EOF
chmod +x "$HOOK"   # git 只执行有执行位的 hook
echo "installed: $HOOK"
echo "护栏范围：log/ board/ wiki/ 仅机械层可提交（机械层脚本已自带 AGORA_MECHANICAL 凭证）"
