#!/usr/bin/env bash
# cancel.sh —— 任务取消（C一期 gt-b5e9）：cancelled 落账＋树状态附注，树交 poll ④c GC。
# task 省略＝自动推导：当前 actor 最近无终态的已派任务（dispatch.sh:68 active 集口径
# dispatched∩无终态∩非僵尸，非 claimed 口径）；多活跃时 pick 最近并在 candidates 回全列表。
# 当前终态 merged/cancelled 拒（ALREADY_TERMINAL；done-unmerged 允许＝放弃未并产出）。
# C 二期（gt-0a34）--kill：进程面补齐——先 runtime abort（API 会话中断，尽力而为），再按
# 进程组 kill .live 记录的 pgid（kill -- -pgid）；前置 cmdline 校验含任务标识防 pid 复用误杀；
# 终了清 .live（兼容 .pid 旁文件）；kill 结果并入 cancelled body（kill: 键）与 JSON 输出。
# 用法: cancel.sh --actor NAME@PROJ [--task gt-xxxx] [--reason "..."] [--kill]
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 单源自定位：兄弟脚本/库一律本仓 scripts（gt-f6e4）
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——裸调用已禁用（静默错路径教训 gt-ca34）：export AGORA_HOME=$HOME/plaza 后重试，或经 MCP server env 注入}"
RUNTIME="${AGORA_RUNTIME:-opencode}"
fail() { python3 -c 'import json,sys; print(json.dumps({"code":sys.argv[1],"message":sys.argv[2]}, ensure_ascii=False), file=sys.stderr)' "$1" "$2"; exit "${3:-2}"; }
ACTOR=""; TASK=""; REASON=""; KILL=0
while [[ $# -gt 0 ]]; do case "$1" in
  --actor) ACTOR="$2";; --task) TASK="$2";; --reason) REASON="$2";;
  --kill) KILL=1;;   # 单参旗标：禁落尾随 shift 2（越界 rc1）
  *) fail VALIDATION_FAILED "unknown arg: $1";;
esac; if [[ "$1" == "--kill" ]]; then shift 1; else shift 2; fi; done
[[ -n "$ACTOR" && "$ACTOR" == *@* ]] || fail VALIDATION_FAILED "actor required (NAME@PROJ)"
[[ -z "$TASK" || "$TASK" =~ ^gt-[0-9a-f]{4,}$ ]] || fail VALIDATION_FAILED "bad task id: $TASK" 2
PROJECT="${ACTOR##*@}"

