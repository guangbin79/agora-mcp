#!/usr/bin/env bash
# pending-sessions.sh —— 重启前挂起盘点（gt-575d B1）：opencode service restart 会杀 spawned worker
# （gt-3c7e＋gt-6bef 前身两次实证）。dispatcher 重启前必查：列出「sessions.map 在册（本机）＋
# 有未终态任务」的会话清单。盘点是辅助决策非自动阻止（任务页边界条款）——退出码恒 0，
# 清单为空即可安全重启；JOIN 键＝dispatched 事件的 session: 字段（gt-2845③ 起两通道统一承载）。
# 用法: pending-sessions.sh   （env: AGORA_HOME 必填，gt-ca34 契约）
set -euo pipefail
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——export AGORA_HOME=\$HOME/plaza 后重试，或经 MCP server env 注入}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONPATH="$SCRIPTS_DIR" python3 - "$AGORA_HOME" "$(hostname)" <<'PYEOF'
import glob, os, re, sys
from datetime import datetime

home, host = sys.argv[1], sys.argv[2]
smap = os.path.join(home, "sessions.map")
rows = []   # (entity, sid, ts)
if os.path.exists(smap):
    for ln in open(smap, encoding="utf-8", errors="replace").read().splitlines():
        if ln.startswith("#"):
            continue
        p = ln.split()
        if len(p) >= 4 and p[0] == host:
            rows.append((p[1], p[2], p[3]))

# 账本扫描：任务最新 dispatched 的 session 与终态集（与 dispatch.sh ledger_scan 同口径）
disp_sid, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        continue
    for line in lines:
        if "event:" not in line:
            continue
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m:
            continue
        t = m.group(1)
        if "event:dispatched" in line:
            sm = re.search(r"\| session:(\S+)", line)
            if sm:
                disp_sid[t] = sm.group(1)   # 文件序+行序，后见覆盖＝最新派发
        elif any(f"event:{e}" in line for e in ("done", "merged", "cancelled")):
            terminal.add(t)

by_sid = {}
for t, sid in disp_sid.items():
    if t not in terminal:
        by_sid.setdefault(sid, []).append(t)

now = datetime.now().astimezone()
pending = []
for ent, sid, ts in rows:
    tasks = sorted(by_sid.get(sid, []))
    age = ""
    try:
        age = f"{(now - datetime.fromisoformat(ts)).total_seconds()/60:.0f}min"
    except Exception:
        pass
    if tasks:
        pending.append((ent, sid, age, tasks))

print(f"== 重启前挂起盘点（host={host} {now.isoformat(timespec='seconds')}）==")
print(f"sessions.map 在册（本机）: {len(rows)} 会话；有未终态任务: {len(pending)}")
if not pending:
    print("全部在册会话无未终态任务——可安全重启")
for ent, sid, age, tasks in pending:
    print(f"  {ent}  {sid}  在册{age}  未终态: {' '.join(tasks)}")
PYEOF
