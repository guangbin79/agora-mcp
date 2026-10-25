#!/usr/bin/env bash
# notify-opencode.sh —— 规格 §8.1 通知桥：监听 inbox/ → 向运行中的 opencode v2 会话注入提醒
#
# 用法: nohup bash notify-opencode.sh >/dev/null 2>&1 &   （或 systemd --user）
#       notify-opencode.sh --once   扫一轮就退（测试/调试）
# 环境:
#   AGORA_NOTIFY_DEBOUNCE_S  同 (entity,sid) 去抖秒数（默认 60，持久化在 .git/notify-wm/，重启不重置）
#   AGORA_NOTIFY_POLL_S      无 inotifywait 时的轮询间隔（默认 5 秒）
#   AGORA_NOTIFY_MODE        opencode（默认）| desktop（notify-send 桌面通知，零开发兜底）
#   AGORA_SESSION_TTL_H      桥侧活性闸小时数（缺省 24，与 register --check-only/poll 保洁同源；<=0=不限）
# 行为契约（规格 §8.1；gt-893a 修订；gt-236a 两层路由）：
#   - 只递提醒不递内容：消息体只含 ref 指针，正文由 agent 主动 agora_check_mail 拉取
#   - 两层路由：精准层 task-routing (task,role)→sid 定向注入（单点，不广播——2508 正解）；
#     定向失败（缺行/白名单拒/dead/delegated/inject rc!=0）逐级落兜底广播——同实体全部 ts
#     新鲜行逐 (entity,sid) 注入（双收）；去抖按 (entity,sid)
#   - 角色过滤（兜底层行级）：worker 行仅收派发/修正类，dispatcher 行仅收终态/计划类，
#     无 role 列 legacy 行全收＝现状不劣化；progress 心跳设计内不注入（落箱不推醒）
#   - 查不到 sessions.map 映射（会话未在跑）静默跳过；全路径落痕 .git/notify-debug.log
#   - 丢不得：全部候选失败不静默——失败计数 .git/notify-wm/<ent>.fail＋水位不推进（下轮重试，
#     去抖防风暴）；成功清零
#   - 投递方式 delivery=queue：不打断正在跑的回合，空闲会话入队即唤起
set -uo pipefail
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——裸调用已禁用（静默错路径教训 gt-ca34）：export AGORA_HOME=$HOME/plaza 后重试，或经 MCP server env 注入}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 单源自定位：兄弟脚本/库一律本仓 scripts（gt-f6e4）
DEBOUNCE="${AGORA_NOTIFY_DEBOUNCE_S:-60}"
POLL_S="${AGORA_NOTIFY_POLL_S:-5}"
MODE="${AGORA_NOTIFY_MODE:-opencode}"
WM_DIR="$AGORA_HOME/.git/notify-wm"; mkdir -p "$WM_DIR"
DBG_LOG="$AGORA_HOME/.git/notify-debug.log"
HOST="$(hostname)"

# 角色映射表常量（gt-236a 唯一源；task-routing.sh 头注同源指回此处）
DISPATCHER_EVENTS="claimed plan done blocked cancelled diagnosed escalated proposal"  # 终态/异常/计划类
WORKER_EVENTS="dispatched ack amended reopened"                                        # 派发/修正类
NO_INJECT_EVENTS="progress"                                                            # 心跳落箱不推醒（seq34 设计内不注入）

dbg() { # $1=entity $2=sid $3=事件——排查落痕（gt-893a：此前零落痕，打偏一周无从定位）
  printf '%s entity=%s sid=%s %s\n' "$(date -Is)" "$1" "${2:--}" "$3" >> "$DBG_LOG" 2>/dev/null || :
}

bump_fail() { # $1=entity——失败计数累加；读值 sanitize（gt-893a 评审 B1：损坏计数文件不得以 set -u 展开错杀 daemon）
  local n; n=$(cat "$WM_DIR/$1.fail" 2>/dev/null || echo 0)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo $(( n + 1 )) > "$WM_DIR/$1.fail"
}

