#!/usr/bin/env bash
# dispatch.sh —— 跨项目派生一次性工作会话（规格 §4.7，四保险丝全在机械层）
# 用法: dispatch.sh --actor NAME@PROJ --project DIR --task gt-xxxx [--prompt "..."]
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
MAX_DEPTH="${AGORA_MAX_DEPTH:-3}"; MAX_SPAWN="${AGORA_MAX_SPAWN:-3}"
RUNTIME="${AGORA_RUNTIME:-opencode}"

ACTOR=""; PDIR=""; TASK=""; PROMPT=""; DTASK=""
while [[ $# -gt 0 ]]; do case "$1" in
  --actor) ACTOR="$2";; --project) PDIR="$2";; --task) TASK="$2";; --prompt) PROMPT="$2";; --dispatcher-task) DTASK="$2";;
  *) echo '{"code":"VALIDATION_FAILED","message":"unknown arg"}' >&2; exit 2;;
esac; shift 2; done
fail() { python3 -c 'import json,sys; print(json.dumps({"code":sys.argv[1],"message":sys.argv[2]}, ensure_ascii=False), file=sys.stderr)' "$1" "$2"; exit "${3:-2}"; }   # $POUT 等嵌值含引号亦合法（评审 MINOR：错误通道 JSON）

NAME="${ACTOR%%@*}"
ENTITY="$AGORA_HOME/wiki/entities/$NAME.md"
[[ -f "$ENTITY" ]] || fail NOT_REGISTERED "caller not in roster: $NAME"

# 注入防御：TASK/DTASK 是外部输入（可能来自他机邮件摘要），进 bash -c 前强制格式
[[ "$TASK" =~ ^gt-[0-9a-f]{4,}$ ]] || fail VALIDATION_FAILED "bad task id: $TASK" 2
[[ -z "$DTASK" || "$DTASK" =~ ^gt-[0-9a-f]{4,}$ ]] || fail VALIDATION_FAILED "bad dispatcher task id: $DTASK" 2

# 保险丝 1：权限（身份页 can_spawn: true）
grep -qE '^can_spawn:[[:space:]]*true' "$ENTITY" || fail SPAWN_FORBIDDEN "$NAME lacks can_spawn" 6

# 保险丝 2/3：深度与配额——env 与账本推导取更大值（v1.32 账本化：L2/API 模式无 env 通道时账本为唯一来源）
# 账本口径：深度=dispatched 事件 dispatcher_task 链逐跳计数（任务最新 dispatched 为准，环检测兜底）；
#          配额活跃=dispatched 集 ∩ 无终态事件（done/merged/cancelled 任一即出集）
LEDGER_NEXT=1; LEDGER_ACTIVE=0
if read -r LN LA <<<"$(python3 - "$AGORA_HOME" "${DTASK:-}" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; dtask = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""
disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md")):
    try: lines = open(f, encoding="utf-8").read().splitlines()
    except OSError: continue
    for line in lines:
        if "event:" not in line: continue
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line:
            d = re.search(r"dispatcher_task:(gt-[0-9a-f]{4,})", line)
            disp[t] = d.group(1) if d else ""   # 文件序+行序扫描，后见覆盖=最新派发
        elif any(f"event:{e}" in line for e in ("done", "merged", "cancelled")):
            terminal.add(t)
def depth(t, seen):
    if t not in disp or t in seen: return 0
    d = disp[t]
    return 1 if not d else 1 + depth(d, seen | {t})
nxt = depth(dtask, frozenset()) + 1 if dtask in disp else 1
print(nxt, sum(1 for t in disp if t not in terminal))
PYEOF
)"; then [ -n "$LN" ] && LEDGER_NEXT=$LN; [ -n "$LA" ] && LEDGER_ACTIVE=$LA; fi
DEPTH="${AGORA_DEPTH:-0}"; NEXT=$((DEPTH+1))
(( NEXT < LEDGER_NEXT )) && NEXT=$LEDGER_NEXT
[[ $NEXT -ge $MAX_DEPTH ]] && fail DEPTH_EXCEEDED "depth $NEXT >= max $MAX_DEPTH" 7

LIVE=$(find "$AGORA_HOME/raw/dispatches" -name '*.live' 2>/dev/null | wc -l)
ACTIVE=$LIVE; (( ACTIVE < LEDGER_ACTIVE )) && ACTIVE=$LEDGER_ACTIVE
[[ $ACTIVE -ge $MAX_SPAWN ]] && fail QUOTA_EXCEEDED "active dispatches $ACTIVE >= max $MAX_SPAWN" 8

