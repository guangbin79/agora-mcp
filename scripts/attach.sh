#!/usr/bin/env bash
# attach.sh —— 证据附件：文件落**项目版本库**的独立 ref，账本只记 <url>@<commit>
# 设计（宣言 v0.9）：证据不进广场仓库（零膨胀）；项目库 git 内容寻址即完整性保证；
#   独立 ref（refs/agora/evidence/<task>，orphan 链式）不污染项目主分支；临时 index 构建，不碰工作区。
# 入参（环境变量）：
#   ACTOR 必填  发帖身份（MCP 裁决注入）
#   TASK  必填  gt-xxxx（须已存在）
#   FILES 必填  逗号分隔的文件路径（相对 PROJECT_DIR）
#   NOTE  可选  说明（进事件 body）
#   PROJECT_DIR 可选，缺省 cwd（必须是 git 仓库）
# 输出：{"task","ref","url","commit"}；失败 JSON → stderr，exit 2 校验 / 5 任务不存在
set -u
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 单源自定位：兄弟脚本/库一律本仓 scripts（gt-f6e4）
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

fail() { python3 -c 'import json,sys; print(json.dumps({"error":sys.argv[1],"hint":sys.argv[2]}, ensure_ascii=False), file=sys.stderr)' "$1" "$2"; exit "${3:-2}"; }   # 嵌值含引号亦合法（评审 MINOR：错误通道 JSON）
[ -z "${ACTOR:-}" ]  && fail ACTOR_REQUIRED "attach 必须带身份（经 agora_attach 工具调用）"
[ -z "${TASK:-}" ]   && fail TASK_REQUIRED ""
[ -z "${FILES:-}" ]  && fail FILES_REQUIRED "至少一个文件"
[ -f "$AGORA_HOME/wiki/tasks/$TASK.md" ] || fail UNKNOWN_TASK "任务不存在: $TASK" 5
cd "$PROJECT_DIR" 2>/dev/null || fail PROJECT_DIR_NOT_FOUND "$PROJECT_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail NOT_A_GIT_REPO "证据必须落在项目版本库: $PROJECT_DIR"

# 临时 index 构建证据树（不动用户的工作区与暂存区）
# 注意：mktemp 创建的空文件不是合法 index，必须删掉让 git 自建
TMPI=$(mktemp); rm -f "$TMPI"; trap "rm -f $TMPI" EXIT
IFS=',' read -ra FS <<< "$FILES"
for f in "${FS[@]}"; do
  f="${f#./}"
  [ -f "$f" ] || fail FILE_NOT_FOUND "$f（相对 $PROJECT_DIR）"
  GIT_INDEX_FILE="$TMPI" git add -- "$f" || fail ADD_FAILED "$f"
done
TREE=$(GIT_INDEX_FILE="$TMPI" git write-tree)

# orphan 链式：同任务的证据串成链，可回溯历次 attach
REF="refs/agora/evidence/$TASK"
PREV=$(git rev-parse -q --verify "$REF" 2>/dev/null || true)
CMT=$(printf 'evidence: %s\n\n%s\n' "$TASK" "${NOTE:-}" | git commit-tree "$TREE" ${PREV:+-p "$PREV"})
git update-ref "$REF" "$CMT"

# URL：远端优先，无远端记 local:<path>（指针语义 = 本机路径）
URL=$(git config --get remote.origin.url 2>/dev/null || echo "local:$(git rev-parse --show-toplevel)")
# 有远端则推送证据 ref（不推送则他机无法按 URL 取到）；失败只告警，哈希日后可补推
PUSH_WARN=""
if [[ "$URL" != local:* ]]; then
  git push origin "$REF" >/dev/null 2>&1 || PUSH_WARN="1"
fi

# 落账：attached 事件（task 类，evidence=<url>@<commit>）
ARGS=(--actor "$ACTOR" --project "${ACTOR#*@}" --event attached --task "$TASK" --evidence "$URL@$CMT")
[ -n "${NOTE:-}" ] && ARGS+=(--body "$NOTE")
OUT=$(bash "$SCRIPTS_DIR/post.sh" "${ARGS[@]}" 2>&1) || fail POST_FAILED "$OUT" 2

printf '{"task":"%s","ref":"%s","url":"%s","commit":"%s"%s}\n' \
  "$TASK" "$REF" "$URL" "$CMT" "${PUSH_WARN:+,\"warn\":\"ref 未推送到远端，证据暂仅本机可达\"}"
