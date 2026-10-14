#!/usr/bin/env bash
# poll.sh —— 唤醒、看门狗与本地保洁（cron/systemd 定时调用，单次执行非守护进程）
#
# 职责：
#   ① sync（见到全网最新账本）
#   ② stalled 看门狗（CONVENTIONS §4）：in-progress 任务 20min 无新事件=可疑（仅报告），
#      40min=派生 diagnosed 事件进诊断队列并 mention 认领者；看门狗自己的 diagnosed
#      事件会重置该任务的活性时钟（自然形成 40min cadence，不刷屏）。
#      活性判定只看"本机首次观察到当前最后事件的时刻"（poll-state.json 的
#      _activity 跟踪表），不解析事件 ts —— 对跨机时钟漂移免疫
#   ③ mention 拾取：本机实体（名册 dirs 在本机存在）的收件箱有新邮件且任务仍待认领
#      （在 board/todo.md 中）→ 本机 dispatch 拉起；拉起模板内置"开工前复查 owner"惯例
#   ④ 本地保洁：sessions.map 本机条目超 TTL（默认 24h）剔除；inbox 超期邮件
#      （默认 90 天）移入 inbox/archive/<name>/；变更 best-effort 提交并推送
#
# 状态：.git/poll-state.json（per-entity 邮件水位 + per-task 活性跟踪）与
#       .git/poll.lock —— 本机文件，不进同步
# 环境：AGORA_POLL_SPAWN=0 只报告不派生；AGORA_POLL_WARN_MIN=20；AGORA_POLL_CRIT_MIN=40；
#       AGORA_DISPATCH_TIMEOUT=30（.live 标记滞留报告阈值，分钟）；
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

AGORA_HOME="$AGORA_HOME" python3 - <<'PYEOF'
import os, re, glob, json, time, shutil, hashlib, subprocess, socket
from datetime import datetime

HOME = os.environ["AGORA_HOME"]
WARN = int(os.environ.get("AGORA_POLL_WARN_MIN", "20"))
CRIT = int(os.environ.get("AGORA_POLL_CRIT_MIN", "40"))
LIVE_TIMEOUT = int(os.environ.get("AGORA_DISPATCH_TIMEOUT", "30"))
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
    """task -> 其最后事件的内容指纹（shard 名序 + 物理行序 = 权威序，与 derive 一致）。"""
    refs = {}
    for f in sorted(glob.glob(f"{HOME}/log/*/*.md")):
        rel = os.path.relpath(f, HOME)
        with open(f, encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                m = re.search(r'\| task:(gt-[0-9a-f]+)\b', line)
                if m:
                    h = hashlib.sha1(line.encode()).hexdigest()[:16]
                    refs[m.group(1)] = f"{rel}:{i}:{h}"
    return refs

report = {"poll": "ok", "host": HOST, "stalled": [], "suspicious": [],
          "spawned": [], "held": [], "stale_live": 0,
          "sessions_reaped": 0, "mails_archived": 0}

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

for task, owner in inprog:
    ref = refs.get(task, "none")  # 无事件（仅任务页）也纳入跟踪，自首次观察起计时
    e = act.get(task)
    if not isinstance(e, dict) or e.get("last_ref") != ref:
        e = {"last_ref": ref, "since": now}   # 初见 / 有新事件：活性时钟归零
        act[task] = e
    age = (now - float(e.get("since", now))) / 60
    if age > CRIT:
        r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog",
                            "--event", "diagnosed", "--task", task,
                            "--conclusion", f"stalled: 任务 {task} 已 {int(age)}min 无新事件落账（阈值 {CRIT}min，本机观察时钟），认领者 {owner}",
                            "--mention", owner])
        if r.returncode == 0:
            act[task] = {"last_ref": None, "since": now}  # 复位：下轮拾取 diagnosed 新事件重建时钟
        report["stalled"].append({"task": task, "owner": owner, "age_min": int(age),
                                  "ok": r.returncode == 0})
    elif age > WARN:
        report["suspicious"].append({"task": task, "owner": owner, "age_min": int(age)})

# .live 滞留（派生会话超时不退）
for f in glob.glob(f"{HOME}/raw/dispatches/*.live"):
    if (now - os.path.getmtime(f)) / 60 > LIVE_TIMEOUT:
        report["stale_live"] += 1

# ---------- ③ mention 拾取（目录存在性 = 机器归属；水位 = 邮件文件名，定宽时间戳字典序可比） ----------
def local_dirs(f):
    txt = open(f, encoding="utf-8").read()
    dirs = [os.path.realpath(os.path.expanduser(d))
            for d in re.findall(r'^\s+-\s+(\S+)\s*$', txt, re.M)]
    return [d for d in dirs if os.path.isdir(d)]

for f in sorted(glob.glob(f"{HOME}/wiki/entities/*.md")):
    name = os.path.basename(f)[:-3]
    dirs = local_dirs(f)
    if not dirs: continue  # 不是本机实体
    can_spawn = bool(re.search(r'^can_spawn:\s*true', open(f, encoding="utf-8").read(), re.M))
    mails = sorted(glob.glob(f"{HOME}/inbox/{name}/*.md"))
    wm = state.get(name, "")
    if not isinstance(wm, str): wm = ""
    new = [m for m in mails if os.path.basename(m) > wm]
    for mail in new:
        m = re.search(r'\| summary:\S+\s+(gt-[0-9a-f]+)', open(mail, encoding="utf-8").read())
        task = m.group(1) if m else None
        if not task or not re.search(rf'^- {re.escape(task)}\b', todo_txt, re.M):
            continue  # 无任务 / 已被认领 / 已终结 —— 只推进水位
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
