#!/usr/bin/env bash
# notify-opencode.sh —— 规格 §8.1 通知桥：监听 inbox/ → 向运行中的 opencode v2 会话注入提醒
#
# 用法: nohup bash notify-opencode.sh >/dev/null 2>&1 &   （或 systemd --user）
#       notify-opencode.sh --once   扫一轮就退（测试/调试）
# 环境:
#   AGORA_NOTIFY_DEBOUNCE_S  同实体去抖秒数（默认 60，持久化在 .git/notify-wm/，重启不重置）
#   AGORA_NOTIFY_POLL_S      无 inotifywait 时的轮询间隔（默认 5 秒）
#   AGORA_NOTIFY_MODE        opencode（默认）| desktop（notify-send 桌面通知，零开发兜底）
# 行为契约（规格 §8.1；gt-893a 修订）：
#   - 只递提醒不递内容：消息体只含 ref 指针，正文由 agent 主动 agora_check_mail 拉取
#   - 注入按实体去抖；查不到 sessions.map 映射（会话未在跑）静默跳过
#   - 目标鉴别：同实体常挂多个 sid（懒注册把派生 worker 也登记进实体＝打偏根因），ts 降序经
#     runtime who 鉴别，注入首个 live interactive 顶层会话；全路径落痕 .git/notify-debug.log
#   - 丢不得：注入失败不静默——失败计数 .git/notify-wm/<ent>.fail＋水位不推进（下轮重试，
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

dbg() { # $1=entity $2=sid $3=事件——排查落痕（gt-893a：此前零落痕，打偏一周无从定位）
  printf '%s entity=%s sid=%s %s\n' "$(date -Is)" "$1" "${2:--}" "$3" >> "$DBG_LOG" 2>/dev/null || :
}

notify() { # $1=entity $2=ref → rc0=投递成功/设计内跳过；rc1=投递失败（scan 不推进水位）
  local ent="$1" ref="$2" now last sf cands s pick="" w
  now=$(date +%s)
  sf="$WM_DIR/$ent.sent"
  last=$(cat "$sf" 2>/dev/null || echo 0)
  (( now - last < DEBOUNCE )) && return 1   # 去抖期＝本轮未投，消息保持 pending（下轮重试）
  # sessions.map 本机条目：<host> <agent> <session> <ts>；同实体多 sid 取 ts 降序逐个鉴别
  cands=$(awk -v h="$HOST" -v e="$ent" '$1==h && $2==e {print $4, $3}' \
        "$AGORA_HOME/sessions.map" 2>/dev/null | sort -r | awk '!seen[$2]++ {print $2}')
  if [[ -z "$cands" ]]; then
    dbg "$ent" "-" "skip no-map-entry"   # 会话未在跑＝设计内静默（不算失败）
    echo "$now" > "$sf"
    return 0
  fi
  for s in $cands; do
    if w=$(bash "$SCRIPTS_DIR/runtime/opencode.sh" who "$s"); then
      if [[ "$w" == delegated || "$w" == dead ]]; then dbg "$ent" "$s" "skip $w"; continue; fi
    else
      dbg "$ent" "$s" "who-unreachable fallback"   # API 不可鉴别（stub/僵死）＝退回旧尽力注入语义
    fi
    pick="$s"; dbg "$ent" "$s" "target ${w:-unknown}"; break
  done
  if [[ -z "$pick" ]]; then
    dbg "$ent" "-" "fail no-live-interactive"
    echo $(( $(cat "$WM_DIR/$ent.fail" 2>/dev/null || echo 0) + 1 )) > "$WM_DIR/$ent.fail"
    echo "$now" > "$sf"   # 尝试即占频：去抖按尝试计（防重试风暴）
    return 1
  fi
  if [[ "$MODE" == desktop ]]; then
    command -v notify-send >/dev/null 2>&1 && \
      notify-send "Agora 广场" "@$ent 有新消息（$ref），请 agora_check_mail" 2>/dev/null
    echo "$now" > "$sf"
    return 0
  fi
  # 传输经 runtime 适配器（opencode api CLI，delivery=queue）；守卫同 dispatch.sh:103/post.sh:262
  # （AGORA_RUNTIME≠opencode 或适配器缺失时旁路＝设计内不算失败）
  if [[ "${AGORA_RUNTIME:-opencode}" == "opencode" && "${AGORA_RUNTIME_API:-1}" != "0" \
        && -f "$SCRIPTS_DIR/runtime/opencode.sh" ]]; then
    if bash "$SCRIPTS_DIR/runtime/opencode.sh" inject "$pick" \
        "广场有新 @你的消息（${ref}），请 agora_check_mail"; then
      dbg "$ent" "$pick" "inject-ok ref=$ref"
      rm -f "$WM_DIR/$ent.fail"
      echo "$now" > "$sf"
      return 0
    fi
    dbg "$ent" "$pick" "fail inject-rc!=0 ref=$ref"
    echo $(( $(cat "$WM_DIR/$ent.fail" 2>/dev/null || echo 0) + 1 )) > "$WM_DIR/$ent.fail"
    echo "$now" > "$sf"
    return 1
  fi
  dbg "$ent" "$pick" "bypass runtime-guard ref=$ref"
  echo "$now" > "$sf"
  return 0
}

scan() {
  local d ent wm f base ref
  for d in "$AGORA_HOME"/inbox/*/; do
    ent=$(basename "$d")
    [[ "$ent" == archive ]] && continue
    wm=$(cat "$WM_DIR/$ent" 2>/dev/null || true)
    for f in "$d"*.md; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f")
      [[ "$base" > "$wm" ]] || continue   # 文件名 = 纳秒时间戳，字典序可比
      ref=$(grep -o 'ref:[^ |]*' "$f" 2>/dev/null | head -1 | cut -d: -f2-)
      notify "$ent" "${ref:-$base}" || break   # gt-893a：失败/去抖不推进水位（丢不得），下轮重试
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
