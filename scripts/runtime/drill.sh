#!/usr/bin/env bash
# drill.sh —— 运行时扰动演练（T2，每周无人值守；dogfooding 计划 20261024-oc2-runtime-dogfood）：
# 四场景扰动打在真机械层上，断言韧性闭环，报告落本地 state（不触碰账本报告面——全程只经
# post/dispatch/cancel 真实通道落账，不伪造事件）。
# 退出码：0=全过 1=断言失败 2=忙碌让行（在飞波次在场，零扰动退出；自身会话任务 AGORA_TASK 豁免）
# 报告：$AGORA_DRILL_STATE/<ts>.json（缺省 ~/.local/state/agora-drill/）schema
#       {ts, scenario:[…], results:[{name,pass,detail}], skipped?}
# 场景（真实 restart 实证留 T5，本轮逻辑面由 smoke 用桩 runtime 验证）：
#   restart —— setsid 脱附重启 opencode 服务＋自身会话无伤＋health 回魂＋看门狗接管
#             （滞留 CRIT 诊断窗内按设计不可达——gt-f8ed 改验窗内事实锚：poll 轮次＋活性时钟重建）
#   kill    —— 杀派发子会话（pgid）→看门狗滞留诊断→reopened→恢复性重派→新会话 spawn（＋真实认领）
#   quota   —— 配额打满 dispatch fail-closed（rc8 零账本零 spawn 残留）→env 天然还原→复通
#   wave    —— 同窗口并发 3 派发：账本 3 派完整＋run log 齐全（无孤儿）＋会话互异＋无双认领
# 环境：AGORA_DRILL_STATE（报告与演练仓根）AGORA_DRILL_ACTOR（缺省 drill；实体页缺失时自举——
#       页属 drill 自身，先到先得口径）AGORA_DRILL_RESTART_CMD（缺省 "opencode service restart"）
#       AGORA_DRILL_HEALTH_WAIT（缺省 60s）AGORA_DRILL_CLAIM_WAIT（缺省 -1＝opencode 300s/桩 0s）
#       AGORA_DRILL_RESTART_TIMEOUT（重启命令超时秒，缺省 120；超时→health 如实记败不悬挂）
# 用法：drill.sh --scenario <restart|kill|quota|wave|all>
# shortcut: restart 真实执行未实证（T5）；API 通道子会话死亡无滞留档，kill/restart/wave 强制 run 通道建模
set -u
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——裸调用已禁用（静默错路径教训 gt-ca34）：export AGORA_HOME=$HOME/plaza 后重试，或经 MCP server env 注入}"
RUNTIME="${AGORA_RUNTIME:-opencode}"
RESTART_CMD="${AGORA_DRILL_RESTART_CMD:-opencode service restart}"
DRILL_STATE="${AGORA_DRILL_STATE:-$HOME/.local/state/agora-drill}"
ACTOR_BASE="${AGORA_DRILL_ACTOR:-drill}"   # 每场景追加 -<scen> 后缀（gt-f8ed 分域隔离）
ACTOR_NAME="$ACTOR_BASE"; ACTOR_PROJ=""; DREPO=""   # 由 provision(<scen>) 逐场景落定
PKG_SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"   # drill 同包 lib：广场 scripts 拷贝滞后时新 drill 必配同版 agora_lib（scan_tasks）
SERVER_PY="$(cd "$PKG_SCRIPTS/.." && pwd)/server/agora_mcp.py"   # --standalone 覆写用 agora server 绝对路径（同包自洽）
[[ -d "$AGORA_HOME/.git" ]] || { echo '{"code":"NO_FORUM","message":"AGORA_HOME 无仓库"}' >&2; exit 2; }

SCEN=""
while [[ $# -gt 0 ]]; do case "$1" in
  --scenario) SCEN="$2"; shift 2;;
  *) echo "usage: drill.sh --scenario <restart|kill|quota|wave|all>" >&2; exit 2;;
esac; done
case "$SCEN" in restart|kill|quota|wave|all) ;; *) echo "usage: drill.sh --scenario <restart|kill|quota|wave|all>" >&2; exit 2;; esac
case "$SCEN" in all) SCENS=(restart kill quota wave);; *) SCENS=("$SCEN");; esac

