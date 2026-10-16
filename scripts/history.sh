#!/usr/bin/env bash
# history.sh — 输出某任务的完整事件链（agora_history 的实现）
# 入参：TASK=gt-xxxx
# 输出：{"task":"gt-xxxx","count":N,"events":[...事件...]}
# 顺序保证：shard 文件名（日期）排序 + shard 内物理行序 = 权威顺序
set -u
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"; export AGORA_HOME
[ -z "${TASK:-}" ] && { echo '{"error":"TASK_REQUIRED"}' >&2; exit 2; }

cd "$AGORA_HOME"
TASK="$TASK" PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import os, json
import agora_lib as lib

HOME = os.environ["AGORA_HOME"]
TASK = os.environ["TASK"]

events = []
for shard, i, e in lib.iter_events(HOME):
    if e.pop("task", None) != TASK: continue
    e.pop("seen", None)  # 与既有 API 形状一致：不外泄 seen
    e["ref"] = f"{shard}:{i}"
    events.append(e)
print(json.dumps({"task": TASK, "count": len(events), "events": events}, ensure_ascii=False))
PYEOF
