#!/usr/bin/env bash
# poll.sh —— 唤醒、看门狗与本地保洁（cron/systemd 定时调用，单次执行非守护进程）
#
# 职责：
#   ① sync（见到全网最新账本）
#   ② stalled 看门狗（CONVENTIONS §4）：in-progress 任务 20min 无新事件=可疑（仅报告），
#      40min=派生 diagnosed 事件进诊断队列并 mention 认领者。
#      活性判定只看"本机首次观察到当前最后事件的时刻"（poll-state.json 的
#      _activity 跟踪表），不解析事件 ts —— 对跨机时钟漂移免疫。
#      升级阶梯（账本推导，跨机一致）：同一任务连续 wn 条看门狗诊断无响应 →
#      wn 达 AGORA_WATCHDOG_ESCALATE_AFTER（默认 3）→ escalated 并 mention 认领者+
#      dispatcher；再之后 AGORA_WATCHDOG_AUTO_REOPEN=1（默认关）则 reopened 回池，
#      否则保持安静（不再刷屏）。发诊断前先 sync 再见一次账本，他机已处理则采信复位
#      （跨机撞窗守卫）
#   ③ mention 拾取：本机实体（名册 dirs 在本机存在）的收件箱有新邮件且任务仍待认领
#      （在 board/todo.md 中）→ 本机 dispatch 拉起；拉起模板内置"开工前复查 owner"惯例
#   ④ 本地保洁：sessions.map 本机条目超 TTL（默认 24h）剔除；inbox 超期邮件
#      （默认 90 天）移入 inbox/archive/<name>/；变更 best-effort 提交并推送
#
# 状态：.git/poll-state.json（per-entity 邮件水位 + per-task 活性跟踪）与
#       .git/poll.lock —— 本机文件，不进同步
# 环境：AGORA_POLL_SPAWN=0 只报告不派生；AGORA_POLL_WARN_MIN=20；AGORA_POLL_CRIT_MIN=40；
#       AGORA_WATCHDOG_ESCALATE_AFTER=3（连续诊断升级阈值）；AGORA_WATCHDOG_AUTO_REOPEN=1
#       时 escalated 之后任务自动 reopened 回池（默认关，保持人工）；
#       AGORA_DISPATCH_TIMEOUT=30（.live 标记滞留阈值，分钟；滞留超阈值 mention 派单方一次）；
#       AGORA_SESSION_TTL_H=24（本机 sessions.map 条目存活小时数，0=不清）；
#       AGORA_INBOX_ARCHIVE_DAYS=90（邮件归档阈值天数，0=不归档）
# 用法：crontab -e → */5 * * * * AGORA_HOME=~/agora bash ~/agora/scripts/poll.sh
set -uo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
[[ -d "$AGORA_HOME/.git" ]] || { echo '{"code":"NO_FORUM","message":"AGORA_HOME 无仓库"}' >&2; exit 2; }

# 防 cron 重叠：拿不到锁说明上一轮还在跑，安静退出
exec 9>"$AGORA_HOME/.git/poll.lock"
flock -n 9 || { echo '{"poll":"skip","reason":"another poll running"}'; exit 0; }

bash "$AGORA_HOME/scripts/sync.sh" pre >/dev/null 2>&1 || true
bash "$AGORA_HOME/scripts/derive-board.sh" >/dev/null 2>&1 || true

AGORA_HOME="$AGORA_HOME" PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import os, re, glob, json, time, shutil, hashlib, subprocess, socket
import agora_lib as lib
from datetime import datetime