PASS=0; FAILS=0; SKIPPED=""
declare -a RESULTS=() TASKS=()
TS="$(date +%Y%m%dT%H%M%S)"
REPORT="$DRILL_STATE/$TS.json"

res() {  # res <名称> <1|0> <detail>：detail 折白防报告碎行
  local d; d=$(printf '%s' "$3" | tr '\t\n' '  ' | tr -s ' ')
  RESULTS+=("$(printf '%s\t%s\t%s' "$1" "$2" "$d")")
  [ "$2" = "1" ] && PASS=$((PASS+1)) || FAILS=$((FAILS+1))
}

finish() {  # 报告唯一写点（本地 state 面，非账本）
  local scen_json data
  scen_json=$(printf '%s\n' "${SCENS[@]}" | python3 -c 'import json,sys;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
  data=$(printf '%s\n' "${RESULTS[@]:-}")
  python3 -c '
import json, os, sys
out, scens, skipped, data = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3], sys.argv[4]
rep = {"ts": os.path.basename(out)[:-5], "scenario": scens, "results": []}
for ln in data.splitlines():
    if not ln: continue
    name, p, det = ln.split("\t", 2)
    rep["results"].append({"name": name, "pass": p == "1", "detail": det})
if skipped: rep["skipped"] = skipped
os.makedirs(os.path.dirname(out), exist_ok=True)
json.dump(rep, open(out, "w"), ensure_ascii=False, indent=1)
print(out)
' "$REPORT" "$scen_json" "${SKIPPED:-}" "$data"
}

dlev() {  # dlev <task> <event>：账本行检索（点分片伴生 glob——gt-3ea2 教训，跨分片核验禁裸 glob）
  cat "$AGORA_HOME"/log/*/*.md "$AGORA_HOME"/log/*/.*.md 2>/dev/null \
    | grep -E "(^|[|] )task:$1( |$)" | grep "event:$2"
}

