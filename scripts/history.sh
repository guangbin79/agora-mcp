#!/usr/bin/env bash
# history.sh — 输出某任务的完整事件链（agora_history 的实现）
# 入参：TASK=gt-xxxx
# 输出：{"task":"gt-xxxx","count":N,"events":[...事件...]}
# 顺序保证：shard 文件名（日期）排序 + shard 内物理行序 = 权威顺序
set -u
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"; export AGORA_HOME
[ -z "${TASK:-}" ] && { echo '{"error":"TASK_REQUIRED"}' >&2; exit 2; }

cd "$AGORA_HOME"
TASK="$TASK" python3 - <<'PYEOF'
import os, re, glob, json

HOME = os.environ["AGORA_HOME"]
TASK = os.environ["TASK"]
LINE_RE = re.compile(r'^- seq:(\d+) \| ts:(\S+) \| actor:(\S+) \| event:(\w+) \| idem:(\S+) \| seen:(\S+)(.*)$')
KV_RE = re.compile(r'(\w+):((?:[^|]|\|(?!\s*\w+:))*?)(?=\s*\|\s*\w+:|$)')

events = []
for f in sorted(glob.glob(f"{HOME}/log/*/*.md")):
    shard = os.path.relpath(f, HOME)
    for i, line in enumerate(open(f, encoding="utf-8"), 1):
        m = LINE_RE.match(line.strip())
        if not m: continue
        seq, ts, actor, event, idem, seen, rest = m.groups()
        fields = dict(KV_RE.findall(rest))
        if fields.pop("task", None) != TASK: continue
        events.append({"ref": f"{shard}:{i}", "seq": int(seq), "ts": ts,
                       "actor": actor, "event": event, "idem": idem,
                       **{k: v.strip() for k, v in fields.items() if v.strip()}})
print(json.dumps({"task": TASK, "count": len(events), "events": events}, ensure_ascii=False))
PYEOF
