#!/usr/bin/env bash
# dispatch.sh —— 跨项目派生一次性工作会话（规格 §4.7，四保险丝全在机械层）
# 用法: dispatch.sh --actor NAME@PROJ --project DIR --task gt-xxxx [--prompt "..."]
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
MAX_DEPTH="${AGORA_MAX_DEPTH:-2}"; MAX_SPAWN="${AGORA_MAX_SPAWN:-3}"
RUNTIME="${AGORA_RUNTIME:-opencode}"

ACTOR=""; PDIR=""; TASK=""; PROMPT=""
while [[ $# -gt 0 ]]; do case "$1" in
  --actor) ACTOR="$2";; --project) PDIR="$2";; --task) TASK="$2";; --prompt) PROMPT="$2";;
  *) echo '{"code":"VALIDATION_FAILED","message":"unknown arg"}' >&2; exit 2;;
esac; shift 2; done
fail() { echo "{\"code\":\"$1\",\"message\":\"$2\"}" >&2; exit "${3:-2}"; }

NAME="${ACTOR%%@*}"
ENTITY="$AGORA_HOME/wiki/entities/$NAME.md"
[[ -f "$ENTITY" ]] || fail NOT_REGISTERED "caller not in roster: $NAME"

# 保险丝 1：权限（身份页 can_spawn: true）
grep -qE '^can_spawn:[[:space:]]*true' "$ENTITY" || fail SPAWN_FORBIDDEN "$NAME lacks can_spawn" 6

# 保险丝 2：深度（AGORA_DEPTH 由父进程环境传入）
DEPTH="${AGORA_DEPTH:-0}"; NEXT=$((DEPTH+1))
[[ $NEXT -ge $MAX_DEPTH ]] && fail DEPTH_EXCEEDED "depth $NEXT >= max $MAX_DEPTH" 7

# 保险丝 3：配额（.live 标记计数）
LIVE=$(find "$AGORA_HOME/raw/dispatches" -name '*.live' 2>/dev/null | wc -l)
[[ $LIVE -ge $MAX_SPAWN ]] && fail QUOTA_EXCEEDED "live dispatches $LIVE >= max $MAX_SPAWN" 8

# 子会话身份：名册目录前缀匹配（最深优先）
CHILD=$(python3 - "$AGORA_HOME" "$PDIR" <<'PYEOF'
import sys, glob, os, re
home, target = sys.argv[1], os.path.realpath(sys.argv[2])
best = None
for f in glob.glob(f"{home}/wiki/entities/*.md"):
    txt = open(f, encoding="utf-8").read()
    m = re.search(r'^dirs:\s*\n((?:\s+-\s+.+\n)+)', txt, re.M)
    if not m: continue
    for d in re.findall(r'-\s+(\S+)', m.group(1)):
        d = os.path.expanduser(d)
        if (target + "/").startswith(os.path.realpath(d) + "/") or target == os.path.realpath(d):
            if best is None or len(d) > len(best[1]): best = (os.path.basename(f)[:-3], d)
print(best[0] if best else "")
PYEOF
)
[[ -z "$CHILD" ]] && fail NOT_REGISTERED "no roster entry for $PDIR" 9

# 保险丝 4：落账（dispatched 事件）
DID="d-$(date +%s%N | sha1sum | cut -c1-8)"
LOG="raw/dispatches/$DID.log"

# 在场优先：目标项目已有活会话 → 只通知不派生
PROJNAME=$(basename "$PDIR")
if grep -q "^$CHILD " "$AGORA_HOME/scripts/sessions.map" 2>/dev/null; then
  bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PROJNAME" --event ack \
    --body "dispatch $TASK notified via bridge" --mention "$CHILD" >/dev/null
  echo "{\"dispatch_id\":\"$DID\",\"mode\":\"notified\",\"child_actor\":\"$CHILD@$PROJNAME\"}"
  exit 0
fi

BOOT="你是广场派生的一次性工作会话。按开场仪式查收信、看看板；你的任务是 $TASK（读 wiki/tasks/$TASK.md，按 verify 要求验收）。完成后 agora_post(event=done) 并结束。${PROMPT:+ 补充指示：$PROMPT}"
touch "$AGORA_HOME/$LOG.live"
setsid env AGORA_DEPTH=$NEXT AGORA_HOME="$AGORA_HOME" \
  bash -c "cd '$PDIR' && $RUNTIME run \"$BOOT\" ; rm -f '$AGORA_HOME/$LOG.live'" \
  >"$AGORA_HOME/$LOG" 2>&1 < /dev/null &

bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PROJNAME" --event dispatched \
  --task "$TASK" --target "$PDIR" --child "$CHILD" --run "$LOG" >/dev/null

echo "{\"dispatch_id\":\"$DID\",\"mode\":\"spawned\",\"child_actor\":\"$CHILD@$PROJNAME\",\"run\":\"$LOG\"}"
