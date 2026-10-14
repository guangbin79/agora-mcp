#!/usr/bin/env bash
# poll.sh —— 唤醒与看门狗（cron/systemd 定时调用，单次执行非守护进程）
#
# 职责：
#   ① sync（见到全网最新账本）
#   ② stalled 看门狗（CONVENTIONS §4）：in-progress 任务 20min 无事件=可疑（仅报告），
#      40min=派生 diagnosed 事件进诊断队列并 mention 认领者；看门狗自己的 diagnosed
#      事件会重置该任务的活性时钟（自然形成 40min  cadence，不刷屏）
#   ③ mention 拾取：本机实体（名册 dirs 在本机存在）的收件箱有新邮件且任务仍待认领
#      （在 board/todo.md 中）→ 本机 dispatch 拉起；拉起模板内置"开工前复查 owner"惯例
#
# 状态：.git/poll-state.json（per-entity 邮件水位）与 .git/poll.lock —— 本机文件，不进同步
# 环境：AGORA_POLL_SPAWN=0 只报告不派生；AGORA_POLL_WARN_MIN=20；AGORA_POLL_CRIT_MIN=40；
#       AGORA_DISPATCH_TIMEOUT=30（.live 标记滞留报告阈值，分钟）
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
import os, re, glob, json, time, subprocess, socket
from datetime import datetime

HOME = os.environ["AGORA_HOME"]
WARN = int(os.environ.get("AGORA_POLL_WARN_MIN", "20"))
CRIT = int(os.environ.get("AGORA_POLL_CRIT_MIN", "40"))
LIVE_TIMEOUT = int(os.environ.get("AGORA_DISPATCH_TIMEOUT", "30"))
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

def last_event_age_min(task):
    """任务最后一条事件距现在多少分钟（无事件返回 None）。"""
    last = None
    for f in glob.glob(f"{HOME}/log/*/*.md"):
        for line in open(f, encoding="utf-8"):
            if f"task:{task} " not in line and not line.rstrip().endswith(f"task:{task}"):
                continue
            m = re.search(r'\| ts:(\S+)', line)
            if m:
                try: last = max(last or 0, datetime.fromisoformat(m.group(1)).timestamp())
                except Exception: pass
    return (time.time() - last) / 60 if last else None

report = {"poll": "ok", "host": HOST, "stalled": [], "suspicious": [],
          "spawned": [], "held": [], "stale_live": 0}

# ---------- ② stalled 看门狗 ----------
todo_txt = open(f"{HOME}/board/todo.md", encoding="utf-8").read() \
    if os.path.exists(f"{HOME}/board/todo.md") else ""
inprog = []  # (task, owner_name)
ip = f"{HOME}/board/in-progress.md"
if os.path.exists(ip):
    for line in open(ip, encoding="utf-8"):
        m = re.match(r'^- (gt-[0-9a-f]+) — (\S+)', line.strip())
        if m: inprog.append((m.group(1), m.group(2).split("@")[0]))

for task, owner in inprog:
    age = last_event_age_min(task)
    if age is None: continue
    if age > CRIT:
        r = run("post.sh", ["--actor", WATCHDOG, "--project", "watchdog",
                            "--event", "diagnosed", "--task", task,
                            "--conclusion", f"stalled: 任务 {task} 已 {int(age)}min 无事件落账（阈值 {CRIT}min），认领者 {owner}",
                            "--mention", owner])
        report["stalled"].append({"task": task, "owner": owner, "age_min": int(age),
                                  "ok": r.returncode == 0})
    elif age > WARN:
        report["suspicious"].append({"task": task, "owner": owner, "age_min": int(age)})

# .live 滞留（派生会话超时不退）
now = time.time()
for f in glob.glob(f"{HOME}/raw/dispatches/*.live"):
    if (now - os.path.getmtime(f)) / 60 > LIVE_TIMEOUT:
        report["stale_live"] += 1

# ---------- ③ mention 拾取（目录存在性 = 机器归属；水位 = 邮件文件名，定宽时间戳字典序可比） ----------
try: state = json.load(open(STATE_F))
except Exception: state = {}

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

os.makedirs(os.path.dirname(STATE_F), exist_ok=True)
json.dump(state, open(STATE_F, "w"))
print(json.dumps(report, ensure_ascii=False))
PYEOF
