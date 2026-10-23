#!/usr/bin/env bash
# runtime/opencode.sh —— opencode 服务 API 适配器（设计 §三 L2；契约：health/create/inject/alive/status）
# 全部经 `opencode api`；响应形状 {"data":…}／消息新者在前／outcome+time.idle 状态机（v2.1.2 openapi 实证，gt-d154）。
# spawn 契约＝create+inject 组合：dispatch 两段调用（create 惰性→落账→inject），保 LEDGER_FAILED→零工作不变量。
# AGORA_RUNTIME≠opencode 或本文件缺失时调用方整体旁路 API 面（stub/替代 runtime 零扰动）。
set -euo pipefail
CMD="${1:-}"; [ -n "$CMD" ] || { echo "usage: opencode.sh <health|create|inject|alive|status> ..." >&2; exit 2; }
# 单调用超时：服务僵死不拖垮调用方（post.sh flock 内也走本适配器，必须快速返回）
api() { timeout "${AGORA_API_TIMEOUT:-15}" opencode api "$@"; }
jget() { python3 -c "$1" 2>/dev/null; }

case "$CMD" in
  health)   # GET /api/info → rc0=API 可达
    api GET /api/info >/dev/null ;;
  create)   # create <dir> → stdout=sid（POST /api/session，location.directory=realpath）
    [ -n "${2:-}" ] || { echo "create: dir required" >&2; exit 2; }
    D=$(realpath "$2")
    BODY=$(python3 -c 'import json,sys;print(json.dumps({"title":"agora","location":{"directory":sys.argv[1]}}))' "$D")
    api POST /api/session -d "$BODY" | jget 'import json,sys;print(json.load(sys.stdin)["data"]["id"])' ;;
  inject)   # inject <sid> <text> → delivery:"queue" 即投即跑（rc0/1）
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "inject: sid text required" >&2; exit 2; }
    BODY=$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"delivery":"queue"}))' "$3")
    api POST "/api/session/$2/prompt" -d "$BODY" >/dev/null ;;
  alive)    # alive <dir> → rc0=该目录有活会话（active 表逐 sid 比 location.directory）
    [ -n "${2:-}" ] || { echo "alive: dir required" >&2; exit 2; }
    D=$(realpath "$2")
    SIDS=$(api GET /api/session/active | jget 'import json,sys;print(" ".join(json.load(sys.stdin)["data"].keys()))') || exit 1
    [ -n "$SIDS" ] || exit 1
    for s in $SIDS; do
      SD=$(api GET "/api/session/$s" | jget 'import json,sys;print(json.load(sys.stdin)["data"]["location"]["directory"])') || continue
      [ "$(realpath "$SD" 2>/dev/null)" = "$D" ] && exit 0
    done
    exit 1 ;;
  status)   # status <sid> → stdout=running|idle|dead（outcome=failed/interrupted 或不可达=dead；succeeded/time.idle=idle）
    [ -n "${2:-}" ] || { echo "status: sid required" >&2; exit 2; }
    api GET "/api/session/$2" | jget 'import json,sys
d=json.load(sys.stdin)["data"]
o=d.get("outcome")
if o in ("failed","interrupted"): print("dead")
elif o=="succeeded" or d.get("time",{}).get("idle"): print("idle")
else: print("running")' || { echo dead; exit 0; } ;;
  *) echo "unknown contract: $CMD" >&2; exit 2 ;;
esac