cleanup() {  # 演练任务统一 cancel --kill：防 drill 孤儿在真广场刷恢复波次（保险丝：只在 EXIT 走一次）
  local pair a t
  for pair in "${TASKS[@]:-}"; do
    [ -n "$pair" ] || continue
    a="${pair% *}"; t="${pair#* }"   # TASKS 存 "actor task" 对——每场景独立分域（gt-f8ed）
    [ -n "$t" ] || continue   # mkdrilltask 失败的空 task 不进 cancel 自动推导档（终闸 B-F2）
    bash "$PKG_SCRIPTS/cancel.sh" --actor "$a" --task "$t" \
      --reason "drill 清场" --kill >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# ---------- 忙碌让行守卫（所有场景先跑）：复用 lib.scan_tasks（与 poll/重派同一真源）；
# 波次口径＝尾事件 dispatched，有意窄于 poll 的 inflight——done-unmerged 合并积压若计入，
# weekly drill 将永久让行失效（真实广场 22 任务积压实证，gt-ef4c 评审轮 1-F2 如实化） ----------
guard() {
  local busy
  busy=$(AGORA_HOME="$AGORA_HOME" PYTHONPATH="$PKG_SCRIPTS" python3 -c '
import os, sys
import agora_lib as lib
mine = (os.environ.get("AGORA_TASK") or "").strip()   # 自身会话任务豁免：派发链自身在飞不构成他扰
# 在飞波次口径＝尾事件仍为 dispatched（子会话在外无后续）。不用 inflight：done-unmerged 合并
# 积压被永久计入会让无人值守 drill 永久让行失效（真实广场 22 任务积压实证，gt-ef4c）
busy = sorted(t for t, d in lib.scan_tasks(sys.argv[1]).items()
              if d.get("last") == "dispatched" and t != mine)
print("\n".join(busy))' "$AGORA_HOME")
  if [ $? -ne 0 ]; then   # 扫描崩溃＝无法证明安静：fail-closed 让行（禁 fail-open 盲扰，真实广场旧 lib 实证）
    SKIPPED="guard scan failed（agora_lib.scan_tasks 不可用——广场 scripts 拷贝滞后于包？）"
    res "忙碌守卫扫描" 0 "$SKIPPED"
    finish
    echo "drill: $SKIPPED —— fail-closed 让行退出，零扰动" >&2
    exit 2
  fi
  if [ -n "$busy" ]; then
    SKIPPED="busy 在飞 dispatched 波次在场: $(echo "$busy" | tr '\n' ' ')"
    res "忙碌让行" 1 "$SKIPPED"
    finish
    echo "drill: $SKIPPED —— 让行退出，零扰动" >&2
    exit 2
  fi
}

provision() {  # provision <scen>：每场景独立 actor 分域＋fixture 仓＋实体页（gt-f8ed 场景隔离——
                # 共享仓路径令 kill 场景活子会话在场降级后续 dispatch，共享 actor 令配额互染）
  local scen="$1"
  ACTOR_NAME="$ACTOR_BASE-$scen"
  ACTOR_PROJ="$ACTOR_NAME@agora-drill-$scen"
  DREPO="$DRILL_STATE/agora-drill-$scen"
  mkdir -p "$DRILL_STATE"
  rm -rf "$DREPO"; mkdir -p "$DREPO"
  git -C "$DREPO" init -q 2>/dev/null
  git -C "$DREPO" -c user.name="$ACTOR_NAME" -c user.email="$ACTOR_NAME@local" \
    commit -q --allow-empty -m "drill fixture" 2>/dev/null
  local ent="$AGORA_HOME/wiki/entities/$ACTOR_NAME.md"
  if [ ! -f "$ent" ]; then
    printf -- '---\nname: %s\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$ACTOR_NAME" "$DREPO" > "$ent"
    (cd "$AGORA_HOME" && git add "wiki/entities/$ACTOR_NAME.md" \
      && AGORA_MECHANICAL=1 git -c user.name="$ACTOR_NAME" -c user.email="$ACTOR_NAME@local" \
         commit -qm "drill 实体自举（演练仓 $DREPO）") >/dev/null 2>&1 || true
  fi
}

mkdrilltask() {  # mkdrilltask <标题> → gt-id（verify 恒 true：演练任务无产出合同）
  TITLE="$1" VERIFY="true" PROJECT_DIR="$DREPO" AGORA_HOME="$AGORA_HOME" \
    bash "$PKG_SCRIPTS/task-create.sh" 2>/dev/null \
    | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p'
}

drill_dispatch() {  # drill_dispatch <task>：强制 run 通道（API 通道子会话死亡无滞留档，演练需 .live 锚点）
  DRILL_RC=0
  DRILL_OUT=$(AGORA_RUNTIME_API=0 bash "$PKG_SCRIPTS/dispatch.sh" --actor "$ACTOR_PROJ" \
    --project "$DREPO" --task "$1" 2>&1) || DRILL_RC=$?
}

drill_poll() {  # 快阈诊断轮（只诊不派）；输出落 POLL_OUT——cron poll 持锁 skip 也 exit 0，调用方须辨真轮
  POLL_OUT=$(AGORA_HOME="$AGORA_HOME" AGORA_ORPHAN_MIN=0 AGORA_DISPATCH_TIMEOUT=0 \
  AGORA_MERGE_WAIT_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_POLL_SPAWN=0 \
  AGORA_RUNTIME="$RUNTIME" bash "$PKG_SCRIPTS/poll.sh" 2>&1)
}

wait_diag() {  # wait_diag <task> <关键词>：poll 重试至诊断落账（poll.lock 被cron占用时静默跳过→重试）
  local i
  for i in 1 2 3; do
    drill_poll
    dlev "$1" diagnosed | grep -q "$2" && return 0
    sleep 1
  done
  return 1
}

kill_child() {  # kill_child <run路径>：进程组 kill（.live pgid；桩/长跑 runtime 的扰动锚点）
  local f="$AGORA_HOME/$1.live" pg
  [ -f "$f" ] || return 1
  pg=$(cat "$f")
  kill -- -"$pg" 2>/dev/null || true
  sleep 1
  ! kill -0 -"$pg" 2>/dev/null
}

claim_hop() {  # claim_hop <task>：真实 runtime 等子会话自认领；桩 runtime 由演练面代认领建模闭环
  local cw="${AGORA_DRILL_CLAIM_WAIT:--1}" i
  [ "$cw" -lt 0 ] && { [ "$RUNTIME" = "opencode" ] && cw=300 || cw=0; }
  if [ "$cw" -gt 0 ]; then
    for i in $(seq "$cw"); do
      dlev "$1" claimed | grep -q event:claimed && return 0
      sleep 1
    done
    return 1
  fi
  bash "$PKG_SCRIPTS/post.sh" --actor "$ACTOR_PROJ" --project agora-drill \
    --event claimed --task "$1" >/dev/null 2>&1
}

scen_restart() {
  provision restart
  local t; t=$(mkdrilltask "drill restart 场景：服务重启扰动"); TASKS+=("$ACTOR_PROJ $t")
  [ -n "$t" ] || { res "restart 建任务" 0 "task-create 无输出"; return; }
  drill_dispatch "$t"
  [ "$DRILL_RC" -eq 0 ] && grep -q '"mode":"spawned"' <<<"$DRILL_OUT" \
    && res "restart 首派 spawn（run 通道）" 1 "task=$t $DRILL_OUT" \
    || { res "restart 首派 spawn（run 通道）" 0 "task=$t rc=$DRILL_RC $DRILL_OUT"; return; }
  local run1; run1=$(sed -n 's/.*"run":"\([^"]*\)".*/\1/p' <<<"$DRILL_OUT")
  sleep 1   # 派发返回与子壳 .live 自删间的毫秒竞态兜底
  [ -f "$AGORA_HOME/$run1.live" ] || { res "restart 活子会话在场" 0 "子会话秒退，无扰动锚点"; return; }
  claim_hop "$t" || true   # 滞留档以 in-progress 为门：真实 runtime 等子会话自认领，桩 runtime 演练面代认领
  # 扰动：setsid 脱附重启（重启命令不随 drill 进程组死；自身 PID 交由重启钩子排除）
  local my_sid rsid out
  my_sid=$(ps -o sid= -p $$ | tr -d ' ')
  out=$(AGORA_DRILL_MY_PID=$$ AGORA_DRILL_RESTART_CMD="$RESTART_CMD" \
    AGORA_DRILL_RESTART_TIMEOUT="${AGORA_DRILL_RESTART_TIMEOUT:-120}" setsid bash -c \
    'echo "drill_rsid=$(ps -o sid= -p $$ | tr -d " ")"; timeout "$AGORA_DRILL_RESTART_TIMEOUT" bash -c "$AGORA_DRILL_RESTART_CMD"' 2>&1)
  rsid=$(sed -n 's/drill_rsid=//p' <<<"$out" | head -1)
  [ -n "$rsid" ] && [ "$rsid" != "$my_sid" ] \
    && res "restart setsid 脱附" 1 "drill_sid=$my_sid restart_sid=$rsid" \
    || res "restart setsid 脱附" 0 "drill_sid=$my_sid restart_sid=${rsid:-空} $out"
  kill -0 "$$" 2>/dev/null && res "restart 自身会话无伤" 1 "pid $$ 存活" \
    || res "restart 自身会话无伤" 0 "pid $$ 死亡"
  # 服务回魂：opencode 走适配器 health；其余 runtime 以 --version 为可达代理
  local hw="${AGORA_DRILL_HEALTH_WAIT:-60}" i hok=1
  for i in $(seq "$hw"); do
    if [ "$RUNTIME" = "opencode" ] && [ -f "$PKG_SCRIPTS/runtime/opencode.sh" ]; then
      bash "$PKG_SCRIPTS/runtime/opencode.sh" health >/dev/null 2>&1 && { hok=0; break; }
    else
      "$RUNTIME" --version >/dev/null 2>&1 && { hok=0; break; }
    fi
    sleep 1
  done
  res "restart 服务回魂（health）" $((1-hok)) "等待 ${i:-0}s"
  # 看门狗接管（gt-f8ed 合同 a）：服务重启杀在飞子会话（真实 runtime 已杀；桩 runtime 补刀建模同形状）。
  # 滞留 diagnosed 窗内按设计不可达（阈值 CRIT 缺省 40min，WARN 20min 仅报表）——改验窗内事实锚：poll 轮次正常运转＋任务活性时钟重建。
  kill_child "$run1" || true
  local i pok=0
  for i in 1 2 3; do   # cron poll 持锁 skip 也 exit 0——重试至真轮（wait_diag 同款 3 次口径，gt-f8ed 终闸 A/B）
    drill_poll
    grep -q '"poll": *"ok"' <<<"$POLL_OUT" && { pok=1; break; }
    sleep 20
  done
  res "restart 后 poll 轮次正常运转" $pok \
    "第${i}次 $(grep -o '"poll": *"[a-z]*"' <<<"$POLL_OUT" | head -1)"
  local clk
  clk=$(AGORA_HOME="$AGORA_HOME" python3 - "$t" <<'PYEOF'
import json, sys, time, os
try:
    st = json.load(open(os.path.join(os.environ["AGORA_HOME"], ".git", "poll-state.json")))
    e = st.get("_activity", {}).get(sys.argv[1])
    if not isinstance(e, dict): print("absent"); raise SystemExit
    age = int(time.time() - float(e.get("since", 0)))
    print(("fresh %ds last_ref=%s" % (age, e.get("last_ref"))) if age <= 600 else f"stale {age}s")
except Exception as exc:
    print(f"err {exc}")
PYEOF
)
  case "$clk" in fresh*) res "restart 任务活性时钟重建" 1 "task=$t $clk";;
    *) res "restart 任务活性时钟重建" 0 "task=$t $clk";; esac
}

