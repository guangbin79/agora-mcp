#!/usr/bin/env bash
# sync.sh pre|post —— 远端同步纪律（仅当 origin 存在时生效；无远端 = 单机模式，零开销）
#   pre : pull --no-rebase（MUST 在 flock 内、任何写入之前调用）
#   post: push（SHOULD 在提交之后调用；失败不拒事件，只告警，下次 pre 会重试合并）
# 纪律（规格 §9 / CONVENTIONS §8）：
#   - 远端 MUST 用 SSH（git@ 或 ssh://）；http/https/git:// 拒绝；file:// 属本地传输，放行但告警
#   - AGORA_SYNC_REQUIRED=1 时任何同步失败 = 硬失败（exit 8）
# 输出：JSON 一行到 stdout（{"sync":"ok|warn:...|off"}），供调用方并入 derived
set -u
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
MODE="${1:-}"
cd "$AGORA_HOME" 2>/dev/null || { echo '{"sync":"off"}'; exit 0; }

REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
[ -z "$REMOTE_URL" ] && { echo '{"sync":"off"}'; exit 0; }

# SSH 强制（http/https/git 协议一律拒绝；file:// 与裸路径 = 本地传输，告警放行）
case "$REMOTE_URL" in
  git@*|ssh://*) ;;
  file://*|/*|./*)  SYNC_NOTE="local_transport" ;;
  *) echo '{"sync":"error:insecure_remote","hint":"远端必须使用 SSH（git@host:path 或 ssh://），当前: '"$REMOTE_URL"'"}' >&2
     [ "${AGORA_SYNC_REQUIRED:-0}" = "1" ] && exit 8
     echo '{"sync":"off"}'; exit 0 ;;
esac

hard_fail() { # $1=code $2=hint
  echo "{\"sync\":\"error:$1\",\"hint\":\"$2\"}" >&2
  [ "${AGORA_SYNC_REQUIRED:-0}" = "1" ] && exit 8
  echo "{\"sync\":\"warn:$1\"}"; exit 0
}

case "$MODE" in
  pre)
    git fetch origin >/dev/null 2>&1 || hard_fail fetch_failed "网络不可达？事件将只落本地"
    # 远端有新提交才合并（--no-rebase：宣言铁律禁 rebase；union 驱动处理同文件追加）
    MERGED=false
    if ! git merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
      git merge --no-edit FETCH_HEAD >/dev/null 2>&1 || hard_fail merge_conflict "union 未覆盖的冲突，查 doctor-runbook §sync"
      MERGED=true
    fi
    echo "{\"sync\":\"ok\",\"merged_new\":$MERGED}" ;;
  post)
    git push origin HEAD >/dev/null 2>&1 || hard_fail push_failed "已本地落账，下次写入前会自动合并重试"
    echo "{\"sync\":\"ok\"}" ;;
  *) echo '{"sync":"off"}' ;;
esac
exit 0
