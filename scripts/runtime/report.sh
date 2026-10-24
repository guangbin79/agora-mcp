#!/usr/bin/env bash
# runtime/report.sh —— 账本周报（dogfood T3 毕业度量）：只读扫描账本，落盘 state 目录，stdout 同内容
# 口径固定：spawn=任务首条 dispatched；merged=任务首条 merged；干预=diagnosed/reopened/escalated/cancelled
# dispatcher 干预限 actor==任务页 dispatcher 字段；毕业 N=按 merged 时序扫 (spawn,merged] 窗口零干预连续任务数（遇干预归零重数，未 merged 不入列）
# drill JSON（T2）缺席→drill 节显式 N/A，禁计 0；分片扫描含点分片伴生（gt-40cc：glob 的 * 不含点开头）
# AGORA_HOME/AGORA_DRILL_STATE 可覆写（smoke fixture 缝），缺省 ~/plaza 与 ~/.local/state/agora-drill
set -euo pipefail
AH="${AGORA_HOME:-$HOME/plaza}"
DS="${AGORA_DRILL_STATE:-$HOME/.local/state/agora-drill}"
exec python3 - "$AH" "$DS" <<'PY'
import glob, json, os, re, sys
from datetime import datetime

ah, ds = sys.argv[1], sys.argv[2]
ra, rd = os.path.realpath(ah), os.path.realpath(ds)
if ra == rd or rd.startswith(ra + os.sep) or ra.startswith(rd + os.sep):
    # C 册终闸 C3＋Round-2 绕过收口：同路径或任一为另一子路径都会让报告落进账本仓（或扫描根被报告目录吞），静默破坏只读不变量——拒跑
    sys.stderr.write("report: AGORA_DRILL_STATE 与 AGORA_HOME 同路径或互相包含，拒跑（只读不变量）\n")
    sys.exit(2)
INTERVENE = {"diagnosed", "reopened", "escalated", "cancelled"}
LINE = re.compile(r"^- seq:\d+ \| ts:(\S+) \| actor:(\S+) \| event:([a-z_]+)")
TASK = re.compile(r"[ |]task:(\S+)")

# gt-40cc：glob 的 * 不含点开头，伴生分片 .xxx.md 必须显式追加
shards = sorted(glob.glob(os.path.join(ah, "log", "*", "*.md"))) + \
         sorted(glob.glob(os.path.join(ah, "log", "*", ".*.md")))
events = []  # (task, ts, actor, event)
for sh in shards:
    with open(sh, encoding="utf-8", errors="replace") as f:
        for ln in f:
            m = LINE.match(ln)
            if not m:
                continue
            t = TASK.search(ln)
            if t:
                events.append((t.group(1), m.group(1), m.group(2), m.group(3)))

disp = {}
for p in glob.glob(os.path.join(ah, "wiki", "tasks", "*.md")):
    for ln in open(p, encoding="utf-8", errors="replace"):
        m = re.match(r"^dispatcher: (\S+)", ln)
        if m:
            disp[os.path.basename(p)[:-3]] = m.group(1)
            break

by_task = {}
for task, ts, actor, ev in events:
    by_task.setdefault(task, []).append((ts, actor, ev))

def p_ts(s):
    # B1/N1（终闸两轮）：坏 ts 或缺时区（naive）的行＝跳过（与 LINE 不匹配同待遇）——
    # naive 值结构性无法进入任何比较/排序，混存崩溃全族一次闭合
    try:
        t = datetime.fromisoformat(s)
    except Exception:
        return None
    return t if t.tzinfo else None

runs = []  # (merge_dt, dirty, wall_seconds)
for task, evs in by_task.items():
    d = sorted(t for t in (p_ts(e[0]) for e in evs if e[2] == "dispatched") if t)
    g = sorted(t for t in (p_ts(e[0]) for e in evs if e[2] == "merged") if t)
    if not d or not g:
        continue
    spawn, merge = d[0], g[0]
    dirty = False
    for e in evs:
        dt = e[2] in INTERVENE and p_ts(e[0])
        if dt and spawn < dt <= merge:
            dirty = True
            break
    runs.append((merge, dirty, (merge - spawn).total_seconds()))
