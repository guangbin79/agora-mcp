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
LEDGER_NEXT=1; LEDGER_ACTIVE=0; LDT=""
if read -r LN LA LDT <<<"$(python3 - "$AGORA_HOME" "${DTASK:-}" "$ACTOR" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; dtask = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""
actor = sys.argv[3] if len(sys.argv) > 3 else ""
disp, terminal, last_alive, claimed = {}, set(), {}, {}
for f in sorted((glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md"))):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError: continue
    for line in lines:
        if "event:" not in line: continue
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line:
            d = re.search(r"dispatcher_task:(gt-[0-9a-f]{4,})", line)
            disp[t] = d.group(1) if d else ""   # 文件序+行序扫描，后见覆盖=最新派发
            last_alive[t] = True
        elif "event:claimed" in line:
            am = re.search(r'\| actor:(\S+)', line)
            claimed[t] = am.group(1) if am else ""
            last_alive[t] = True
        elif any(f"event:{e}" in line for e in ("done", "merged", "cancelled")):
            terminal.add(t); claimed.pop(t, None)
        elif "event:diagnosed" in line:
            last_alive[t] = False   # 子会话已死（秒死/stale）——配额出集，占位释放
        elif "event:progress" in line or "event:plan" in line:
            last_alive[t] = True
def depth(t, seen):
    if t not in disp or t in seen: return 0
    d = disp[t]
    return 1 if not d else 1 + depth(d, seen | {t})
# dispatcher_task 机械推导（终审 A-W1）：未显式传入时取本 actor 最近 claimed 且无终态的任务
if not dtask and actor:
    cands = [t for t, a in claimed.items() if a == actor]
    if cands: dtask = cands[-1]
nxt = depth(dtask, frozenset()) + 1 if dtask in disp else 1
# 配额活跃＝dispatched ∩ 无终态 ∩ 非僵尸（last_alive=False＝已死出集；真活由 .live 计数兜底取 max）
active = sum(1 for t in disp if t not in terminal and last_alive.get(t, True))
print(nxt, active, dtask)
PYEOF
)"; then [ -n "$LN" ] && LEDGER_NEXT=$LN; [ -n "$LA" ] && LEDGER_ACTIVE=$LA; fi
# 推导回填（A-W1）：显式传入优先，机械推导兜底——两者都进 dispatched 落账
[ -z "$DTASK" ] && [ -n "${LDT:-}" ] && [ "$LDT" != "None" ] && DTASK="$LDT"
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

PROJNAME=$(basename "$PROOT")

# L2 API 通道门（设计 §三）：默认开；RUNTIME=opencode 且适配器在场且 health 通才启用（stub/替代 runtime 零扰动）
RT="$AGORA_HOME/scripts/runtime/opencode.sh"
API=0
if [ "$RUNTIME" = "opencode" ] && [ "${AGORA_RUNTIME_API:-1}" != "0" ] && [ -f "$RT" ]; then
  timeout "${AGORA_API_TIMEOUT:-15}" bash "$RT" health >/dev/null 2>&1 && API=1
fi

# 任务页 wt 感知：wt_dir 在场 → 凭据预写/树重建预检/免在场优先（设计 §四/§五/§六）
PAGE="$AGORA_HOME/wiki/tasks/$TASK.md"
WT_DIR=""
[ -f "$PAGE" ] && WT_DIR=$(sed -n 's/^wt_dir:[[:space:]]*//p' "$PAGE" | head -1)
WT_MAIN=""
if [ -n "$WT_DIR" ]; then
  WT_MAIN=$(PYTHONPATH="$AGORA_HOME/scripts" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "$(realpath "$PDIR")")
fi

# 预检（落账前，失败零账本残留；SPAWN_PRECHECK 同步可见——失败必须响）
"$RUNTIME" --version >/dev/null 2>&1 || fail SPAWN_PRECHECK "runtime 不可用: $RUNTIME" 9
[ -d "$PDIR" ] || fail SPAWN_PRECHECK "project_dir 不存在: $PDIR" 9
if [ -n "$WT_DIR" ]; then
  [ -e "$WT_MAIN/.git" ] || fail SPAWN_PRECHECK "wt 主仓不可用: $WT_MAIN" 9
  if [ ! -d "$WT_DIR" ]; then
    # 锚点重建（FMEA D2）：分支在→直挂既有分支；分支已删→默认分支重建分支
    # （S1：基点=init.defaultBranch/main/master 序探，不用主仓当前 HEAD——主仓停他支时防漂移）。
    # prune 先行：目录被 rm 后 .git/worktrees 注册残留会让 add 拒绝同路径重建
    git -C "$WT_MAIN" worktree prune
    if git -C "$WT_MAIN" show-ref --verify --quiet "refs/heads/wt/$TASK"; then
      git -C "$WT_MAIN" worktree add -q "$WT_DIR" "wt/$TASK" \
        || fail SPAWN_PRECHECK "树重建失败（挂既有分支）: $WT_DIR" 9
    else
      DEFBR=""
      for _c in "$(git -C "$WT_MAIN" config --get init.defaultBranch 2>/dev/null)" main master; do
        [ -n "$_c" ] && git -C "$WT_MAIN" show-ref --verify --quiet "refs/heads/$_c" && { DEFBR="$_c"; break; }
      done
      [ -n "$DEFBR" ] || fail SPAWN_PRECHECK "默认分支不可解析（init.defaultBranch/main/master 均缺）" 9
      git -C "$WT_MAIN" worktree add -q -b "wt/$TASK" "$WT_DIR" "$DEFBR" \
        || fail SPAWN_PRECHECK "树重建失败（默认分支基点 $DEFBR）: $WT_DIR" 9
    fi
  fi
  # setup 钩子（设计 §五环境完备）：项目页 setup: 命令在树内先跑（装环境；预检段执行＝失败零落账）
  SETUPCMD=""
  for pf in "$AGORA_HOME"/wiki/projects/*.md; do
    [ -f "$pf" ] || continue
    _pp=$(sed -n 's/^path:[[:space:]]*//p' "$pf" | head -1)
    [ -z "$_pp" ] && continue
    [ "$(realpath "$_pp" 2>/dev/null)" = "$WT_MAIN" ] && { SETUPCMD=$(sed -n 's/^setup:[[:space:]]*//p' "$pf" | head -1); break; }
  done
  if [ -n "$SETUPCMD" ]; then
    (cd "$WT_DIR" && timeout "${AGORA_SETUP_TIMEOUT:-600}" bash -c "$SETUPCMD") >/dev/null 2>&1 \
      || fail SETUP_FAILED "项目页 setup: 在树内失败（cmd: $SETUPCMD；装环境未完成不派生）" 9
  fi
fi

# 在场优先：目标项目已有活会话 → 只通知不派生（wt 任务豁免——在场会话无树凭据，notified 必死）
# L2：alive API 优先（按目录比 location.directory），sessions.map 降回退（run 通道口径不变）
# sessions.map 按机器隔离（格式：<host> <agent> <session> <ts>）——他机的活会话
# 无法被本机通知桥触达，不算"在场"；跨机派活走 task_create + mention 异步路径
if [ -z "$WT_DIR" ]; then
  _PRESENT=0
  if [ "$API" = 1 ] && timeout "${AGORA_API_TIMEOUT:-15}" bash "$RT" alive "$PDIR" >/dev/null 2>&1; then
    _PRESENT=1
  elif grep -q "^$(hostname) $CHILD " "$AGORA_HOME/scripts/sessions.map" 2>/dev/null; then
    _PRESENT=1
  fi
  if [ "$_PRESENT" = 1 ]; then
  bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PROJNAME" --event ack \
    --body "dispatch $TASK notified via bridge" --mention "$CHILD" >/dev/null
  echo "{\"dispatch_id\":\"$DID\",\"mode\":\"notified\",\"child_actor\":\"$CHILD@$PROJNAME\"}"
  exit 0
  fi
fi

BOOT="你是广场派生的一次性工作会话。按开场仪式查收信、看看板；你的任务是 $TASK（读 wiki/tasks/$TASK.md，按 verify 要求验收）。若任务页有 wt_dir：你在该专用树内开发——新鲜树缺 node_modules/venv 等环境，先装环境再验收（项目页 setup: 已由 dispatch 预跑）。动手实施前先 agora_post(event=plan, task=$TASK) 落实施计划——dispatcher ack（mention 你）后再动工；等待超 30min 无 ack 可自行放行并在 plan 评论注明。每完成一个里程碑 agora_post(event=progress, task=$TASK) 刷新看板。你不自己合并——done 即止（树上 commit＋自验），合并由 dispatcher 走 merge.sh；需改第三仓照常 task_create＋dispatch 下钻（受深度/配额约束）；等待下级时 post progress 后退出，由 poll 恢复性重派唤醒。若你是恢复性重派：先 agora_history(task=$TASK) 自查进度、git status/log 查半成品，接着做。合并阶段 non-ff 冲突：先在原树 rebase 到合并目标分支，重走 verify 再试。完成后 agora_post(event=done) 并结束。${PROMPT:+ 补充指示：$PROMPT}"
# 注入防御：PROMPT/PDIR 均不可信（PROMPT 可能来自他机邮件摘要）。一律走 env 传数据 +
# 单引号脚本，bash -c 体内不出现任何外部插值

# 补偿落账顺序：dispatched 先行（LEDGER_FAILED → 零 spawn，无孤儿会话；孤儿 dispatched 由 poll 档兜底）
# L2 两段化（D1）：create 惰性（无 prompt）先行 → dispatched(session:) 落账 → inject 投 boot——
# 保 LEDGER_FAILED→零工作不变量；create/health 失败发生在落账前 → API=0 回落 run（账本与纯 run 一致，零残留）
SID=""
if [ "$API" = 1 ]; then
  SID=$(timeout 20 bash "$RT" create "$PDIR" 2>/dev/null) || SID=""
  [ -z "$SID" ] && API=0
fi
PARGS=(--actor "$ACTOR" --project "$PROJNAME" --event dispatched --task "$TASK" --target "$PDIR" --child "$CHILD" --run "$LOG")
[[ -n "$DTASK" ]] && PARGS+=(--dispatcher-task "$DTASK")
[[ -n "$SID" ]] && PARGS+=(--session "$SID")
POUT=$(bash "$AGORA_HOME/scripts/post.sh" "${PARGS[@]}" 2>&1) \
  || { printf '%s\n' "$POUT" >&2; fail LEDGER_FAILED "dispatched 落账失败（详情见 stderr 上一行）" 4; }
DEDUP=$(echo "$POUT" | sed -n 's/.*"dedup":\(true\|false\).*/\1/p')
case "$DEDUP" in true|false) ;; *) fail LEDGER_FAILED "post.sh 输出异常（无 dedup 键）: $POUT" 4;; esac

