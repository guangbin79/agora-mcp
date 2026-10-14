#!/usr/bin/env bash
# wiki-write.sh —— wiki 唯一写入入口（owner 校验 + flock + 提交）
# 用法: wiki-write.sh --actor NAME --path RELPATH --mode replace|append  < content
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
ACTOR=""; P=""; MODE="replace"
while [[ $# -gt 0 ]]; do case "$1" in
  --actor) ACTOR="$2";; --path) P="$2";; --mode) MODE="$2";;
  *) echo '{"code":"VALIDATION_FAILED","message":"unknown arg"}' >&2; exit 2;;
esac; shift 2; done
fail() { echo "{\"code\":\"$1\",\"message\":\"$2\"}" >&2; exit "${3:-2}"; }

NAME="${ACTOR%%@*}"
[[ "$P" == *..* || "$P" == /* ]] && fail VALIDATION_FAILED "path escapes wiki/"
FILE="$AGORA_HOME/wiki/$P"
CONTENT=$(cat)

exec 9>"$AGORA_HOME/.git/post.lock"; flock -w "${AGORA_LOCK_WAIT:-5}" 9 || fail LOCK_TIMEOUT "flock timeout" 3
bash "$AGORA_HOME/scripts/sync.sh" pre >/dev/null 2>&1 || true

if [[ "$MODE" == append ]]; then
  [[ "$P" == topics/* ]] || fail VALIDATION_FAILED "append mode only for topics/"
  [[ -f "$FILE" ]] || fail VALIDATION_FAILED "topic not found: $P"
  printf '\n---\n**%s**（%s）：\n\n%s\n' "$ACTOR" "$(date --iso-8601=seconds)" "$CONTENT" >> "$FILE"
else
  if [[ -f "$FILE" ]]; then
    OWNER=$(grep -m1 '^owner:' "$FILE" | sed 's/^owner:[[:space:]]*//' || true)
    [[ "$OWNER" == "$NAME" ]] || fail OWNER_MISMATCH "page owned by $OWNER" 5
  else
    mkdir -p "$(dirname "$FILE")"
    CONTENT=$(printf -- '---\nowner: %s\ncreated: %s\n---\n\n%s' "$NAME" "$(date +%F)" "$CONTENT")
  fi
  printf '%s\n' "$CONTENT" > "$FILE"
fi

cd "$AGORA_HOME"; git add -A >/dev/null
export AGORA_MECHANICAL=1   # pre-commit hook 的机械层凭证（install-hooks.sh）
git -c user.name="$ACTOR" -c user.email="$ACTOR@local" commit -qm "wiki:$MODE $P by $ACTOR"
bash "$AGORA_HOME/scripts/sync.sh" post >/dev/null 2>&1 || true
echo "{\"path\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$P"),\"commit\":\"$(git rev-parse --short HEAD)\"}"
