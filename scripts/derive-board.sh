#!/usr/bin/env bash
# derive-board.sh —— 推导层：从事件日志重建看板（宣言 §5.3 状态机）
# 确定性、随时可重跑。board/ 是唯一输出，log/ 是唯一输入。
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
cd "$AGORA_HOME"

python3 - <<'PYEOF'
import os, re, glob, collections

HOME = os.environ.get("AGORA_HOME", os.path.expanduser("~/agora"))
LINE_RE = re.compile(r'^- seq:\d+ \| ts:\S+ \| actor:(\S+) \| event:(\w+) \| idem:\S+ \| seen:\S+(.*)$')
KV_RE = re.compile(r'(\w+):((?:[^|]|\|(?!\s*\w+:))*?)(?=\s*\|\s*\w+:|$)')

# 任务全集来自 wiki/tasks（含 deps / parent / title，供 ready 与计划进度计算）
tasks = {}
task_deps = {}
task_parent = {}
task_title = {}
for p in sorted(glob.glob(f"{HOME}/wiki/tasks/*.md")):
    tid = os.path.basename(p)[:-3]
    tasks[tid] = {"state": "todo", "owner": None}
    src = open(p, encoding="utf-8").read()
    dm = re.search(r'^deps:\s*\[([^\]]*)\]', src, re.M)
    task_deps[tid] = [d.strip() for d in dm.group(1).split(",") if d.strip()] if dm else []
    pm = re.search(r'^parent:\s*(\S+)', src, re.M)
    if pm: task_parent[tid] = pm.group(1)
    tm = re.search(r'^title:\s*(.+)', src, re.M)
    task_title[tid] = tm.group(1).strip() if tm else ""

conflicts, stall_notes = [], []
last_progress = {}   # tid -> 最新 progress 摘要（过程信息进看板）
events = []
for f in sorted(glob.glob(f"{HOME}/log/*/*.md")):
    shard = os.path.relpath(f, HOME)
    for i, line in enumerate(open(f, encoding="utf-8"), 1):
        m = LINE_RE.match(line.strip())
        if not m: continue
        actor, event, rest = m.groups()
        fields = dict(KV_RE.findall(rest))
        events.append((shard, i, actor, event, fields))

retired = set()
for shard, i, actor, event, f in events:
    name = actor.split("@")[0]
    if event == "retired":
        retired.add(actor)
        for t in tasks.values():
            if t["owner"] == actor: t.update(state="todo", owner=None)
        continue
    if actor in retired: continue
    tid = f.get("task")
    if event == "claimed" and tid in tasks:
        if tasks[tid]["owner"] is None and tasks[tid]["state"] == "todo":
            tasks[tid].update(state="in-progress", owner=actor)
        elif tasks[tid]["owner"] != actor:
            conflicts.append(f"{tid}: {actor} vs owner {tasks[tid]['owner']} ({shard}:{i})")
    elif event == "done" and tid in tasks and tasks[tid]["owner"] == actor:
        tasks[tid].update(state="done")
    elif event == "cancelled" and tid in tasks:
        # 认领者可取消自己的任务；未认领任务任何人可取消（终态，除非 reopened）
        if tasks[tid]["owner"] in (None, actor) and tasks[tid]["state"] != "done":
            tasks[tid].update(state="cancelled", owner=None)
    elif event == "reopened" and tid in tasks:
        # 任何非 in-progress 状态可重开（done 重开 = 返工；cancelled 重开 = 恢复）
        if tasks[tid]["state"] != "in-progress":
            tasks[tid].update(state="todo", owner=None)
    elif event == "verify_failed" and tid in tasks:
        pass  # 保持 in-progress（宣言 §5.3）
    elif event == "blocked" and tid in tasks and tasks[tid]["owner"] == actor:
        tasks[tid].update(state="blocked")
    elif event == "diagnosed" and tid:
        stall_notes.append(f"{tid}: {f.get('conclusion','')}")
    elif event == "progress" and tid:
        last_progress[tid] = (f.get("body") or "")[:60]

def render(title, items):
    out = [f"<!-- derived: do not edit by hand -->\n# {title}\n"]
    out += [f"- {x}\n" for x in items] or ["- （空）\n"]
    return "".join(out)

cols = collections.defaultdict(list)
for tid in sorted(tasks):
    t = tasks[tid]
    if t["state"] == "in-progress":
        line = f"{tid} — {t['owner']}"
        if tid in last_progress: line += f" — 进展: {last_progress[tid]}"
        cols["in-progress"].append(line)
    elif t["state"] == "blocked": cols["blocked"].append(tid)
    elif t["state"] == "todo":
        unmet = [d for d in task_deps.get(tid, []) if tasks.get(d, {}).get("state") != "done"]
        if unmet: cols["waiting"].append(f"{tid}（等待: {', '.join(unmet)}）")
        else: cols["todo"].append(tid)  # ready = 无未满足依赖（bd ready 等价物）

os.makedirs(f"{HOME}/board", exist_ok=True)

# 计划进度：parent 被引用即成为计划根，统计子任务完成度（cancelled 不计入总数，单列展示）
plan_children = collections.defaultdict(list)
for tid, par in task_parent.items():
    if par in tasks: plan_children[par].append(tid)
plan_lines = []
for par in sorted(plan_children):
    kids = plan_children[par]
    active = [k for k in kids if tasks[k]["state"] != "cancelled"]
    cancelled_n = len(kids) - len(active)
    done_n = sum(1 for k in active if tasks[k]["state"] == "done")
    title = task_title.get(par) or ""
    line = f"- **{par}** {title} — {done_n}/{len(active)} 完成"
    if cancelled_n: line += f"（{cancelled_n} 已取消）"
    plan_lines.append(line)

todo_out = ["<!-- derived: do not edit by hand -->\n# Todo（ready）\n"]
if plan_lines:
    todo_out.append("\n## 计划进度\n\n")
    todo_out += [l + "\n" for l in plan_lines]
    todo_out.append("\n## 任务\n\n")
else:
    todo_out.append("\n")
todo_out += [f"- {x}\n" for x in cols["todo"]] or ["- （空）\n"]
open(f"{HOME}/board/todo.md", "w").write("".join(todo_out))
open(f"{HOME}/board/in-progress.md", "w").write(render("In Progress", cols["in-progress"]))
open(f"{HOME}/board/blocked.md", "w").write(render("Blocked", cols["blocked"]))
open(f"{HOME}/board/waiting.md", "w").write(render("Waiting（依赖未满足）", cols["waiting"]))
if conflicts:
    open(f"{HOME}/board/conflicts.md", "w").write(render("Conflicts (claim_conflict)", conflicts))
PYEOF
