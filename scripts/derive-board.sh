#!/usr/bin/env bash
# derive-board.sh —— 推导层：从事件日志重建看板（宣言 §5.3 状态机）
# 确定性、随时可重跑。board/ 是唯一输出，log/ 是唯一输入。
#
# 增量推导（v1.14）：.git/derive-cache.json 记录每分片水位 {n: 已处理行数, h: 前 n 行 sha1}
# 与重放后的看板状态。再跑时逐分片校验前缀哈希：
#   - 前缀未变 → 只重放追加行（事件正则解析是大头，读+哈希极快）；
#   - 前缀变了（union 合并重排、历史被改）、新分片插入到已缓存分片之前、
#     分片被删、任务页集合变化、缓存损坏 → 自动退回全量重放。
# 缓存是本机文件（.git/ 内），不进同步；任何可疑一律全量，正确性优先于省速。
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/plaza}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # cd 前捕获：scripts 目录内相对调用亦能定位 agora_lib
cd "$AGORA_HOME"
PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import os, re, glob, json, hashlib, collections
import agora_lib as lib   # LINE_RE/KV_RE/parse_event 唯一真源

HOME = os.environ.get("AGORA_HOME", os.path.expanduser("~/plaza"))
CACHE_F = os.path.join(HOME, ".git", "derive-cache.json")

# 任务元数据每次全量重读（deps/parent/title 供渲染；页面集合变化 = 缓存失效条件之一，
# 因为页面缺失期间其事件被状态机跳过，事后补页必须全量重放才能补算）
task_deps, task_parent, task_title = {}, {}, {}
for p in sorted(glob.glob(f"{HOME}/wiki/tasks/*.md")):
    tid = os.path.basename(p)[:-3]
    src = open(p, encoding="utf-8").read()
    dm = re.search(r'^deps:\s*\[([^\]]*)\]', src, re.M)
    task_deps[tid] = [d.strip() for d in dm.group(1).split(",") if d.strip()] if dm else []
    pm = re.search(r'^parent:\s*(\S+)', src, re.M)
    if pm: task_parent[tid] = pm.group(1)
    tm = re.search(r'^title:\s*(.+)', src, re.M)
    task_title[tid] = tm.group(1).strip() if tm else ""
task_ids = sorted(set(task_deps) | set(task_parent) | set(task_title) |
                  {os.path.basename(p)[:-3] for p in glob.glob(f"{HOME}/wiki/tasks/*.md")})

def hash_lines(lines):
    return hashlib.sha1("".join(lines).encode()).hexdigest()

def fresh_state():
    return ({tid: {"state": "todo", "owner": None} for tid in task_ids},
            set(), [], {})   # tasks, retired, conflicts, last_progress

tasks, retired, conflicts, last_progress = fresh_state()
wm, stats = {}, {"incr": 0, "full": 0}

cache = None
try:
    # v5（gt-8fe1 C1）：done 出列权威化（先于 retired 盲化＋owner 放宽 None）——v4 缓存水位下的
    # done 曾被 retired 盲化吞掉，旧缓存必须作废全量重放补账，否则 done 任务 todo 永驻不自愈
    c = json.load(open(CACHE_F))
    if c.get("v") == 5 and c.get("task_ids") == task_ids and isinstance(c.get("watermark"), dict):
        cache = c
except Exception: pass