HOME = os.environ["AGORA_HOME"]
WARN = int(os.environ.get("AGORA_POLL_WARN_MIN", "20"))
CRIT = int(os.environ.get("AGORA_POLL_CRIT_MIN", "40"))
LIVE_TIMEOUT = int(os.environ.get("AGORA_DISPATCH_TIMEOUT", "30"))
MERGE_WAIT = int(os.environ.get("AGORA_MERGE_WAIT_MIN", "15"))
REDISPATCH_MAX = int(os.environ.get("AGORA_REDISPATCH_MAX", "3"))
ORPHAN_MIN = int(os.environ.get("AGORA_ORPHAN_MIN", "10"))
WT_GRACE_MIN = int(os.environ.get("AGORA_WT_GRACE_MIN", "60"))
TTL_H = int(os.environ.get("AGORA_SESSION_TTL_H", "24"))
ARCH_D = int(os.environ.get("AGORA_INBOX_ARCHIVE_DAYS", "90"))
SPAWN = os.environ.get("AGORA_POLL_SPAWN", "1") != "0"
HOST = socket.gethostname()
WATCHDOG = f"watchdog@{HOST}"
STATE_F = os.path.join(HOME, ".git", "poll-state.json")

RECHECK = ("纪律：开工前先 agora_sync，再用 agora_history 复查该任务 owner——"
           "若已被他人认领，立即 agora_post(event=retired, task=本任务) 收工，一行代码都不要写。")

def run(script, args):
    return subprocess.run(["bash", os.path.join(HOME, "scripts", script)] + args,
                          capture_output=True, text=True,
                          env={**os.environ, "AGORA_HOME": HOME})