# 子会话身份：名册目录前缀匹配（最深优先）；worktree 路径归一主 repo（口径在 agora_lib.resolve_entity，gt-ac14）
R=$(PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - "$AGORA_HOME" "$PDIR" <<'PYEOF'
import sys
import agora_lib as lib
home, path = sys.argv[1], sys.argv[2]
r = lib.resolve_entity(home, path)
print(f"{r[0]}\n{r[1]}\n{r[2]}" if r else "")
PYEOF
)
CHILD=$(sed -n 1p <<<"$R"); PROOT=$(sed -n 3p <<<"$R")
[[ -z "$CHILD" || -z "$PROOT" ]] && fail NOT_REGISTERED "no roster entry for $PDIR" 9

# 保险丝 4：落账（dispatched 事件）——数组拼参＋条件追加 dispatcher_task（链深度登记面）
DID="d-$(date +%s%N | sha1sum | cut -c1-8)"
LOG="raw/dispatches/$DID.log"

# 在场优先：目标项目已有活会话 → 只通知不派生
# sessions.map 按机器隔离（格式：<host> <agent> <session> <ts>）——他机的活会话
# 无法被本机通知桥触达，不算"在场"；跨机派活走 task_create + mention 异步路径
PROJNAME=$(basename "$PROOT")
if grep -q "^$(hostname) $CHILD " "$AGORA_HOME/scripts/sessions.map" 2>/dev/null; then
  bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PROJNAME" --event ack \
    --body "dispatch $TASK notified via bridge" --mention "$CHILD" >/dev/null
  echo "{\"dispatch_id\":\"$DID\",\"mode\":\"notified\",\"child_actor\":\"$CHILD@$PROJNAME\"}"
  exit 0
fi

BOOT="你是广场派生的一次性工作会话。按开场仪式查收信、看看板；你的任务是 $TASK（读 wiki/tasks/$TASK.md，按 verify 要求验收）。动手实施前先 agora_post(event=plan, task=$TASK) 落实施计划——dispatcher ack（mention 你）后再动工；等待超 30min 无 ack 可自行放行并在 plan 评论注明。每完成一个里程碑（阶段完成/关键决策/受阻）agora_post(event=progress, task=$TASK) 刷新看板。完成后 agora_post(event=done) 并结束。${PROMPT:+ 补充指示：$PROMPT}"
# 注入防御：PROMPT/PDIR 均不可信（PROMPT 可能来自他机邮件摘要）。一律走 env 传数据 +
# 单引号脚本，bash -c 体内不出现任何外部插值
touch "$AGORA_HOME/$LOG.live"
# --auto：无人值守权限放行（未显式 deny 即放行）；子会话 cwd 由 cd 提供（--dir 随 opencode 2.0.32 移除，2026-10-20 实证 exit 1）；AGORA_RUNTIME 覆写为非 opencode 时旗标兼容性自担
setsid env AGORA_DEPTH=$NEXT AGORA_HOME="$AGORA_HOME" AGORA_RUNTIME="$RUNTIME" \
  AGORA_BOOT="$BOOT" AGORA_PDIR="$PDIR" AGORA_LIVEF="$AGORA_HOME/$LOG.live" \
  bash -c 'cd "$AGORA_PDIR" && "$AGORA_RUNTIME" run --auto "$AGORA_BOOT" ; rm -f "$AGORA_LIVEF"' \
  >"$AGORA_HOME/$LOG" 2>&1 < /dev/null &

PARGS=(--actor "$ACTOR" --project "$PROJNAME" --event dispatched --task "$TASK" --target "$PDIR" --child "$CHILD" --run "$LOG")
[[ -n "$DTASK" ]] && PARGS+=(--dispatcher-task "$DTASK")
POUT=$(bash "$AGORA_HOME/scripts/post.sh" "${PARGS[@]}" 2>&1) \
  || { printf '%s\n' "$POUT" >&2; fail LEDGER_FAILED "dispatched 落账失败（详情见 stderr 上一行）" 4; }
DEDUP=$(echo "$POUT" | sed -n 's/.*"dedup":\(true\|false\).*/\1/p')
case "$DEDUP" in true|false) ;; *) fail LEDGER_FAILED "post.sh 输出异常（无 dedup 键）: $POUT" 4;; esac

echo "{\"dispatch_id\":\"$DID\",\"mode\":\"spawned\",\"child_actor\":\"$CHILD@$PROJNAME\",\"run\":\"$LOG\",\"dedup\":${DEDUP:-false}}"
