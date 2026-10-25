#!/usr/bin/env bash
# runtime/opencode.sh —— opencode 服务 API 适配器（设计 §三 L2；契约：health/create/inject/alive/status/who/abort）
# 全部经 `opencode api`；响应形状 {"data":…}／消息新者在前／outcome+time.idle 状态机（v2.1.2 openapi 实证，gt-d154）。
# spawn 契约＝create+inject 组合：dispatch 两段调用（create 惰性→落账→inject），保 LEDGER_FAILED→零工作不变量。
# abort（C 二期 gt-0a34 spike）：POST /api/session/{id}/interrupt（v2.1.2 openapi 实证在场）——cancel --kill 的 API 会话中断面。
# AGORA_RUNTIME≠opencode 或本文件缺失时调用方整体旁路 API 面（stub/替代 runtime 零扰动）。
set -euo pipefail
CMD="${1:-}"; [ -n "$CMD" ] || { echo "usage: opencode.sh <health|create|inject|alive|status|abort> ..." >&2; exit 2; }
# 单调用超时：服务僵死不拖垮调用方（post.sh flock 内也走本适配器，必须快速返回）
api() { timeout "${AGORA_API_TIMEOUT:-15}" opencode api "$@"; }
jget() { python3 -c "$1" "${@:2}" 2>/dev/null; }

case "$CMD" in
  health)   # GET /api/info → rc0=API 可达
    api GET /api/info >/dev/null ;;
  create)   # create <dir> [title] → stdout=sid（POST /api/session，location.directory=realpath；title 缺省 agora）
    [ -n "${2:-}" ] || { echo "create: dir required" >&2; exit 2; }
    D=$(realpath "$2")
    BODY=$(python3 -c 'import json,sys;print(json.dumps({"title":sys.argv[1],"location":{"directory":sys.argv[2]}}))' "${3:-agora}" "$D")
    api POST /api/session -d "$BODY" | jget 'import json,sys;print(json.load(sys.stdin)["data"]["id"])' ;;
  inject)   # inject <sid> <text> → delivery:"queue" 即投即跑（rc0/1）
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "inject: sid text required" >&2; exit 2; }
    BODY=$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1],"delivery":"queue"}))' "$3")
    api POST "/api/session/$2/prompt" -d "$BODY" >/dev/null ;;
  alive)    # alive <dir> [delegated] → rc0=该目录有活会话；delegated 仅认「运行中」委托子会话（title 前缀 "agora: gt-" ∧ status=running——done/idle/dead 残留不算在场 gt-762a；title 机械锚 gt-2845②；交互会话占坑不算在场 gt-0ed3）
    [ -n "${2:-}" ] || { echo "alive: dir required" >&2; exit 2; }
    case "${3:-}" in ""|delegated) ;; *) echo "alive: unknown flag: $3" >&2; exit 2 ;; esac   # ocr：拼错标志静默退宽语义＝本任务要消灭的行为类，必须响
    D=$(realpath "$2")
    SIDS=$(api GET /api/session/active | jget 'import json,sys;print(" ".join(json.load(sys.stdin)["data"].keys()))') || exit 1
    [ -n "$SIDS" ] || exit 1
    for s in $SIDS; do
      if ! J=$(api GET "/api/session/$s"); then
        [ "${3:-}" = delegated ] && exit 0   # 893a 同口径：status 不可达退回尽力在场，宁 notified 不重复 spawn
        continue
      fi
      printf '%s' "$J" | jget 'import json,sys,os
d=json.load(sys.stdin)["data"]
loc=(d.get("location") or {}).get("directory") or ""
hit = bool(loc) and os.path.isdir(loc) and os.path.realpath(loc) == os.path.realpath(sys.argv[1])
if hit and sys.argv[2] == "delegated":
  if not (d.get("title") or "").startswith("agora: gt-"): hit = False
  elif d.get("outcome") in ("failed","interrupted","succeeded") or d.get("time",{}).get("idle"): hit = False   # gt-762a：仅 running 在场，done 残留（succeeded/idle）与 dead 不算
print("hit" if hit else "")' "$D" "${3:-}" | grep -q hit && exit 0
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
  who)      # who <sid> → stdout=interactive|dead|delegated（rc0）；rc1=不可达。实体信只投顶层 live 会话：
            # delegated＝派生 worker（parentID 在场＝subagent 派生；title "agora: gt-" 前缀＝dispatch 派生），
            # dead＝outcome failed/interrupted（存储持久化致崩溃会话仍可 API 可达，gt-893a）
    [ -n "${2:-}" ] || { echo "who: sid required" >&2; exit 2; }
    api GET "/api/session/$2" | jget 'import json,sys
d=json.load(sys.stdin)["data"]
o=d.get("outcome")
if o in ("failed","interrupted"): print("dead")
elif d.get("parentID") or (d.get("title") or "").startswith("agora: gt-"): print("delegated")
else: print("interactive")' || exit 1 ;;
  abort)    # abort <sid> → POST /api/session/$sid/interrupt（rc0=中断受理；C 二期 gt-0a34 第六契约）
    [ -n "${2:-}" ] || { echo "abort: sid required" >&2; exit 2; }
    api POST "/api/session/$2/interrupt" >/dev/null ;;
  *) echo "unknown contract: $CMD" >&2; exit 2 ;;
esac