def task_last_refs():
    """task -> (指纹, event, actor, wn)。wn = 该任务尾部连续看门狗诊断条数
    （账本推导的升级阶梯计数，跨机一致，任何真实活动即归零）。
    事件解析走 agora_lib（行格式唯一真源）；畸形行跳过。"""
    refs = {}
    for f in sorted((glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md"))):
        rel = os.path.relpath(f, HOME)
        with open(f, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                e = lib.parse_event(line)
                if not e: continue
                t = e.get("task") or ""
                if not re.fullmatch(r"gt-[0-9a-f]+", t): continue
                h = hashlib.sha1(line.encode()).hexdigest()[:16]
                wn = 0
                if e["event"] in ("diagnosed", "escalated") and e["actor"].startswith("watchdog@"):
                    wn = (refs.get(t) or (None, "", "", 0))[3] + 1
                refs[t] = (f"{rel}:{i}:{h}", e["event"], e["actor"], wn)
    return refs

report = {"poll": "ok", "host": HOST, "stalled": [], "suspicious": [], "escalated": [],
          "reopened": [], "spawned": [], "held": [], "stale_live": 0,
          "sessions_reaped": 0, "mails_archived": 0,
          "merge_wait_diag": [], "redispatched": [], "escalated_merge": [],
          "orphan_diag": [], "wt_removed": [], "wt_kept_dirty": [], "wt_kept_grace": [], "wt_remove_failed": []}

now = time.time()

# ---------- ② stalled 看门狗（活性 = 本机观察时钟，免疫跨机钟漂） ----------
todo_txt = open(f"{HOME}/board/todo.md", encoding="utf-8").read() \
    if os.path.exists(f"{HOME}/board/todo.md") else ""
inprog = []  # (task, owner_name)
ip = f"{HOME}/board/in-progress.md"
if os.path.exists(ip):
    for line in open(ip, encoding="utf-8"):
        m = re.match(r'^- (gt-[0-9a-f]+) — (\S+)', line.strip())
        if m: inprog.append((m.group(1), m.group(2).split("@")[0]))

try: state = json.load(open(STATE_F))
except Exception: state = {}
act = state.setdefault("_activity", {})
refs = task_last_refs()
live_tasks = {t for t, _ in inprog}
for t in list(act):  # 已离开 in-progress 的任务清出跟踪表，状态文件不膨胀
    if t not in live_tasks: del act[t]

ESCALATE_AFTER = int(os.environ.get("AGORA_WATCHDOG_ESCALATE_AFTER", "3"))
AUTO_REOPEN = os.environ.get("AGORA_WATCHDOG_AUTO_REOPEN", "0") == "1"

def task_dispatcher(task):
    p = f"{HOME}/wiki/tasks/{task}.md"
    if os.path.exists(p):
        m = re.search(r'^dispatcher:\s*(\S+)', open(p, encoding="utf-8").read(), re.M)
        if m: return m.group(1)
    return None

def scan_tasks():
    """task -> {"dispatched":[(actor,run,dispatcher_task)...], "has":set(events), "last":event}。
    账本推导唯一口径（重派/孤儿/GC/豁免共用）；last/done_open 按 ts 序重放（跨分片文件序≠时间序）。"""
    tasks = {}
    for f in sorted((glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md"))):
        with open(f, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                e = lib.parse_event(line)
                if not e: continue
                t = e.get("task") or ""
                if not re.fullmatch(r"gt-[0-9a-f]+", t): continue
                d = tasks.setdefault(t, {"dispatched": [], "has": set(), "last": None, "done_open": False, "last_actor": "", "_rows": []})
                d["_rows"].append((e.get("ts", ""), e["event"]))
                d["has"].add(e["event"])
                d["last_actor"] = e.get("actor", "")
                if e["event"] == "dispatched":
                    d["dispatched"].append((e.get("actor", ""), e.get("run", ""), e.get("dispatcher_task", ""), e.get("session", "")))
    for d in tasks.values():
        rows = sorted(d["_rows"], key=lambda r: r[0])  # gt-caf3/gt-db15：跨分片文件序≠时间序，状态机统一按 ts 序
        d["last"] = rows[-1][1] if rows else None  # B-M3：last 按 ts 序取尾行——与 done_open 重放同口径（同 ts 平局一致）
        for _ts, ev in rows:  # gt-db15：done_open 同按 ts 序重放——同日多分片文件名字典序≠时间序
            if ev == "done": d["done_open"] = True          # done 未闭：merged/cancelled/reopened 才清
            elif ev in ("merged", "cancelled", "reopened"): d["done_open"] = False
        del d["_rows"]
    return tasks

TASKS = scan_tasks()
TERMINALS = {"done", "merged", "cancelled"}

# ×4 豁免集（设计 §六 watchdog）：任务被「活 dispatched 的 dispatcher_task」指向，
# 或为 in-progress 任务的 parent/deps 上游 —— 有活下级的等待不算 stalled
exempt = set()
for t, d in TASKS.items():
    if d["has"] & TERMINALS or not d["dispatched"]: continue
    for _, _, up, _sess in d["dispatched"]:
        if up: exempt.add(up)
for t in {x for x, _ in inprog}:
    p = f"{HOME}/wiki/tasks/{t}.md"
    if os.path.exists(p):
        txt = open(p, encoding="utf-8").read()
        pm = re.search(r'^parent:\s*(gt-[0-9a-f]+)', txt, re.M)
        if pm: exempt.add(pm.group(1))
        dm = re.search(r'^deps:\s*\[([^\]]*)\]', txt, re.M)
        if dm: exempt.update(re.findall(r'gt-[0-9a-f]+', dm.group(1)))

for task, owner in inprog:
    cur = refs.get(task)
    fp = cur[0] if cur else "none"  # 无事件（仅任务页）也纳入跟踪，自首次观察起计时
    e = act.get(task)
    if not isinstance(e, dict) or e.get("last_ref") != fp:
        e = {"last_ref": fp, "since": now}   # 初见 / 有新事件：活性时钟归零
        act[task] = e
    age = (now - float(e.get("since", now))) / 60
    crit_t = CRIT * 4 if task in exempt else CRIT   # 链上等待豁免：阈值 ×4
    warn_t = crit_t // 2
    if age <= crit_t:
        if age > warn_t:
            report["suspicious"].append({"task": task, "owner": owner, "age_min": int(age)})
        continue
    # 跨机撞窗守卫：发诊断前再见一次全网账本；任务有了新事件（他机看门狗/认领者
    # 已处理）→ 采信并复位，不重复落账
    run("sync.sh", ["pre"])
    cur2 = task_last_refs().get(task)
    fp2 = cur2[0] if cur2 else "none"
    if fp2 != fp:
        act[task] = {"last_ref": fp2, "since": now}
        continue
    wn = cur2[3] if cur2 else 0  # 尾部连续看门狗诊断条数（含 escalated）
    disp = task_dispatcher(task)
    mention = owner
    if disp and disp != owner: mention = f"{owner},{disp}"
    if wn < ESCALATE_AFTER:
        r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog",
                            "--event", "diagnosed", "--task", task,
                            "--conclusion", f"stalled: 任务 {task} 已 {int(age)}min 无新事件落账（阈值 {CRIT}min，本机观察时钟），认领者 {owner}（第 {wn+1} 次诊断）",
                            "--mention", owner])
        if r.returncode == 0:
            act[task] = {"last_ref": None, "since": now}  # 复位：下轮拾取 diagnosed 新事件重建时钟
        report["stalled"].append({"task": task, "owner": owner, "age_min": int(age),
                                  "diag": wn + 1, "ok": r.returncode == 0})
    elif wn == ESCALATE_AFTER:
        r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog",
                            "--event", "escalated", "--task", task,
                            "--conclusion", f"stalled 升级：任务 {task} 连续 {wn} 次诊断无响应（认领者 {owner} 可能已死/掉线），请介入或重新分配",
                            "--mention", mention])
        if r.returncode == 0:
            act[task] = {"last_ref": None, "since": now}
        report["escalated"].append({"task": task, "owner": owner, "ok": r.returncode == 0})
    elif AUTO_REOPEN:
        r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog",
                            "--event", "reopened", "--task", task,
                            "--reason", f"watchdog 自动回池：escalated 后仍无响应（AGORA_WATCHDOG_AUTO_REOPEN=1）",
                            "--mention", disp or owner])
        if r.returncode == 0:
            act.pop(task, None)  # 回池后离开 in-progress，移出跟踪
        report["reopened"].append({"task": task, "owner": owner, "ok": r.returncode == 0})
    # else：已 escalated 且未开自动回池 —— 保持安静，不刷屏

