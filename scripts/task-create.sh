#!/usr/bin/env bash
# task-create.sh — 结构化创建任务页（agora_task_create 的实现）
# 入参（环境变量）:
#   TITLE       必填，任务标题
#   BODY        可选，任务描述正文
#   VERIFY      可选，完成判据命令（与 PROJECT_DIR 必须同时提供）
#   PROJECT_DIR 可选，verify 执行目录
#   DEPS        可选，逗号分隔的前置任务 id（必须已存在）
#   PARENT      可选，父任务 id（必须已存在）
# 输出：{"task":"gt-xxxx","path":"wiki/tasks/gt-xxxx.md"}
# 失败：JSON → stderr，exit 2 参数校验 / 5 引用不存在
set -u
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"

[ -z "${TITLE:-}" ] && { echo '{"error":"TITLE_REQUIRED","hint":"需要 TITLE"}' >&2; exit 2; }
if [ -n "${VERIFY:-}" ] && [ -z "${PROJECT_DIR:-}" ]; then
  echo '{"error":"VERIFY_NEEDS_PROJECT_DIR","hint":"verify 与 project_dir 必须同时提供"}' >&2; exit 2
fi
if [ -n "${PROJECT_DIR:-}" ] && [ -z "${VERIFY:-}" ]; then
  echo '{"error":"PROJECT_DIR_NEEDS_VERIFY","hint":"project_dir 与 verify 必须同时提供"}' >&2; exit 2
fi
[ -n "${PROJECT_DIR:-}" ] && [ ! -d "$PROJECT_DIR" ] && {
  echo "{\"error\":\"PROJECT_DIR_NOT_FOUND\",\"hint\":\"目录不存在: $PROJECT_DIR\"}" >&2; exit 2; }

# 引用存在性校验
for ref in $(echo "${DEPS:-}" | tr ',' ' ') ${PARENT:-}; do
  [ -z "$ref" ] && continue
  [ -f "$AGORA_HOME/wiki/tasks/$ref.md" ] || {
    echo "{\"error\":\"TASK_NOT_FOUND\",\"hint\":\"引用的任务不存在: $ref\"}" >&2; exit 5; }
done

# ID 生成：gt-<sha1(title|ts|rand)[:4]>，撞了重摇
TASKS_DIR="$AGORA_HOME/wiki/tasks"
mkdir -p "$TASKS_DIR"
for i in 1 2 3 4 5; do
  TASK_ID="gt-$(echo -n "${TITLE}|$(date +%s%N)|$RANDOM" | sha1sum | cut -c1-4)"
  [ ! -f "$TASKS_DIR/$TASK_ID.md" ] && break
done
[ -f "$TASKS_DIR/$TASK_ID.md" ] && { echo '{"error":"ID_ALLOC_FAILED","hint":"重试"}' >&2; exit 2; }

# deps yaml 行
DEPS_YAML="[]"
if [ -n "${DEPS:-}" ]; then
  DEPS_YAML="[$(echo "$DEPS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sed 's/.*/"&"/' | paste -sd,)]"
fi

# 同锁写入 + commit（与 post.sh 串行化；有远端时锁内先 pull 后 push）
(
  flock -w "${AGORA_LOCK_WAIT:-5}" 9 || { echo '{"error":"LOCK_TIMEOUT"}' >&2; exit 3; }
  bash "$AGORA_HOME/scripts/sync.sh" pre >/dev/null 2>&1 || true
  {
    echo "---"
    echo "id: $TASK_ID"
    echo "title: $TITLE"
    echo "status: open"
    echo "deps: $DEPS_YAML"
    [ -n "${VERIFY:-}" ]       && echo "verify: $VERIFY"
    [ -n "${PROJECT_DIR:-}" ]  && echo "project_dir: $PROJECT_DIR"
    [ -n "${PARENT:-}" ]       && echo "parent: $PARENT"
    echo "---"
    echo
    echo "${BODY:-（无描述）}"
  } > "$TASKS_DIR/$TASK_ID.md"
  cd "$AGORA_HOME"
  export AGORA_MECHANICAL=1
  git add "wiki/tasks/$TASK_ID.md"
  git commit -q -m "task: create $TASK_ID $TITLE"
  bash "$AGORA_HOME/scripts/sync.sh" post >/dev/null 2>&1 || true
) 9>"$AGORA_HOME/.git/post.lock"

printf '{"task":"%s","path":"wiki/tasks/%s.md"}\n' "$TASK_ID" "$TASK_ID"
