#!/usr/bin/env bash
# task-routing.sh —— task→role→sid 亲和映射（task-routing）单源写面（gt-236a）
# 用法:
#   task-routing.sh upsert <gt-xxxx> <dispatcher|worker> <entity> <sid>   # 按 (task,role) 原位刷 sid+ts，缺行追加
#   task-routing.sh get  <gt-xxxx> <dispatcher|worker>                    # stdout=sid（空串=无行）
# 行格式: <task> <role> <entity> <sid> <ts>
# 存储 $AGORA_HOME/.git/task-routing —— 本机状态域（sid 无跨机语义，.git 内天然不入账本不同步；与 notify-wm 同域）。
# 写入方: enforcer 插件（execFileP，采集三件 gt-236a）＋dispatch.sh（spawn 顺带）；消费方: notify-opencode.sh（只读）。
# 信任边界: 写侧只做行完整性校验（防空白/控制字符撕裂行），伪造面同 sessions.map——消费端白名单＋who 鉴别双闸兜底（gt-893a 契约①）。
set -euo pipefail
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——export AGORA_HOME=\$HOME/plaza 后重试，或经 MCP server env 注入}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-}"; TASK="${2:-}"; ROLE="${3:-}"; ENT="${4:-}"; SID="${5:-}"
[[ "$TASK" =~ ^gt-[0-9a-f]{4,}$ ]] || { echo '{"code":"VALIDATION_FAILED","message":"task 非 gt-xxxx 形态"}' >&2; exit 2; }
[[ "$ROLE" == dispatcher || "$ROLE" == worker ]] || { echo '{"code":"VALIDATION_FAILED","message":"role 须 dispatcher/worker"}' >&2; exit 2; }
RF="$AGORA_HOME/.git/task-routing"
mkdir -p "$AGORA_HOME/.git" 2>/dev/null || true
case "$CMD" in
  upsert)
    [[ $# -eq 5 ]] || { echo '{"code":"VALIDATION_FAILED","message":"upsert 需 task role entity sid 四参"}' >&2; exit 2; }
    for v in "$ENT" "$SID"; do
      [[ "$v" =~ ^[^[:space:][:cntrl:]]{1,128}$ ]] || { echo '{"code":"VALIDATION_FAILED","message":"entity/sid 含空白/控制字符或超 128（routing 行伪造面），拒绝"}' >&2; exit 2; }
    done
    (
      flock -w "${AGORA_LOCK_WAIT:-5}" 9 || { echo '{"code":"LOCK_TIMEOUT","message":"task-routing 锁忙"}' >&2; exit 4; }
      PYTHONPATH="$SCRIPTS_DIR" python3 - "$RF" "$TASK" "$ROLE" "$ENT" "$SID" <<'PYEOF'
import sys, os
from datetime import datetime
rf, task, role, ent, sid = sys.argv[1:6]
lines = open(rf, encoding="utf-8").read().splitlines() if os.path.exists(rf) else []
row = f"{task} {role} {ent} {sid} {datetime.now().astimezone().isoformat(timespec='seconds')}"
idx = next((i for i, l in enumerate(lines)
            if not l.startswith("#") and len(l.split()) >= 4 and l.split()[:2] == [task, role]), None)
if idx is None:
    lines.append(row)
else:
    lines[idx] = row
tmp = rf + ".tmp"   # 原子写（locale-validation-contract）：异常只留旧表
open(tmp, "w", encoding="utf-8").write("\n".join(lines) + "\n")
os.replace(tmp, rf)
print(row)
PYEOF
    ) 9>"$AGORA_HOME/.git/task-routing.lock"
    ;;
  get)
    [[ $# -eq 3 ]] || { echo '{"code":"VALIDATION_FAILED","message":"get 需 task role 两参"}' >&2; exit 2; }
    awk -v t="$TASK" -v r="$ROLE" '!/^#/ && $1==t && $2==r {print $4; exit}' "$RF" 2>/dev/null || true
    ;;
  *) echo '{"code":"VALIDATION_FAILED","message":"unknown subcommand（upsert/get）"}' >&2; exit 2 ;;
esac