# .live 滞留（派生会话超时不退）：计数 + 回溯 dispatched 事件 mention 派单方（每个 did 一次）
live_notified = state.setdefault("_live_notified", {})
for f in glob.glob(f"{HOME}/raw/dispatches/*.live"):
    age_min = (now - os.path.getmtime(f)) / 60
    if age_min <= LIVE_TIMEOUT: continue
    report["stale_live"] += 1
    did = os.path.basename(f)[:-5]
    if did in live_notified: continue
    disp, dtask = None, None
    for lf in sorted((glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md"))):
        for line in open(lf, encoding="utf-8"):
            if did in line and "| event:dispatched" in line:
                am = re.search(r'\| actor:(\S+)', line)
                tm = re.search(r'\| task:(gt-[0-9a-f]+)', line)
                if am: disp = am.group(1).split("@")[0]
                if tm: dtask = tm.group(1)
    if disp and dtask and dtask in live_tasks:
        r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog",
                            "--event", "diagnosed", "--task", dtask,
                            "--conclusion", f"派生会话 {did} 超 {int(age_min)}min 未退（.live 滞留，子会话或已死/卡死），派单方 {disp} 请核查后 kill 并 rm 标记",
                            "--mention", disp])
        if r.returncode == 0:
            report["stale_live_notified"] = report.get("stale_live_notified", 0) + 1
    live_notified[did] = now  # 无论是否提醒都只记一次（防轮轮重复）