shards = sorted(os.path.relpath(f, HOME) for f in (glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md")))
need_full = cache is None

if cache:
    wm = cache["watermark"]
    stats = cache.get("stats", stats)
    if set(wm) - set(shards):
        need_full = True                      # 分片被删
    elif wm:
        hi = max(wm)
        if any(rel not in wm and rel <= hi for rel in shards):
            need_full = True                  # 新分片插入已缓存分片之前，权威序被打乱
    if not need_full:
        for tid, st in cache.get("tasks", {}).items():
            if tid in tasks: tasks[tid] = st
        retired = set(cache.get("retired", []))
        conflicts = list(cache.get("conflicts", []))
        last_progress = dict(cache.get("last_progress", {}))

def apply(shard, i, actor, event, f):
    tid = f.get("task")
    if event == "merged" and tid in tasks:
        # gt-5a59：merged＝机械簿记终态（merge.sh 机械票背书，非 actor 的任务主张）——先于 retired 过滤：
        # 已退休 actor 补账的 merged 仍须闭环离板，否则 todo 永驻（实证：retired 盲化令当日 merged 全部失效）。
        # 终态语义见任务页：merged 蕴含工作已落目标分支。含 cancelled→done（机械真值覆盖人工取消；
        # merge.sh 实操链对 cancelled 任务不发 merged，此形态仅手工/raw 落账可达）
        tasks[tid].update(state="done")
        return
    if event == "done" and tid in tasks and tasks[tid]["owner"] in (None, actor):
        # gt-8fe1 C1：done＝出列权威主张（post.sh verify 两段机械真跑背书），先于 retired 盲化——
        # 活跃 actor 发 wave 让行型 retired 被误盲化后（agora-mcp/dotfiles-orch 实证入 retired 集），
        # 其 claimed/done 全遭忽略：claimed 丢→owner 恒 None→done 的 owner==actor 判不过→
        # done 任务永驻 todo（当日 41 条 todo 污染根因）。owner 放宽 None＝未认领任务的 done
        # （收编代发/直发）同判离板，与 cancelled 的 (None, actor) 口径对齐。
        # 只修出列：入列面（claimed 对 retired 的盲化）语义不动。
        tasks[tid].update(state="done")
        return
    if event == "retired":
        retired.add(actor)
        for t in tasks.values():
            # gt-ae6f：done 只能经 reopened/merged/cancelled 离场——retired 把 done 任务
            # 踢回 todo 曾造 gt-bb0b 拾取风暴（视图与 mention 守卫 done_open 口径对齐）
            if t["owner"] == actor and t["state"] != "done": t.update(state="todo", owner=None)
        return
    if actor in retired: return
    if event == "claimed" and tid in tasks:
        if tasks[tid]["owner"] is None and tasks[tid]["state"] == "todo":
            tasks[tid].update(state="in-progress", owner=actor)
        elif tasks[tid]["owner"] != actor:
            conflicts.append(f"{tid}: {actor} vs owner {tasks[tid]['owner']} ({shard}:{i})")
    elif event == "cancelled" and tid in tasks:
        # 认领者可取消自己的任务；未认领任务任何人可取消（终态，除非 reopened）
        if tasks[tid]["owner"] in (None, actor) and tasks[tid]["state"] != "done":
            tasks[tid].update(state="cancelled", owner=None)
    elif event == "reopened" and tid in tasks:
        # 任何非 in-progress 状态可重开（done 重开 = 返工；cancelled 重开 = 恢复）；
        # in-progress 仅 watchdog@* 可重开（CONVENTIONS §4 升级阶梯的自动回池，
        # 宣言 §5.3 v0.19 起）
        if tasks[tid]["state"] != "in-progress" or actor.startswith("watchdog@"):
            tasks[tid].update(state="todo", owner=None)
    elif event == "verify_failed" and tid in tasks:
        pass  # 保持 in-progress（宣言 §5.3）
    elif event == "blocked" and tid in tasks and tasks[tid]["owner"] == actor \
            and tasks[tid]["state"] == "in-progress":
        # gt-40cc：前置守卫对齐 reopened——done/cancelled/todo 不得被迟到的 blocked 拖走
        tasks[tid].update(state="blocked")
    elif event == "progress" and tid:
        last_progress[tid] = (f.get("ts", ""), (f.get("body") or "")[:60])   # (ts, body)：看板显示心跳 age（v1.31）

def replay_lines(shard, start, lines):
    for off, line in enumerate(lines, 1):
        e = lib.parse_event(line)
        if e: apply(shard, start + off, e["actor"], e["event"], e)

if need_full:
    tasks, retired, conflicts, last_progress = fresh_state()
    wm = {}
    for rel in shards:
        lines = open(os.path.join(HOME, rel), encoding="utf-8").read().splitlines(keepends=True)
        replay_lines(rel, 0, lines)
        wm[rel] = {"n": len(lines), "h": hash_lines(lines)}
    stats["full"] += 1
else:
    new_wm = {}
    for rel in shards:
        lines = open(os.path.join(HOME, rel), encoding="utf-8").read().splitlines(keepends=True)
        if rel in wm:
            n, h = wm[rel]["n"], wm[rel]["h"]
            if len(lines) < n or hash_lines(lines[:n]) != h:
                need_full = True
                break
            if len(lines) > n:
                replay_lines(rel, n, lines[n:])
        else:
            replay_lines(rel, 0, lines)       # 新分片（已保证排在全部缓存分片之后）
        new_wm[rel] = {"n": len(lines), "h": hash_lines(lines)}
    if need_full:  # 前缀校验中途失败：状态已被部分污染，从零全量
        tasks, retired, conflicts, last_progress = fresh_state()
        new_wm = {}
        for rel in shards:
            lines = open(os.path.join(HOME, rel), encoding="utf-8").read().splitlines(keepends=True)
            replay_lines(rel, 0, lines)
            new_wm[rel] = {"n": len(lines), "h": hash_lines(lines)}
        stats["full"] += 1
    else:
        stats["incr"] += 1
    wm = new_wm

def render(title, items):
    out = [f"<!-- derived: do not edit by hand -->\n# {title}\n"]
    out += [f"- {x}\n" for x in items] or ["- （空）\n"]
    return "".join(out)

cols = collections.defaultdict(list)
for tid in sorted(tasks):
    t = tasks[tid]
    if t["state"] == "in-progress":
        line = f"{tid} — {t['owner']}"
        lp = last_progress.get(tid)
        if lp:
            if isinstance(lp, str): lp = ("", lp)   # 旧 cache 兼容（str → 无时间）
            age = ""
            if lp[0]:
                try:
                    from datetime import datetime
                    m = max(int((datetime.now().astimezone() - datetime.fromisoformat(lp[0])).total_seconds() // 60), 0)   # 跨机钟漂：未来 ts 钳零
                    age = f"（{m}min前）" if m < 1440 else f"（{m // 60}h前）"
                except (ValueError, TypeError): pass   # 畸形/无时区 ts 静默（v1.31）
            line += f" — 进展{age}: {lp[1]}"
        cols["in-progress"].append(line)
    elif t["state"] == "blocked": cols["blocked"].append(f"{tid} — {t['owner']}" if t.get("owner") else tid)
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
# 条件视图：有则落盘、无则清除陈旧文件（reopened/状态回迁不留死文件）
def _write_optional(name, title, items):
    p = f"{HOME}/board/{name}.md"
    if items:
        open(p, "w").write(render(title, items))
    elif os.path.exists(p):
        os.remove(p)

_write_optional("conflicts", "Conflicts (claim_conflict)", conflicts)
_write_optional("cancelled", "Cancelled",
                [tid for tid in sorted(tasks) if tasks[tid]["state"] == "cancelled"])

os.makedirs(os.path.dirname(CACHE_F), exist_ok=True)
json.dump({"v": 5, "watermark": wm, "tasks": tasks, "retired": sorted(retired),
           "conflicts": conflicts, "last_progress": last_progress,
           "task_ids": task_ids, "stats": stats},
          open(CACHE_F, "w"))
PYEOF