# 凭据预写（幂等重写）＋ spawn ＋ 验证窗 ＋ 有界重试（一次）
# --auto：无人值守权限放行（未显式 deny 即放行）；子会话 cwd 由 cd 提供（--dir 随 opencode 2.0.32 移除，2026-10-20 实证 exit 1）；AGORA_RUNTIME 覆写为非 opencode 时旗标兼容性自担
# 验证窗口径：本尝试的 EXIT:<try>=<rc> 行——0=过、非零=秒死、窗口尽仍活=过（长任务）
spawn_attempt() {
  local _try="$1" _rc="" _w
  if [ -n "$WT_DIR" ]; then
    mkdir -p "$WT_DIR/.omo/agora-delegation"
    printf 'gt: %s\nworktree: %s\ndispatched: %s\n' "$TASK" "$(realpath "$WT_DIR")" "$(date -Is)" \
      > "$WT_DIR/.omo/agora-delegation/$TASK.md"
  fi
  touch "$AGORA_HOME/$LOG.live"
  setsid env AGORA_DEPTH=$NEXT AGORA_HOME="$AGORA_HOME" AGORA_RUNTIME="$RUNTIME" \
    AGORA_BOOT="$BOOT" AGORA_PDIR="$PDIR" AGORA_LIVEF="$AGORA_HOME/$LOG.live" \
    AGORA_LOGF="$AGORA_HOME/$LOG" AGORA_TRY="$_try" \
    bash -c 'cd "$AGORA_PDIR" && "$AGORA_RUNTIME" run --auto "$AGORA_BOOT"; rc=$?; echo "EXIT:$AGORA_TRY=$rc" >> "$AGORA_LOGF"; rm -f "$AGORA_LIVEF"' \
    >>"$AGORA_HOME/$LOG" 2>&1 < /dev/null &
  for _w in $(seq 1 "${AGORA_VERIFY_WIN:-10}"); do
    _rc=$(sed -n "s/^EXIT:$_try=//p" "$AGORA_HOME/$LOG" 2>/dev/null | tail -1)
    [ -n "$_rc" ] && { [ "$_rc" = "0" ] && return 0 || return 1; }
    sleep 1
  done
  return 0
}
spawn_died_diag() {   # 秒死→日志尾落 diagnosed（失败必须响；重试间幂等窗天然去重同文落账）
  bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PROJNAME" --event diagnosed \
    --task "$TASK" --conclusion "$(tail -n 5 "$AGORA_HOME/$LOG" | tr '\n' ' ' | tr -d '|')" >/dev/null 2>&1 || true
}
api_alive_wait() {  # D7 验证窗：轮询 idle——dead=秒死；idle=过；窗口尽仍 running=过（与 run「窗口尽仍活=过」同口径）
  local _try="$1" _w _st
  for _w in $(seq 1 "${AGORA_VERIFY_WIN:-10}"); do
    _st=$(timeout "${AGORA_API_TIMEOUT:-15}" bash "$RT" status "$SID" 2>/dev/null || echo dead)
    case "$_st" in
      idle) echo "ALIVE:$_try=idle" >> "$AGORA_HOME/$LOG"; return 0 ;;
      dead) echo "ALIVE:$_try=dead" >> "$AGORA_HOME/$LOG"; return 1 ;;
    esac
    sleep 1
  done
  echo "ALIVE:$_try=running" >> "$AGORA_HOME/$LOG"; return 0
}
api_spawn_attempt() {  # D2：log/.live/凭据与 run 通道对称（poll 孤儿判据与配额计数不破）
  local _try="$1" _rc
  if [ -n "$WT_DIR" ]; then
    mkdir -p "$WT_DIR/.omo/agora-delegation"
    printf 'gt: %s\nworktree: %s\ndispatched: %s\n' "$TASK" "$(realpath "$WT_DIR")" "$(date -Is)" \
      > "$WT_DIR/.omo/agora-delegation/$TASK.md"
  fi
  echo "SESSION:$_try=$SID" >> "$AGORA_HOME/$LOG"
  touch "$AGORA_HOME/$LOG.live"
  if ! timeout 30 bash "$RT" inject "$SID" "$BOOT" 2>>"$AGORA_HOME/$LOG"; then
    echo "INJECT:$_try=fail" >> "$AGORA_HOME/$LOG"; rm -f "$AGORA_HOME/$LOG.live"; return 1
  fi
  api_alive_wait "$_try"; _rc=$?
  rm -f "$AGORA_HOME/$LOG.live"
  return $_rc
}
if [ "$API" = 1 ]; then
  if ! api_spawn_attempt 1; then
    spawn_died_diag
    if ! api_spawn_attempt 2; then
      spawn_died_diag
      # D3：落账后 API 两连败 → run 通道兜底（dispatched 已落账不重发；session: 指向死 sid 为已知极限，diagnosed 已响）
      if ! spawn_attempt 1; then
        spawn_died_diag
        if ! spawn_attempt 2; then
          spawn_died_diag
          fail SPAWN_DIED "子会话 API+run 四连秒死（run log: $LOG；diagnosed 已落账）" 9
        fi
      fi
    fi
  fi
  echo "{\"dispatch_id\":\"$DID\",\"mode\":\"spawned\",\"channel\":\"api\",\"session\":\"$SID\",\"child_actor\":\"$CHILD@$PROJNAME\",\"run\":\"$LOG\",\"dedup\":${DEDUP:-false}}"
  exit 0
fi
if ! spawn_attempt 1; then
  spawn_died_diag
  if ! spawn_attempt 2; then
    spawn_died_diag
    fail SPAWN_DIED "子会话两连秒死（run log: $LOG；diagnosed 已落账）" 9
  fi
fi

echo "{\"dispatch_id\":\"$DID\",\"mode\":\"spawned\",\"child_actor\":\"$CHILD@$PROJNAME\",\"run\":\"$LOG\",\"dedup\":${DEDUP:-false}}"