# 自动推导（账本重放；口径逐条对齐 dispatch.sh 保险丝 2/3 的 python 块）
EVAL=$(python3 - "$AGORA_HOME" "$ACTOR" "$TASK" <<'PYEOF'
import glob, re, sys, json
home, actor, task = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
from datetime import datetime
def _pts(s):
    try:
        d = datetime.fromisoformat(s)
        return d if d.tzinfo else d.astimezone()
    except Exception:
        return None
disp, terminal, last_alive = {}, set(), {}
disp_ts, runs, sess = {}, {}, {}
scan_i = 0   # gt-6769：全局扫描序＝ts 同秒并列的确定性次键（append-only 后写者更近）
for f in sorted((glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md"))):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError: continue
    for line in lines:
        scan_i += 1
        if "event:" not in line: continue
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line:
            am = re.search(r"\| actor:(\S+)", line)
            if am and am.group(1) == actor: disp[t] = True   # 只认本 actor 派的
            tmz = re.search(r"\| ts:([^|]+)", line)
            if tmz: disp_ts[t] = (tmz.group(1).strip(), scan_i)   # gt-6769：pick 按 (ts, 扫描序) 判「最近」
            last_alive[t] = True
            rm2 = re.search(r"\| run:(\S+)", line)           # C 二期（gt-0a34）：--kill 定位 live/pgid 用
            if rm2: runs[t] = rm2.group(1)
            sm = re.search(r"\| session:(\S+)", line)
            if sm: sess[t] = sm.group(1)
        elif "event:claimed" in line:
            last_alive[t] = True
        elif any(f"event:{e}" in line for e in ("done", "merged", "cancelled")):
            terminal.add(t)
        elif "event:diagnosed" in line:
            last_alive[t] = False   # 尾随 diagnosed＝子会话已死出集（:68 同款；后续 progress/plan 复活）
        elif "event:progress" in line or "event:plan" in line:
            last_alive[t] = True
cands = [t for t in disp if t not in terminal and last_alive.get(t, True)]
if task:
    print(json.dumps({"candidates": [task], "pick": task,
                      "run": runs.get(task, ""), "session": sess.get(task, "")}))
else:
    # gt-6769：pick 按 (ts, 扫描序) 判「最近派发」——文件/set 序在跨 UTC 日期分片分裂时≠时序（F5 三连挂实证）
    pick = max(cands, key=lambda t: ((_pts(disp_ts.get(t, ("",))[0]) or _pts("1970-01-01T00:00:00+00:00")).timestamp(), disp_ts.get(t, ("", 0))[1])) if cands else ""
    print(json.dumps({"candidates": cands, "pick": pick,
                      "run": runs.get(pick, ""), "session": sess.get(pick, "")}))
PYEOF
) || fail INTERNAL "账本重放失败" 4
PICK=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pick"])' <<<"$EVAL")
[[ -z "$PICK" ]] && fail CANCEL_NO_TARGET "该 actor 无「无终态的已派任务」（candidates 空；显式传 --task 可取消任意任务）" 4
TASK="$PICK"

# 当前终态守卫：merged/cancelled（reopened 清除）不可再取消
TERM=$(python3 - "$AGORA_HOME" "$TASK" <<'PYEOF'
import glob, re, sys, json
home, t0 = sys.argv[1], sys.argv[2]
rows = []
for f in sorted((glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md"))):
    try: fh = open(f, encoding="utf-8", errors="replace")
    except OSError: continue
    for line in fh:
        m = re.search(rf"(?:^|[|] )task:({t0})(?:\s|$)", line)   # 左锚防 dispatcher_task:<id> 尾段子串误中（merge.sh:38 边界范式，R1-F3）
        if not m: continue
        em = re.search(r"event:([a-z_]+)", line)
        ts = re.search(r"ts:(\S+)", line)
        if em and ts: rows.append((ts.group(1), em.group(1)))
rows.sort(key=lambda r: r[0])   # ts 序稳定排序（平局保文件序＝因果序；元组全排会被 ev 字典序重排）
term = None
for _ts, ev in rows:
    if ev in ("merged", "cancelled"): term = ev
    elif ev == "reopened": term = None
print(term or "")
PYEOF
) || fail INTERNAL "状态重放失败" 4
[[ -n "$TERM" ]] && fail ALREADY_TERMINAL "task $TASK 当前终态 $TERM，不可再取消（reopened 可回池）" 4

PAGE="$AGORA_HOME/wiki/tasks/$TASK.md"
[[ -f "$PAGE" ]] || fail UNKNOWN_TASK "task not found: $TASK" 5
# 树状态附注（cancelled 事件 body；清树交 poll GC——净树/窄域自动清，业务 dirty 只报告）
WTD=$(sed -n 's/^wt_dir:[[:space:]]*//p' "$PAGE" | head -1)
TSTAT="none"; WINFO=""
if [[ -n "$WTD" ]]; then
  WINFO="wt:$WTD "
  if [[ ! -d "$WTD" ]]; then TSTAT="missing"
  else
    DN=$(git -C "$WTD" status --porcelain -uall 2>/dev/null | grep -c . || true)
    TSTAT="clean"; [[ "${DN:-0}" -gt 0 ]] && TSTAT="dirty:$DN"
  fi
fi
# C 二期（gt-0a34）：--kill 进程面——runtime abort（API 会话中断，尽力而为）＋进程组 kill（cmdline 校验防 pid 复用）
KINFO=""
if [[ "$KILL" == 1 ]]; then
  KRUN=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("run",""))' <<<"$EVAL")
  KSID=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session",""))' <<<"$EVAL")
  if [[ -n "$KSID" && "$KSID" =~ ^[-A-Za-z0-9_]+$ && "$RUNTIME" == opencode && -f "$SCRIPTS_DIR/runtime/opencode.sh" ]]; then
    timeout 5 bash "$SCRIPTS_DIR/runtime/opencode.sh" abort "$KSID" >/dev/null 2>&1 || true
  fi
  LIVEF=""
  [[ -n "$KRUN" ]] && LIVEF="$AGORA_HOME/$KRUN.live"
  if [[ ! "$KRUN" =~ ^raw/dispatches/d-[0-9a-f]+\.log$ ]]; then   # 账本 run: 字段形状闸（防路径穿越 rm，终闸 C1）
    KINFO="kill:no-live"
  elif [[ -z "$LIVEF" || ! -f "$LIVEF" ]]; then
    KINFO="kill:no-live"
  else
    PGID=$(head -1 "$LIVEF" 2>/dev/null | tr -d "[:space:]" || true)   # || true：-f 与 head 之间 .live 被子进程删的竞态（终闸 B1），空值落 bad-pgid
    if [[ ! "$PGID" =~ ^[0-9]+$ ]]; then KINFO="kill:bad-pgid"
    elif [[ ! -d "/proc/$PGID" ]]; then KINFO="kill:dead-pgid"
    elif ! tr '\0' ' ' <"/proc/$PGID/cmdline" 2>/dev/null | grep -q "$TASK"; then
      KINFO="kill:skipped-cmdline-mismatch"   # pid 复用：组长的 cmdline 已非本任务，不杀
    else
      kill -TERM -- -"$PGID" 2>/dev/null || true
      _k=0; while kill -0 -- -"$PGID" 2>/dev/null && (( _k < 10 )); do sleep 0.2; _k=$((_k+1)); done
      kill -0 -- -"$PGID" 2>/dev/null && kill -KILL -- -"$PGID" 2>/dev/null || true
      KINFO="kill:pgid=$PGID"
    fi
    rm -f "$LIVEF" "${KRUN%.log}.pid"
  fi
fi
bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PROJECT" --event cancelled \
  --task "$TASK" --reason "${REASON:-cancel via agora_cancel}" --body "${WINFO}${KINFO:+$KINFO }tree:$TSTAT" >/dev/null \
  || fail POST_FAILED "cancelled 落账失败" 4
python3 - "$TASK" "$TSTAT" "$EVAL" "$KINFO" <<'PYEOF'
import json, sys
print(json.dumps({"task": sys.argv[1], "cancelled": True, "tree": sys.argv[2],
                  "kill": sys.argv[4],
                  "candidates": json.loads(sys.argv[3])["candidates"]},
                 ensure_ascii=False, separators=(",", ":")))   # 紧凑分隔符：机器面 sed/grep 解析契约（post/dispatch 同款）
PYEOF
