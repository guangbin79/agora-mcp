#!/usr/bin/env bash
# notify-opencode.sh —— 规格 §8.1 通知桥：监听 inbox/ → 向运行中的 opencode v2 会话注入提醒
#
# 用法: nohup bash notify-opencode.sh >/dev/null 2>&1 &   （或 systemd --user）
#       notify-opencode.sh --once   扫一轮就退（测试/调试）
# 环境:
#   AGORA_NOTIFY_DEBOUNCE_S  同实体去抖秒数（默认 60，持久化在 .git/notify-wm/，重启不重置）
#   AGORA_NOTIFY_POLL_S      无 inotifywait 时的轮询间隔（默认 5 秒）
#   AGORA_NOTIFY_MODE        opencode（默认）| desktop（notify-send 桌面通知，零开发兜底）
# 行为契约（规格 §8.1）：
#   - 只递提醒不递内容：消息体只含 ref 指针，正文由 agent 主动 agora_check_mail 拉取
#   - 注入按实体去抖；查不到 sessions.map 映射（会话未在跑）静默跳过
#   - runtime 注入失败静默跳过，不阻塞、不重试风暴
#   - 投递方式 delivery=queue：不打断正在跑的回合，空闲会话入队即唤起
set -uo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
DEBOUNCE="${AGORA_NOTIFY_DEBOUNCE_S:-60}"
POLL_S="${AGORA_NOTIFY_POLL_S:-5}"
MODE="${AGORA_NOTIFY_MODE:-opencode}"
WM_DIR="$AGORA_HOME/.git/notify-wm"; mkdir -p "$WM_DIR"
HOST="$(hostname)"

notify() { # $1=entity $2=ref
  local ent="$1" ref="$2" now sid last sf
  now=$(date +%s)
  sf="$WM_DIR/$ent.sent"
  last=$(cat "$sf" 2>/dev/null || echo 0)
  (( now - last < DEBOUNCE )) && return 0
  # sessions.map 本机条目：<host> <agent> <session> <ts>；同一实体多次登记取最新一条
  sid=$(awk -v h="$HOST" -v e="$ent" '$1==h && $2==e {sid=$3} END{if (sid) print sid}' \
        "$AGORA_HOME/scripts/sessions.map" 2>/dev/null)
  [[ -z "$sid" ]] && return 0   # 会话未在跑，静默
  if [[ "$MODE" == desktop ]]; then
    command -v notify-send >/dev/null 2>&1 && \
      notify-send "Agora 广场" "@$ent 有新消息（$ref），请 agora_check_mail" 2>/dev/null
  else
    # 传输经 runtime 适配器（opencode api CLI，delivery=queue）；守卫同 dispatch.sh:103/post.sh:262
    # （AGORA_RUNTIME≠opencode 或适配器缺失时旁路），rc 非 0 静默跳过
    if [[ "${AGORA_RUNTIME:-opencode}" == "opencode" && "${AGORA_RUNTIME_API:-1}" != "0" \
          && -f "$AGORA_HOME/scripts/runtime/opencode.sh" ]]; then
      bash "$AGORA_HOME/scripts/runtime/opencode.sh" inject "$sid" \
        "广场有新 @你的消息（${ref}），请 agora_check_mail" || :
    fi
  fi
  echo "$now" > "$sf"   # 按注入频率去抖：记录尝试即占频
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
      notify "$ent" "${ref:-$base}"
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