evt_in() { # $1=事件清单 $2=事件；字面比对（R2#3：[[ == ]] 右侧未引号展开＝glob 元字符注入面，信件是不可信共享文本）；空事件恒假
  local w
  [[ -n "${2:-}" ]] || return 1
  for w in $1; do [[ "$w" == "$2" ]] && return 0; done
  return 1
}

notify() { # $1=entity $2=ref $3=event $4=task → rc0=投递成功/设计内跳过；rc1=投递失败（scan 不推进水位）
  local ent="$1" ref="$2" ev="${3:-}" task="${4:-}"
  local now raw cands bad w sid ts rowrole kind pick="" tse
  local rrole="" routed="" debounce_hit=0 injectable=0 delivered=0
  now=$(date +%s)
  evt_in "$NO_INJECT_EVENTS" "$ev" && { dbg "$ent" "-" "progress-silent ev=$ev"; return 0; }
  # sessions.map 本机条目：<host> <agent> <session> <ts> [role]；同实体多 sid 兜底广播全活行。
  raw=$(awk -v h="$HOST" -v e="$ent" '$1==h && $2==e {n++} END{print n+0}' \
      "$AGORA_HOME/sessions.map" 2>/dev/null)
  if [[ -z "$raw" || "$raw" == 0 ]]; then   # -z＝map 文件缺失（awk rc2 无 END），同归设计内静默
    dbg "$ent" "-" "skip no-map-entry"   # 会话未在跑＝设计内静默（不算失败）
    return 0
  fi
  # 精准层：task-routing 亲和 (task,role)→sid；方向表定 role（角色映射表常量见文件头）
  if [[ -n "$task" ]]; then
    if evt_in "$DISPATCHER_EVENTS" "$ev"; then rrole=dispatcher
    elif evt_in "$WORKER_EVENTS" "$ev"; then rrole=worker; fi
    [[ -n "$rrole" ]] && routed=$(bash "$SCRIPTS_DIR/task-routing.sh" get "$task" "$rrole" 2>/dev/null || true)
    # 实体匹配（R2#2）：routing 行 (task,role) 全局唯一，信件收件实体≠行实体（如 watchdog diagnosed
    # 同时 mention owner,disp）时视为无行——落兜底广播，禁跨实体误投＋禁 kind=R 单点吞掉真收件人
    if [[ -n "$routed" ]]; then
      read -r rt_ent routed <<< "$routed"
      [[ "$rt_ent" == "$ent" ]] || { dbg "$ent" "$rt_ent" "skip routed-entity-mismatch task=$task"; routed=""; }
    fi
    # 精准层同过消费端白名单硬闸（C 册实弹：写侧完整性校验放行 / 与点段，routed sid 逐字进
    # API URL 与 debounce 文件路径——../ 层数加深可落点任意；与兜底层同一闸同一口径）
    if [[ -n "$routed" && ( ! "$routed" =~ ^[A-Za-z0-9._-]+$ || "$routed" =~ ^\.\.?$ ) ]]; then
      dbg "$ent" "$routed" "skip bad-sid routed"
      routed=""
    fi
  fi
  # 兜底层候选：sid 白名单硬闸（gt-893a 评审 C1：map 是不可信共享可变文本——sid 逐字进 API URL
  # 路径且经 for 展开，glob/路径形态可静默换注入目标）；TTL/角色/who 过滤在循环内逐行判
  cands=$(awk -v h="$HOST" -v e="$ent" \
        '$1==h && $2==e && $3 ~ /^[A-Za-z0-9._-]+$/ && $3 !~ /^\.\.?$/ {print $4, $3, $5}' \
        "$AGORA_HOME/sessions.map" 2>/dev/null | sort -r)
  bad=$(awk -v h="$HOST" -v e="$ent" \
      '$1==h && $2==e && ($3 !~ /^[A-Za-z0-9._-]+$/ || $3 ~ /^\.\.?$/) {print $3}' \
      "$AGORA_HOME/sessions.map" 2>/dev/null | sort -u | tr "\n" ",")
  [[ -n "$bad" ]] && dbg "$ent" "${bad%,}" "skip bad-sid"
  local ttl_h="${AGORA_SESSION_TTL_H:-24}" cutoff=0
  [[ "$ttl_h" =~ ^-?[0-9]+$ ]] || ttl_h=24   # sanitize（gt-893a B1 同类）；负数放行由下方 >0 判定＝不限（R2#9 对齐 register/poll「<=0=不清」契约）
  (( ttl_h > 0 )) && cutoff=$(( now - ttl_h * 3600 ))
  declare -A seen=()
  local try_list="" role_skip=0 hard_skip=0
  [[ -n "$routed" ]] && try_list="R $routed - -"$'\n'
  while read -r ts sid rowrole; do
    [[ -n "$sid" ]] || continue
    [[ -n "${seen[$sid]:-}" ]] && continue
    seen[$sid]=1
    # 行级角色过滤（兜底广播；精准层由方向表定位，不受此滤）。订阅面拒收只置 role_skip 标记
    # （R2#1：全行拒收＝设计内跳过 rc0 推水位，不得以 fail 挂死整条 inbox 流水线）
    if [[ -n "$rowrole" && "$rowrole" != "-" ]]; then
      if [[ "$rowrole" == worker ]] && ! evt_in "$WORKER_EVENTS" "$ev"; then
        dbg "$ent" "$sid" "skip role-filter ev=$ev role=$rowrole"; role_skip=1; continue
      fi
      if [[ "$rowrole" == dispatcher ]] && ! evt_in "$DISPATCHER_EVENTS" "$ev"; then
        dbg "$ent" "$sid" "skip role-filter ev=$ev role=$rowrole"; role_skip=1; continue
      fi
    fi
    # TTL 活性闸：ts 解析失败视为存疑放行（who 鉴别兜底；poll 双失败存疑不动同口径）。
    # stale＝硬过滤（占频：R2#6 全过滤路径去抖防 who 风暴）
    tse=0; [[ -n "$ts" ]] && tse=$(date -d "$ts" +%s 2>/dev/null || echo 0)
    if (( cutoff > 0 && tse > 0 && tse < cutoff )); then
      dbg "$ent" "$sid" "skip stale ts=$ts"; hard_skip=1
      echo "$now" > "$WM_DIR/$ent.$sid.sent" 2>/dev/null || :
      continue
    fi
    try_list+="F $sid $rowrole $ts"$'\n'
  done <<< "$cands"
  local sf last
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    kind=${line%% *}; line=${line#* }; sid=${line%% *}
    # 去抖 (entity,sid)：目标粒度占频（精准 sid 失败不堵兜底行）
    sf="$WM_DIR/$ent.$sid.sent"
    last=$(cat "$sf" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0   # sanitize（R2#8：(()) 算术递归展开注入面，同 bump_fail/TTL 先例）
    if (( now - last < DEBOUNCE )); then debounce_hit=1; continue; fi
    if w=$(bash "$SCRIPTS_DIR/runtime/opencode.sh" who "$sid"); then
      # delegated/dead＝身份恒常（title/parentID 与 outcome 持久化）→占频防 who 风暴（R2#6）。
      # 例外（R2#7）：精准层 R 行＝任务亲和定向（同 post.sh T3 ack 注入先例），delegated worker
      # 会话正是设计投递目标——只挡 dead；兜底 F 行维持实体信不投 delegated（gt-893a 边界）
      if [[ "$w" == dead || ( "$w" == delegated && "$kind" == F ) ]]; then
        dbg "$ent" "$sid" "skip $w kind=$kind"
        echo "$now" > "$sf" 2>/dev/null || :
        continue
      fi
    else
      dbg "$ent" "$sid" "who-unreachable fallback"   # API 不可鉴别（stub/僵死）＝退回旧尽力注入语义
    fi
    pick="$sid"; injectable=1
    dbg "$ent" "$sid" "target ${w:-unknown} kind=$kind"
    echo "$now" > "$sf"   # 尝试即占频（防重试风暴）
    if [[ "$MODE" == desktop ]]; then
      command -v notify-send >/dev/null 2>&1 && \
        notify-send "Agora 广场" "@$ent 有新消息（$ref），请 agora_check_mail" 2>/dev/null
      rm -f "$WM_DIR/$ent.fail"
      return 0
    fi
    # 传输经 runtime 适配器（opencode api CLI，delivery=queue）；守卫同 dispatch.sh/post.sh
    # （AGORA_RUNTIME≠opencode 或适配器缺失时旁路＝设计内不算失败）
    if [[ "${AGORA_RUNTIME:-opencode}" == "opencode" && "${AGORA_RUNTIME_API:-1}" != "0" \
          && -f "$SCRIPTS_DIR/runtime/opencode.sh" ]]; then
      if bash "$SCRIPTS_DIR/runtime/opencode.sh" inject "$pick" \
          "广场有新 @你的消息（${ref}），请 agora_check_mail"; then
        dbg "$ent" "$pick" "inject-ok ref=$ref kind=$kind"
        rm -f "$WM_DIR/$ent.fail"
        delivered=1
        [[ "$kind" == R ]] && return 0   # 精准层命中＝单点定向（2508 正解），不广播
        continue   # 兜底层＝广播语义：继续投下一活行（双收）
      fi
      dbg "$ent" "$pick" "fail inject-rc!=0 ref=$ref kind=$kind"
      continue   # 本 sid 失败：已占频，落下一候选（兜底补投）
    fi
    dbg "$ent" "$pick" "bypass runtime-guard ref=$ref"
    rm -f "$WM_DIR/$ent.fail"
    delivered=1
    [[ "$kind" == R ]] && return 0
  done <<< "$try_list"
  (( delivered )) && return 0   # 兜底广播至少一投即成（水位推进；queue 语义下未投活行无损）
  if (( injectable == 0 )); then
    if (( debounce_hit > 0 )); then
      return 1   # 去抖期＝本轮未投，消息保持 pending（下轮重试），不算失败
    fi
    if (( role_skip > 0 && hard_skip == 0 )); then
      # 订阅面拒收＝设计内跳过（R2#1）：角色订阅说「此信非你收」——推水位不挂队列不涨 fail
      dbg "$ent" "-" "role-skip-silent ev=$ev"
      return 0
    fi
    dbg "$ent" "-" "fail no-live-interactive"   # 条目在但全被过滤＝失败可见不得静默丢提醒
    bump_fail "$ent"
    return 1
  fi
  # 存在可投候选但全部 inject 失败：失败可见＋已逐 sid 占频
  dbg "$ent" "-" "fail no-live-interactive"
  bump_fail "$ent"
  return 1
}

scan() {
  local d ent wm f base ref sumline ev task
  for d in "$AGORA_HOME"/inbox/*/; do
    ent=$(basename "$d")
    [[ "$ent" == archive ]] && continue
    wm=$(cat "$WM_DIR/$ent" 2>/dev/null || true)
    for f in "$d"*.md; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f")
      [[ "$base" > "$wm" ]] || continue   # 文件名 = 纳秒时间戳，字典序可比
      ref=$(grep -o 'ref:[^ |]*' "$f" 2>/dev/null | head -1 | cut -d: -f2-)
      sumline=$(grep -o 'summary:.*' "$f" 2>/dev/null | head -1)
      ev=${sumline#summary:}; ev=${ev%% *}          # 首词＝事件名（post.sh 落信格式 summary:<event> <task>）
      task=$(printf '%s' "$sumline" | grep -o 'gt-[0-9a-f]\{4,\}' | head -1)
      notify "$ent" "${ref:-$base}" "$ev" "$task" || break   # gt-893a：失败/去抖不推进水位（丢不得），下轮重试
      wm="$base"
    done
    [[ -n "$wm" ]] && echo "$wm" > "$WM_DIR/$ent"
  done
}

if [[ "${1:-}" == "--once" ]]; then scan; exit 0; fi

if command -v inotifywait >/dev/null 2>&1; then
  while true; do
    scan
    inotifywait -q -r -e close_write -e create "$AGORA_HOME/inbox/" >/dev/null 2>&1
  done
else
  while true; do scan; sleep "$POLL_S"; done
fi