scen_kill() {
  provision kill
  local t; t=$(mkdrilltask "drill kill 场景：杀子会话恢复闭环"); TASKS+=("$ACTOR_PROJ $t")
  [ -n "$t" ] || { res "kill 建任务" 0 "task-create 无输出"; return; }
  drill_dispatch "$t"
  [ "$DRILL_RC" -eq 0 ] && grep -q '"mode":"spawned"' <<<"$DRILL_OUT" \
    && res "kill 首派 spawn（run 通道）" 1 "task=$t $DRILL_OUT" \
    || { res "kill 首派 spawn（run 通道）" 0 "task=$t rc=$DRILL_RC $DRILL_OUT"; return; }
  local sid1 run1
  run1=$(sed -n 's/.*"run":"\([^"]*\)".*/\1/p' <<<"$DRILL_OUT")
  sid1=$(dlev "$t" dispatched | sed -n 's/.*| session:\([^ |]*\).*/\1/p' | tail -1)
  sleep 1
  [ -f "$AGORA_HOME/$run1.live" ] || { res "kill 活子会话在场" 0 "子会话秒退（秒退 runtime 无法演练 kill）"; return; }
  claim_hop "$t" && res "kill 首派认领" 1 "task=$t" \
    || { res "kill 首派认领" 0 "task=$t 无认领（真实 runtime 超时）"; return; }
  # 扰动：进程组杀子会话
  kill_child "$run1" && res "kill 扰动注入（进程组）" 1 "run=$run1" \
    || { res "kill 扰动注入（进程组）" 0 "run=$run1 进程组仍活"; return; }
  # 闭环①：看门狗滞留诊断
  wait_diag "$t" "滞留" && res "kill 看门狗滞留诊断" 1 "task=$t" \
    || { res "kill 看门狗滞留诊断" 0 "task=$t 无滞留诊断"; return; }
  # 闭环②：恢复性重派（redispatch.sh 对在飞拒绝——按派单方语义 reopened 回池再派，全真实通道）
  bash "$PKG_SCRIPTS/post.sh" --actor "$ACTOR_PROJ" --project agora-drill \
    --event reopened --task "$t" --reason "drill kill 闭环：恢复性重派" >/dev/null 2>&1
  drill_dispatch "$t"
  [ "$DRILL_RC" -eq 0 ] && grep -q '"mode":"spawned"' <<<"$DRILL_OUT" \
    && res "kill 恢复性重派 spawn" 1 "$DRILL_OUT" \
    || { res "kill 恢复性重派 spawn" 0 "rc=$DRILL_RC $DRILL_OUT"; return; }
  local ndisp sid2
  ndisp=$(dlev "$t" dispatched | grep -c event:dispatched)
  sid2=$(dlev "$t" dispatched | sed -n 's/.*| session:\([^ |]*\).*/\1/p' | tail -1)
  [ "$ndisp" -eq 2 ] && [ -n "$sid2" ] && [ "$sid2" != "$sid1" ] \
    && res "kill 闭环：新会话互异（2 派 2 sid）" 1 "sid $sid1→$sid2" \
    || res "kill 闭环：新会话互异（2 派 2 sid）" 0 "ndisp=$ndisp sid $sid1→$sid2"
  claim_hop "$t" && res "kill 闭环：新会话认领" 1 "task=$t" \
    || res "kill 闭环：新会话认领" 0 "task=$t 重派后无认领"
}