live_now = {os.path.basename(f)[:-5] for f in glob.glob(f"{HOME}/raw/dispatches/*.live")}
for d in list(live_notified):
    if d not in live_now: del live_notified[d]  # .live 已清，移出通知记录

# ---------- ③ mention 拾取（目录存在性 = 机器归属；水位 = 邮件文件名，定宽时间戳字典序可比） ----------
def local_dirs(f):
    txt = open(f, encoding="utf-8", errors="replace").read()
    return [d for d in (os.path.realpath(os.path.expanduser(x)) for x in lib.entity_dirs(txt))
            if os.path.isdir(d)]

for f in sorted(glob.glob(f"{HOME}/wiki/entities/*.md")):
    name = os.path.basename(f)[:-3]
    if not lib.valid_entity_name(name): continue   # 畸形实体名不参与 mention 拾取
    dirs = local_dirs(f)
    if not dirs: continue  # 不是本机实体
    can_spawn = bool(re.search(r'^can_spawn:\s*true', open(f, encoding="utf-8", errors="replace").read(), re.M))
    mails = sorted(glob.glob(f"{HOME}/inbox/{name}/*.md"))
    wm = state.get(name, "")
    if not isinstance(wm, str): wm = ""
    new = [m for m in mails if os.path.basename(m) > wm]
    for mail in new:
        m = re.search(r'\| summary:\S+\s+(gt-[0-9a-f]+)', open(mail, encoding="utf-8").read())
        task = m.group(1) if m else None
        if not task or not re.search(rf'^- {re.escape(task)}\b', todo_txt, re.M):
            continue  # 无任务 / 已被认领 / 已终结 —— 只推进水位
        # wt_host 限定（设计 §五）：跨机 wt 任务不本地拾取（他机的树本地不可用）
        tp = f"{HOME}/wiki/tasks/{task}.md"
        if os.path.exists(tp):
            hm = re.search(r'^wt_host:\s*(\S+)', open(tp, encoding="utf-8").read(), re.M)
            if hm and hm.group(1) != HOST:
                report["held"].append({"entity": name, "task": task,
                                       "reason": f"wt_host={hm.group(1)}≠{HOST}，跨机 wt 任务不本地拾取"})
                continue
        if not (can_spawn and SPAWN):
            report["held"].append({"entity": name, "task": task,
                                   "reason": "can_spawn=false" if not can_spawn else "POLL_SPAWN=0"})
            continue
        r = run("dispatch.sh", ["--actor", f"{name}@{os.path.basename(dirs[0])}",
                                "--project", dirs[0], "--task", task, "--prompt", RECHECK])
        if r.returncode == 0:
            try: out = json.loads(r.stdout.strip().splitlines()[-1])
            except Exception: out = {"raw": r.stdout[-200:]}
            report["spawned"].append({"entity": name, "task": task, "prompt": RECHECK, **out})
        else:
            report["held"].append({"entity": name, "task": task,
                                   "reason": r.stderr.strip().splitlines()[-1][:120] if r.stderr else "dispatch failed"})
    if new: state[name] = os.path.basename(new[-1])

