#!/usr/bin/env bash
# redispatch.sh —— 一键回池重派（C一期 gt-b5e9）：escalated/done-unmerged → reopened＋dispatch 合一。
# prompt 不注入补充文案＝dispatch.sh 标准 BOOT（任务页 title/verify 由子会话读页获得）。
# task 省略＝自动推导：本 actor 最近可回池任务（尾态 escalated 或 done_open 的已派任务），多活跃回列表。
# 守卫：当前终态 merged/cancelled 拒；在飞（活跃 dispatched 未闭合且非 escalated/done-unmanaged 尾态）拒。
# 用法: redispatch.sh --actor NAME@PROJ [--task gt-xxxx]
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 单源自定位：兄弟脚本/库一律本仓 scripts（gt-f6e4）
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
fail() { python3 -c 'import json,sys; print(json.dumps({"code":sys.argv[1],"message":sys.argv[2]}, ensure_ascii=False), file=sys.stderr)' "$1" "$2"; exit "${3:-2}"; }
ACTOR=""; TASK=""
while [[ $# -gt 0 ]]; do case "$1" in
  --actor) ACTOR="$2";; --task) TASK="$2";;
  *) fail VALIDATION_FAILED "unknown arg: $1";;
esac; shift 2; done
[[ -n "$ACTOR" && "$ACTOR" == *@* ]] || fail VALIDATION_FAILED "actor required (NAME@PROJ)"
[[ -z "$TASK" || "$TASK" =~ ^gt-[0-9a-f]{4,}$ ]] || fail VALIDATION_FAILED "bad task id: $TASK" 2
PROJECT="${ACTOR##*@}"

EVAL=$(python3 - "$AGORA_HOME" "$ACTOR" "$TASK" <<'PYEOF'
import glob, re, sys, json
home, actor, task = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
rows_by, mine = {}, set()
for f in sorted((glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md"))):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError: continue
    for line in lines:
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        em = re.search(r"event:([a-z_]+)", line)
        ts = re.search(r"ts:(\S+)", line)
        if not em or not ts: continue
        t = m.group(1)
        rows_by.setdefault(t, []).append((ts.group(1), em.group(1)))
        if em.group(1) == "dispatched":
            am = re.search(r"\| actor:(\S+)", line)
            if am and am.group(1) == actor: mine.add(t)
states = {}
for t, rows in rows_by.items():
    rows.sort(key=lambda r: r[0])   # ts 序稳定排序（平局保文件序＝因果序，poll.sh scan_tasks 同款；元组全排会被 ev 字典序重排）
    term, done_open, inflight = None, False, False
    for _ts, ev in rows:
        if ev == "done": done_open = True          # done 未闭：merged/cancelled/reopened 才清
        elif ev in ("merged", "cancelled", "reopened"): done_open = False
        if ev in ("merged", "cancelled"): term = ev
        if ev == "reopened": term = None; inflight = False   # 返工清终态、清在飞
        elif ev == "dispatched": inflight = True
        elif ev in ("merged", "cancelled"): inflight = False
    states[t] = {"last": rows[-1][1] if rows else "", "term": term,
                 "done_open": done_open, "inflight": inflight}
if task:
    st = states.get(task) or {}
    print(json.dumps({"candidates": [task] if st else [], "pick": task if st else "", "state": st}))
else:
    cands = [t for t in mine if t in states and
             (states[t]["last"] == "escalated" or states[t]["done_open"])]
    pick = cands[-1] if cands else ""   # 文件序尾＝最近派发
    print(json.dumps({"candidates": cands, "pick": pick, "state": states.get(pick, {})}))
PYEOF
) || fail INTERNAL "账本重放失败" 4
PICK=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pick"])' <<<"$EVAL")
[[ -z "$PICK" ]] && fail REDISPATCH_NO_TARGET "无可回池任务（本 actor 无尾态 escalated/done-unmerged 的已派任务）" 4
TASK="$PICK"
S=$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["state"]))' <<<"$EVAL")
J() { python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]) or '')" "$S" "$1"; }
ST_LAST=$(J last); ST_TERM=$(J term)
ST_OPEN=$(python3 -c "import json,sys; print(1 if json.loads(sys.argv[1]).get('done_open') else 0)" "$S")
ST_INFLIGHT=$(python3 -c "import json,sys; print(1 if json.loads(sys.argv[1]).get('inflight') else 0)" "$S")
[[ -n "$ST_TERM" ]] && fail ALREADY_TERMINAL "task $TASK 当前终态 $ST_TERM（merged/cancelled 不可重派）" 4
if [[ "$ST_LAST" != "escalated" && "$ST_OPEN" != "1" ]]; then
  [[ "$ST_INFLIGHT" == "1" || "$ST_LAST" == "dispatched" ]] \
    && fail ALREADY_INFLIGHT "task $TASK 在飞（活跃 dispatched 未闭合），不重复派发" 4
fi
PAGE="$AGORA_HOME/wiki/tasks/$TASK.md"
[[ -f "$PAGE" ]] || fail UNKNOWN_TASK "task not found: $TASK" 5
PDIR=$(sed -n 's/^project_dir:[[:space:]]*//p' "$PAGE" | head -1)
[[ -z "$PDIR" ]] && fail VALIDATION_FAILED "任务页缺 project_dir，无法定位派发目标" 2
REOPENED=0
if [[ "$ST_LAST" == "escalated" || "$ST_OPEN" == "1" ]]; then
  ORIG="done-unmerged"; [[ "$ST_LAST" == "escalated" ]] && ORIG="escalated"
  bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PROJECT" --event reopened \
    --task "$TASK" --reason "redispatch 回池（原态:$ORIG）" >/dev/null \
    || fail POST_FAILED "reopened 落账失败" 4
  REOPENED=1
fi
OUT=$(bash "$SCRIPTS_DIR/dispatch.sh" --actor "$ACTOR" --project "$PDIR" --task "$TASK") || {
  printf '%s\n' "$OUT" >&2; fail DISPATCH_FAILED "dispatch.sh 失败（详情见 stderr 上一行）" 4; }
DJ=$(echo "$OUT" | tail -1)
python3 - "$TASK" "$REOPENED" "$ST_LAST" "$S" "$DJ" <<'PYEOF'
import json, sys
try: d = json.loads(sys.argv[5])
except Exception: d = {"raw": sys.argv[5][-200:]}
print(json.dumps({"task": sys.argv[1], "reopened": sys.argv[2] == "1",
                  "prev_state": sys.argv[3], "state": json.loads(sys.argv[4]),
                  "dispatch": d}, ensure_ascii=False, separators=(",", ":")))   # 紧凑分隔符：机器面解析契约（post/dispatch 同款）
PYEOF
