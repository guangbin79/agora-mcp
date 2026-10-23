#!/usr/bin/env bash
# cancel.sh —— 任务取消（C一期 gt-b5e9）：cancelled 落账＋树状态附注，树交 poll ④c GC。
# task 省略＝自动推导：当前 actor 最近无终态的已派任务（dispatch.sh:68 active 集口径
# dispatched∩无终态∩非僵尸，非 claimed 口径）；多活跃时 pick 最近并在 candidates 回全列表。
# 当前终态 merged/cancelled 拒（ALREADY_TERMINAL；done-unmerged 允许＝放弃未并产出）。
# 不做任何进程操作（kill 能力归 C 二期）。
# 用法: cancel.sh --actor NAME@PROJ [--task gt-xxxx] [--reason "..."]
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
fail() { python3 -c 'import json,sys; print(json.dumps({"code":sys.argv[1],"message":sys.argv[2]}, ensure_ascii=False), file=sys.stderr)' "$1" "$2"; exit "${3:-2}"; }
ACTOR=""; TASK=""; REASON=""
while [[ $# -gt 0 ]]; do case "$1" in
  --actor) ACTOR="$2";; --task) TASK="$2";; --reason) REASON="$2";;
  *) fail VALIDATION_FAILED "unknown arg: $1";;
esac; shift 2; done
[[ -n "$ACTOR" && "$ACTOR" == *@* ]] || fail VALIDATION_FAILED "actor required (NAME@PROJ)"
[[ -z "$TASK" || "$TASK" =~ ^gt-[0-9a-f]{4,}$ ]] || fail VALIDATION_FAILED "bad task id: $TASK" 2
PROJECT="${ACTOR##*@}"

# 自动推导（账本重放；口径逐条对齐 dispatch.sh 保险丝 2/3 的 python 块）
EVAL=$(python3 - "$AGORA_HOME" "$ACTOR" "$TASK" <<'PYEOF'
import glob, re, sys, json
home, actor, task = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
disp, terminal, last_alive = {}, set(), {}
for f in sorted((glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md"))):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError: continue
    for line in lines:
        if "event:" not in line: continue
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line:
            am = re.search(r"\| actor:(\S+)", line)
            if am and am.group(1) == actor:
                disp.pop(t, None); disp[t] = True   # move-to-tail：插入序＝最近派发序（重派刷新位次，终闸 B 册）
            last_alive[t] = True
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
    print(json.dumps({"candidates": [task], "pick": task}))
else:
    print(json.dumps({"candidates": cands, "pick": cands[-1] if cands else ""}))   # 文件序尾＝最近派发
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
        m = re.search(rf"task:({t0})( |$)", line)
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
bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PROJECT" --event cancelled \
  --task "$TASK" --reason "${REASON:-cancel via agora_cancel}" --body "${WINFO}tree:$TSTAT" >/dev/null \
  || fail POST_FAILED "cancelled 落账失败" 4
python3 - "$TASK" "$TSTAT" "$EVAL" <<'PYEOF'
import json, sys
print(json.dumps({"task": sys.argv[1], "cancelled": True, "tree": sys.argv[2],
                  "candidates": json.loads(sys.argv[3])["candidates"]},
                 ensure_ascii=False, separators=(",", ":")))   # 紧凑分隔符：机器面 sed/grep 解析契约（post/dispatch 同款）
PYEOF