# ---------- ②c done-unmerged 恢复性重派档（设计 §六 定案 ii：poll 重派上游 dispatcher） ----------
mw = state.setdefault("_merge_wait", {})
for t, d in TASKS.items():
    page = f"{HOME}/wiki/tasks/{t}.md"
    txt = open(page, encoding="utf-8").read() if os.path.exists(page) else ""
    if "wt_dir:" not in txt:
        mw.pop(t, None); continue
    # done_open＝done 后无 merged/cancelled/reopened（诊断/blocked 不打断跟踪）
    if not d.get("done_open") or "merged" in d["has"]:
        mw.pop(t, None); continue
    e = mw.get(t)
    if not isinstance(e, dict):
        e = {"since": now, "n": 0}; mw[t] = e
    if (now - float(e.get("since", now))) / 60 < MERGE_WAIT: continue
    run("sync.sh", ["pre"])   # 撞窗守卫：发诊前再见一次全网账本
    d2 = scan_tasks().get(t)
    if not d2 or not d2.get("done_open") or "merged" in d2["has"]:
        mw.pop(t, None); continue
    ups = [x[2] for x in d["dispatched"] if x[2]]
    # 通知目标：派单方优先；未派发过（直建任务）→ 任务最后 actor（通常 claimer）——失败必响到人
    disp_actor = d["dispatched"][-1][0] if d["dispatched"] else (d.get("last_actor") or "watchdog")
    n = int(e.get("n", 0)) + 1
    if n > REDISPATCH_MAX:
        r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog", "--event", "escalated",
                            "--task", t,
                            "--conclusion", f"done 未合并超限：{t} 已 {n-1} 次恢复性重派仍无 merged（上限 {REDISPATCH_MAX}），请 operator/派单方 {disp_actor} 介入",
                            "--mention", disp_actor.split("@")[0]])
        if r.returncode == 0: mw.pop(t, None)
        report["escalated_merge"].append({"task": t, "n": n, "ok": r.returncode == 0})
        continue
    r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog", "--event", "diagnosed",
                        "--task", t,
                        "--conclusion", f"done 未合并：{t} 已 done 且超 {MERGE_WAIT}min 无 merged（第 {n}/{REDISPATCH_MAX} 次提醒），dispatcher 请评审 diff 后 merge.sh 闭环",
                        "--mention", disp_actor.split("@")[0]])   # A-W2：失败必响——派单方 inbox 必达
    if ups and r.returncode == 0 and SPAWN:
        up = ups[-1]
        upage = f"{HOME}/wiki/tasks/{up}.md"
        if os.path.exists(upage):
            upd = re.search(r'^project_dir:\s*(\S+)', open(upage, encoding="utf-8").read(), re.M)
            if upd:
                boot = (f"恢复性重派：你的下级任务 {t} 已 done 未合并。先 agora_history(task={t}) 自查，"
                        f"再评审其 diff（任务页 wt_dir 的树），然后 bash {HOME}/scripts/merge.sh"
                        f" --actor {disp_actor} --task {t} 闭环；若 non-ff 先在原树 rebase 到合并目标分支"
                        f"再重走 verify。完成后继续你自己的任务。")
                # L2 注入式续跑（设计 §三）：上游最新 dispatched 带 session: 且 wt_host==本机 → inject 优先
                # （sid 只在本机 opencode 服务有效——跨机判则沿用 wt_host；无 session:/失败 → 回落恢复性重派）
                injected = False
                api_on = (os.environ.get("AGORA_RUNTIME_API", "1") != "0"
                          and os.environ.get("AGORA_RUNTIME", "opencode") == "opencode"
                          and os.path.exists(f"{HOME}/scripts/runtime/opencode.sh"))
                if api_on:
                    upsess = ""
                    for _row in (TASKS.get(up) or {}).get("dispatched", []):
                        if _row[3]: upsess = _row[3]
                    wh = re.search(r'^wt_host:\s*(\S+)', open(upage, encoding="utf-8").read(), re.M)
                    if upsess and wh and wh.group(1) == HOST:
                        ri = run("runtime/opencode.sh", ["inject", upsess, boot])
                        if ri.returncode == 0:
                            injected = True
                            report["redispatched"].append({"upstream": up, "downstream": t, "n": n, "mode": "injected"})
                if not injected:
                    # M5：重派上游时透传其原链 dispatcher_task（上游自身 dispatched 的最新链字段），
                    # 防重派抹链致后续深度推导降级
                    upchain = (TASKS.get(up) or {}).get("dispatched") or []
                    rargs = ["--actor", disp_actor, "--project", upd.group(1), "--task", up, "--prompt", boot]
                    if upchain and upchain[-1][2]:
                        rargs += ["--dispatcher-task", upchain[-1][2]]
                    r2 = run("dispatch.sh", rargs)
                    if r2.returncode == 0:
                        report["redispatched"].append({"upstream": up, "downstream": t, "n": n, "mode": "spawned"})
    mw[t] = {"since": now, "n": n}
    report["merge_wait_diag"].append({"task": t, "n": n})