scen_quota() {
  provision quota
  local t; t=$(mkdrilltask "drill quota 场景：配额闸 fail-closed"); TASKS+=("$ACTOR_PROJ $t")
  [ -n "$t" ] || { res "quota 建任务" 0 "task-create 无输出"; return; }
  local before_live after_live ndisp1 ndisp2 out rc
  before_live=$(find "$AGORA_HOME/raw/dispatches" -name '*.live' 2>/dev/null | wc -l)
  # A：配额打满 → dispatch 必须 fail-closed（rc8 QUOTA_EXCEEDED；锁内外双闸都打满）
  out=$(AGORA_MAX_SPAWN=0 AGORA_MAX_SPAWN_GLOBAL=0 bash "$PKG_SCRIPTS/dispatch.sh" \
    --actor "$ACTOR_PROJ" --project "$DREPO" --task "$t" 2>&1); rc=$?
  [ "$rc" -eq 8 ] && grep -q QUOTA_EXCEEDED <<<"$out" \
    && res "quota fail-closed rc8" 1 "task=$t $out" \
    || res "quota fail-closed rc8" 0 "task=$t rc=$rc $out"
  # 零残留：账本零 dispatched＋零新 .live（trap 兜底：env 钳制随子进程天然还原）
  ndisp1=$(dlev "$t" dispatched | grep -c event:dispatched)
  after_live=$(find "$AGORA_HOME/raw/dispatches" -name '*.live' 2>/dev/null | wc -l)
  [ "$ndisp1" -eq 0 ] && [ "$after_live" -eq "$before_live" ] \
    && res "quota fail-closed 零残留" 1 "dispatched=0 .live $before_live→$after_live" \
    || res "quota fail-closed 零残留" 0 "dispatched=$ndisp1 .live $before_live→$after_live"
  # B：还原后复通——spawned 为正道；notified＝目标仓在场委托会话的合规通知降级，接受但显式记录原因
  out=$(bash "$PKG_SCRIPTS/dispatch.sh" --actor "$ACTOR_PROJ" --project "$DREPO" --task "$t" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && grep -q '"mode":"spawned"' <<<"$out"; then
    res "quota 复通 dispatch spawned" 1 "$out"
  elif [ "$rc" -eq 0 ] && grep -q '"mode":"notified"' <<<"$out"; then
    res "quota 复通 dispatch spawned" 1 "合规降级 notified：目标仓在场委托会话走通知通道（非配额/闸拒绝） $out"
  else
    res "quota 复通 dispatch spawned" 0 "rc=$rc $out"
  fi
}

scen_wave() {
  provision wave
  local t; t=$(mkdrilltask "drill wave 场景：同窗 3 并发派发"); TASKS+=("$ACTOR_PROJ $t")
  [ -n "$t" ] || { res "wave 建任务" 0 "task-create 无输出"; return; }
  local i pids=()
  for i in 1 2 3; do
    ( bash "$PKG_SCRIPTS/dispatch.sh" --actor "$ACTOR_PROJ" --project "$DREPO" \
        --task "$t" >"$DRILL_STATE/wave-$i.out" 2>&1; echo $? >"$DRILL_STATE/wave-$i.rc" ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  local okn=0
  for i in 1 2 3; do
    [ "$(cat "$DRILL_STATE/wave-$i.rc")" = "0" ] \
      && grep -q '"mode":"spawned"' "$DRILL_STATE/wave-$i.out" && okn=$((okn+1))
  done
  res "wave 3 并发派发全成" $([ "$okn" -eq 3 ] && echo 1 || echo 0) "task=$t success=$okn/3"
  local ndisp runs nruns missing=0 r
  ndisp=$(dlev "$t" dispatched | grep -c event:dispatched)
  runs=$(dlev "$t" dispatched | sed -n 's/.*| run:\([^ |]*\).*/\1/p' | sort -u)
  nruns=$(printf '%s\n' "$runs" | grep -c .)
  for r in $runs; do [ -f "$AGORA_HOME/$r" ] || missing=1; done
  res "wave 账本 3 派＋run log 齐全（无孤儿）" \
    $([ "$ndisp" -eq 3 ] && [ "$nruns" -eq 3 ] && [ "$missing" -eq 0 ] && echo 1 || echo 0) \
    "dispatched=$ndisp runs=$nruns missing=$missing"
  local nsid
  nsid=$(dlev "$t" dispatched | sed -n 's/.*| session:\([^ |]*\).*/\1/p' | sort -u | grep -c .)
  res "wave 会话互异（无双生会话）" $([ "$nsid" -eq 3 ] && echo 1 || echo 0) "sids=$nsid"
  drill_poll   # 快阈诊断轮后不得出现第 4 派（无孤儿档复活波）
  ndisp=$(dlev "$t" dispatched | grep -c event:dispatched)
  res "wave 无孤儿复活波" $([ "$ndisp" -eq 3 ] && echo 1 || echo 0) "poll 后 dispatched=$ndisp"
  # 无双认领：认领至多一个干净持有人（桩 runtime 零认领；真实并发认领必须有冲突派生兜住）
  local nclaim conflicts
  nclaim=$(dlev "$t" claimed | grep -c event:claimed)
  conflicts=$(grep -l "$t" "$AGORA_HOME/board/conflicts.md" 2>/dev/null | wc -l)
  { [ "$nclaim" -le 1 ] || [ "$conflicts" -gt 0 ]; } \
    && res "wave 无双认领" 1 "claimed=$nclaim conflicts=$conflicts" \
    || res "wave 无双认领" 0 "claimed=$nclaim conflicts=$conflicts"
}

guard

# ---------- --standalone 隔离（gt-7cd9 根因①）：service 模式下子会话工具在常驻服务进程内执行，
# opencode.json mcp.agora.environment 钉死的 AGORA_HOME 压过 spawn 进程 env——沙箱会话 agora MCP
# 全指主广场（anon@proj 污染名册十一例实证）。review-loop e2e 先例：--standalone 私有 server＝
# 独立 env＋独立 MCP；2026-10-26 /proc 实证纯 --standalone 下 config pin 仍胜子会话进程 env，
# 故并辅 OPENCODE_CONFIG_CONTENT 同键覆写（合成形状 mcp.<name> 实证可覆盖全局 servers 形状）。
# 只作用于 spawn 面（包装 runtime 交 dispatch）；poll/health 面维持原 RUNTIME。busy 让行先行，零扰动不落盘。
DRILL_BIN="$DRILL_STATE/bin"; mkdir -p "$DRILL_BIN"
WRAP="$DRILL_BIN/runtime-standalone.sh"
cat > "$WRAP" <<EOF
#!/usr/bin/env bash
# drill 专用 runtime 包装（gt-7cd9）：run 子命令注入 --standalone（私有 server＝子会话进程 env 生效）
if [ "\$1" = "run" ]; then shift; exec "$RUNTIME" run --standalone "\$@"; fi
exec "$RUNTIME" "\$@"
EOF
chmod +x "$WRAP"
export AGORA_RUNTIME="$WRAP"
if [ -f "$SERVER_PY" ]; then   # server 缺席（畸形安装）时跳过覆写，包装层隔离仍在
  export OPENCODE_CONFIG_CONTENT="$(RUNTIME="$RUNTIME" AGORA_HOME="$AGORA_HOME" SERVER_PY="$SERVER_PY" python3 -c '
import json, os, sys
print(json.dumps({"mcp": {"agora": {
    "type": "local",
    "command": ["python3", os.environ["SERVER_PY"]],
    "environment": {"AGORA_HOME": os.environ["AGORA_HOME"]},
    "disabled": False,
}}}))')"
fi

for SCEN in "${SCENS[@]}"; do
  case "$SCEN" in
    restart) scen_restart;;
    kill)    scen_kill;;
    quota)   scen_quota;;
    wave)    scen_wave;;
  esac
done
finish
echo "drill: $PASS 过 / $FAILS 败 —— $REPORT"
[ "$FAILS" -eq 0 ]