runs.sort()

na = not events  # 账本缺席：四数字与 N 全 N/A，禁计 0
if runs:
    walls = sorted(r[2] for r in runs)
    n = len(walls)
    med = walls[n // 2] if n % 2 else (walls[n // 2 - 1] + walls[n // 2] + 1) // 2  # 半舍入（A 册 A2）
    med_s = "N/A (n=%d)" % n if na else "%ds (n=%d)" % (int(med), n)
else:
    med_s = "N/A (n=0)"

def cnt(ev):
    return "N/A" if na else str(sum(1 for e in events if e[3] == ev))

def actor_is(actor, disp_name):
    # 身份规范化：账本 actor 带宿主后缀（name@host）、任务页 dispatcher 为裸名——按 @ 本地段比对
    # （现网实证：严格串比较令 dispatcher 干预恒 0；同源 gt-eefd actor-attribution 教训）
    return actor.split("@", 1)[0] == disp_name.split("@", 1)[0]

dint = "N/A" if na else str(sum(
    1 for task, ts, actor, ev in events
    if ev in INTERVENE and disp.get(task) and actor_is(actor, disp[task])))

if not runs:
    n_line = "N=N/A（无 merged 任务，禁计 0）"
    n_suffix = ""
else:
    streak = 0
    for merge, dirty, wall in runs:
        streak = 0 if dirty else streak + 1
    n_line = "N=%d" % streak
    n_suffix = "（目标 N≥10，中断即归零重数）"

def md_safe(s):
    # C 册终闸 C2：drill JSON 字段过信任边界，禁携带 markdown 结构（换行/管道/标题井）进报告
    return re.sub(r"[|\r\n#]", " ", str(s))

drill = "last_run: N/A（无报告 JSON，禁计 0）"
js = sorted(glob.glob(os.path.join(ds, "*.json")))
if js:
    try:
        r = json.load(open(js[-1], encoding="utf-8"))
        res = r.get("results", [])
        p = sum(1 for x in res if x.get("pass"))
        sk = "，skipped:%s" % md_safe(r["skipped"]) if r.get("skipped") else ""
        drill = "last_run: %s（pass %d/%d%s）" % (md_safe(r.get("ts", "?")), p, len(res), sk)
    except Exception:
        drill = "last_run: N/A（报告 JSON 解析失败，禁计 0）"

y, w, _ = datetime.now().isocalendar()
week = "%04d-W%02d" % (y, w)
now = datetime.now().astimezone().isoformat(timespec="seconds")
out = "\n".join([
    "# 账本周报 %s" % week,
    "",
    "- generated: %s（只读扫描 %s，零账本写入）" % (now, ah),
    "- 口径：spawn=任务首条 dispatched；merged=任务首条 merged；干预=diagnosed/reopened/escalated/cancelled；"
    "dispatcher 干预限 actor 与任务页 dispatcher 字段按 @ 本地段身份相等；毕业 N=按 merged 时序扫 (spawn,merged] 窗口零干预连续任务数，"
    "遇干预归零重数，未 merged 任务不入列",
    "",
    "## 四数字",
    "",
    "| 指标 | 值 |",
    "|---|---|",
    "| spawn→merged 中位墙钟 | %s |" % med_s,
    "| reopened 数 | %s |" % cnt("reopened"),
    "| diagnosed 数 | %s |" % cnt("diagnosed"),
    "| dispatcher 干预数 | %s |" % dint,
    "",
    "## 毕业计数",
    "",
    "- 连续零在场干预 spawn→merged 任务 %s%s" % (n_line, n_suffix),
    "",
    "## drill（T2 扰动演练）",
    "",
    "- %s" % drill,
    "",
])
os.makedirs(ds, exist_ok=True)
with open(os.path.join(ds, "report-%s.md" % week), "w", encoding="utf-8") as f:
    f.write(out)
sys.stdout.write(out)
PY