# ---------- ②d 孤儿 dispatched 档（FMEA B3：落账后 spawn 前崩溃——run log 缺失＝spawn 未执行） ----------
orph = state.setdefault("_orphan", {})
for t, d in TASKS.items():
    # B-M3：判据＝最后事件==dispatched 且 run log 缺失（累计 has 集曾令 stalled 诊断过的
    # 任务此后真孤儿永不报）；终态或后续任何活动（progress/done 等）自然出集
    if not d["dispatched"] or d["last"] != "dispatched":
        orph.pop(t, None); continue
    _, runf, _, _ = d["dispatched"][-1]
    if runf and os.path.exists(os.path.join(HOME, runf)):
        orph.pop(t, None); continue
    e = orph.get(t)
    if not isinstance(e, dict): e = {"since": now, "n": 0}; orph[t] = e
    if (now - float(e.get("since", now))) / 60 < ORPHAN_MIN: continue
    actor = d["dispatched"][-1][0] or "watchdog"
    n = int(e.get("n", 0)) + 1
    if n > REDISPATCH_MAX:
        r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog", "--event", "escalated",
                            "--task", t, "--conclusion", f"孤儿 dispatched 超限：{t} 多轮无 run log（上限 {REDISPATCH_MAX}），请介入",
                            "--mention", actor.split("@")[0]])
        if r.returncode == 0: orph.pop(t, None)
        report["escalated_merge"].append({"task": t, "orphan": True, "n": n, "ok": r.returncode == 0})
        continue
    r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog", "--event", "diagnosed",
                        "--task", t,
                        "--conclusion", f"孤儿 dispatched：{t} 已落账派发但 run log 缺失（spawn 未执行，第 {n}/{REDISPATCH_MAX} 次），恢复性重派"])
    page = f"{HOME}/wiki/tasks/{t}.md"
    redisp = False  # B-M4：核查 dispatch 返回码，失败如实回报不谎报
    if r.returncode == 0 and SPAWN and os.path.exists(page):
        upd = re.search(r'^project_dir:\s*(\S+)', open(page, encoding="utf-8", errors="replace").read(), re.M)
        if upd:
            r2 = run("dispatch.sh", ["--actor", actor, "--project", upd.group(1), "--task", t,
                                     "--prompt", RECHECK])
            redisp = r2.returncode == 0
    orph[t] = {"since": now, "n": n, "redispatched": redisp}
    report["orphan_diag"].append({"task": t, "n": n, "redispatched": redisp})

# ---------- ④c wt 树 GC（终态＋宽限＋clean→删；dirty/宽限内→报告；缺任务页树归 doctor 只报告） ----------
gcst = state.setdefault("_wtgc", {})
for page in glob.glob(f"{HOME}/wiki/tasks/*.md"):
    t = os.path.basename(page)[:-3]
    txt = open(page, encoding="utf-8").read()
    wm = re.search(r'^wt_dir:\s*(\S+)', txt, re.M)
    if not wm or not os.path.isdir(wm.group(1)): continue
    d = TASKS.get(t)
    # B-C1（终审）：GC 判据＝merged 或 cancelled——done 单独不足（done≠merged 是 L1 核心语义，
    # 未合并的 done 任务树/分支是唯一工作现场，删之即数据丢失）
    if not d or not (d["has"] & {"merged", "cancelled"}): continue
    e = gcst.get(t)
    if not isinstance(e, dict): e = {"since": now}; gcst[t] = e
    if (now - float(e.get("since", now))) / 60 < WT_GRACE_MIN:
        report["wt_kept_grace"].append(t); continue
    wtd = wm.group(1)
    dirty = subprocess.run(["git", "-C", wtd, "status", "--porcelain"],
                           capture_output=True, text=True).stdout.strip()
    if dirty:
        report["wt_kept_dirty"].append(t); continue
    main_ = lib.main_repo_of(wtd) or wtd
    rr = subprocess.run(["git", "-C", main_, "worktree", "remove", wtd],
                        capture_output=True, text=True)
    if rr.returncode != 0:
        try: os.rmdir(wtd)   # remove 失败常剩空壳（git 已摘 worktree 元数据）；rmdir 只删空目录，不碰有数据现场
        except OSError: pass
    if not os.path.isdir(wtd):
        gcst.pop(t, None); report["wt_removed"].append(t)
        subprocess.run(["git", "-C", main_, "branch", "-q", "-D", f"wt/{t}"], capture_output=True)
    else:
        # B-M7：删失败必响（report 可见）且 gcst 保留待下轮重试；跳过 branch -D（防分支先于树删除）
        report["wt_remove_failed"].append(
            {"task": t, "dir": wtd,
             "err": ((rr.stderr or rr.stdout or "unknown").strip().splitlines() or ["unknown"])[-1][:160]})

# ---------- ④a sessions.map TTL 保洁（只清本机条目；他机条目由它自己机器的 poll 清） ----------
SMAP = f"{HOME}/scripts/sessions.map"
if TTL_H > 0 and os.path.exists(SMAP):
    kept, reaped = [], 0
    for ln in open(SMAP, encoding="utf-8").read().splitlines(keepends=True):
        p = ln.split()
        if p and not ln.startswith("#") and len(p) >= 4 and p[0] == HOST:
            try:
                if (now - datetime.fromisoformat(p[3]).timestamp()) / 3600 > TTL_H:
                    reaped += 1
                    continue
            except Exception: pass  # 时间戳解析失败 = 条目存疑但不动它（保守）
        kept.append(ln)
    if reaped:
        open(SMAP, "w", encoding="utf-8").writelines(kept)
        report["sessions_reaped"] = reaped

# ---------- ④b inbox 归档（文件名 = 纳秒时间戳，定宽可解析；解析失败退回 mtime） ----------
if ARCH_D > 0:
    cutoff = now - ARCH_D * 86400
    for mail in glob.glob(f"{HOME}/inbox/*/*.md"):
        name = os.path.basename(os.path.dirname(mail))
        if name == "archive": continue
        try: mt = int(os.path.basename(mail)[:-3]) / 1e9
        except ValueError: mt = os.path.getmtime(mail)
        if mt < cutoff:
            dst = f"{HOME}/inbox/archive/{name}"
            os.makedirs(dst, exist_ok=True)
            shutil.move(mail, os.path.join(dst, os.path.basename(mail)))
            report["mails_archived"] += 1

# 保洁变更 best-effort 入库 + 推送（失败不拒，下轮 pre 合并重试）
if report["sessions_reaped"] or report["mails_archived"]:
    env = {**os.environ, "AGORA_HOME": HOME, "AGORA_MECHANICAL": "1"}
    subprocess.run(["git", "add", "scripts/sessions.map", "inbox/"],
                   cwd=HOME, env=env, capture_output=True)
    r = subprocess.run(["git", "-c", f"user.name={WATCHDOG}",
                        "-c", f"user.email={WATCHDOG}@local", "commit", "-qm",
                        f"chore: poll 保洁（sessions -{report['sessions_reaped']}, mails archived {report['mails_archived']}）"],
                       cwd=HOME, env=env, capture_output=True, text=True)
    if r.returncode == 0:
        run("sync.sh", ["post"])

os.makedirs(os.path.dirname(STATE_F), exist_ok=True)
json.dump(state, open(STATE_F, "w"))
print(json.dumps(report, ensure_ascii=False))
PYEOF
