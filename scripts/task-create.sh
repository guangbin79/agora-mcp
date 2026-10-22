#!/usr/bin/env bash
# task-create.sh — 结构化创建任务页（agora_task_create 的实现）
# 入参（环境变量）:
#   TITLE       必填，任务标题
#   BODY        可选，任务描述正文
#   VERIFY      可选，完成判据命令（与 PROJECT_DIR 必须同时提供；
#               缺省时若项目页 wiki/projects/* 注册了该目录的 verify 则自动回填）
#   PROJECT_DIR 可选，verify 执行目录
#   DEPS        可选，逗号分隔的前置任务 id（必须已存在）
#   PARENT      可选，父任务 id（必须已存在）
# 输出：{"task":"gt-xxxx","path":"wiki/tasks/gt-xxxx.md"}
# 失败：JSON → stderr，exit 2 参数校验 / 5 引用不存在
set -u
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"

[ -z "${TITLE:-}" ] && { echo '{"error":"TITLE_REQUIRED","hint":"需要 TITLE"}' >&2; exit 2; }
# frontmatter 单行字段禁止换行/回车（否则撕裂 yaml 头，甚至注入伪字段）
for v in TITLE VERIFY PROJECT_DIR PARENT IDEM; do
  case "${!v:-}" in
    *$'\n'*|*$'\r'*) echo "{\"error\":\"VALIDATION_FAILED\",\"hint\":\"$v 不得含换行\"}" >&2; exit 2;;
  esac
done
if [ -n "${VERIFY:-}" ] && [ -z "${PROJECT_DIR:-}" ]; then
  echo '{"error":"VERIFY_NEEDS_PROJECT_DIR","hint":"verify 与 project_dir 必须同时提供"}' >&2; exit 2
fi
# verify fallback：项目页注册过该目录的默认 verify 则回填（编排大脑无需重复提供验收命令）
# 归一口径：PROJECT_DIR 经 agora_lib.main_repo_of 归一到主仓再匹配（worktree 路径同样命中，设计 §五）
if [ -n "${PROJECT_DIR:-}" ] && [ -z "${VERIFY:-}" ]; then
  VERIFY=$(AGORA_HOME="$AGORA_HOME" PROJECT_DIR="$PROJECT_DIR" python3 - <<'PYEOF'
import os, glob, re, sys
home = os.environ["AGORA_HOME"]
sys.path.insert(0, os.path.join(home, "scripts"))
import agora_lib
raw = os.path.expanduser(os.environ["PROJECT_DIR"])
target = os.path.realpath(agora_lib.main_repo_of(raw) or raw)
for f in glob.glob(f"{home}/wiki/projects/*.md"):
    txt = open(f, encoding="utf-8").read()
    pm = re.search(r'^path:\s*(\S+)\s*$', txt, re.M)
    if pm and os.path.realpath(os.path.expanduser(pm.group(1))) == target:
        vm = re.search(r'^verify:\s*(.+?)\s*$', txt, re.M)
        if vm: print(vm.group(1)); break
PYEOF
)
fi
if [ -n "${PROJECT_DIR:-}" ] && [ -z "${VERIFY:-}" ]; then
  echo '{"error":"PROJECT_DIR_NEEDS_VERIFY","hint":"project_dir 需要 verify：显式提供，或在该目录的项目页（wiki/projects/）注册默认 verify"}' >&2; exit 2
fi
# WT=1（agora 建树）必须有 verify 合同——只给可验收任务建树（设计 §五）
if [ "${WT:-0}" = "1" ] && { [ -z "${PROJECT_DIR:-}" ] || [ -z "${VERIFY:-}" ]; }; then
  echo '{"error":"WT_NEEDS_VERIFY","hint":"WT=1 需要 project_dir 与 verify（agora 只给可验收任务建树）"}' >&2; exit 2
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

# idem 命中判定（唯一口径：frontmatter 精确行匹配）——锁外快路径与锁内权威复检共用
idem_lookup() {
  [ -n "${IDEM:-}" ] || return 1
  for f in "$TASKS_DIR"/gt-*.md; do
    [ -f "$f" ] || continue
    if sed -n '2,/^---$/p' "$f" | grep -qxF "idem: $IDEM"; then basename "$f" .md; return 0; fi
  done
  return 1
}
# idem 快路径（无锁预检）：命中直接短路返回，连树都不建（权威判定仍在锁内复检兜并发窗口）
FOUND=$(idem_lookup) && { printf '{"task":"%s","path":"wiki/tasks/%s.md"}\n' "$FOUND" "$FOUND"; exit 0; }

# WT=1：agora 建专用 worktree（flock 外——外部 git 操作不占账本锁；v1.29 修订边界）
# 命名 ../<REPO>__wt-<gt-id>__<MMDDHHMM>（agora 自有命名域，GC 前缀口径）；分支 wt/<gt-id>
WT_DIR=""; WT_MAIN=""
if [ "${WT:-0}" = "1" ]; then
  MR=$(realpath "$PROJECT_DIR")
  WT_MAIN=$(PYTHONPATH="$AGORA_HOME/scripts" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "$MR")
  WT_DIR="$(dirname "$WT_MAIN")/$(basename "$WT_MAIN")__wt-${TASK_ID}__$(date +%m%d%H%M)"
  git -C "$WT_MAIN" worktree add -q -b "wt/$TASK_ID" "$WT_DIR" \
    || { echo '{"error":"WORKTREE_CREATE_FAILED","hint":"git worktree add 失败（详见 stderr）"}' >&2; exit 2; }
fi

# deps yaml 行
DEPS_YAML="[]"
if [ -n "${DEPS:-}" ]; then
  DEPS_YAML="[$(echo "$DEPS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sed 's/.*/"&"/' | paste -sd,)]"
fi

# 同锁写入 + commit（与 post.sh 串行化；有远端时锁内先 pull 后 push）
# 子 shell 输出被捕获：短路路径输出既有任务 JSON（exit 0 只退出子 shell），外层见非空即透传终止
SHORTOUT=$( (
  flock -w "${AGORA_LOCK_WAIT:-5}" 9 || { echo '{"error":"LOCK_TIMEOUT"}' >&2; exit 3; }
  # idem 权威复检（锁内）：快路径后、建树后到此的并发窗口兜底——他方同 key 已落页则
  # 拆本方刚建的树（分支含 WIP 不可能有——刚建未派发）并返回既有任务
  FOUND=$(idem_lookup) && {
    [ -n "$WT_DIR" ] && { git -C "$WT_MAIN" worktree remove --force "$WT_DIR" 2>/dev/null
                          git -C "$WT_MAIN" branch -D "wt/$TASK_ID" 2>/dev/null; }
    printf '{"task":"%s","path":"wiki/tasks/%s.md"}' "$FOUND" "$FOUND"
    exit 0
  }
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
    [ -n "${IDEM:-}" ]         && echo "idem: $IDEM"
    [ "${WT:-0}" = "1" ] && { echo "wt: true"; echo "wt_dir: $WT_DIR"; echo "wt_host: $(hostname)"; }
    echo "---"
    echo
    echo "${BODY:-（无描述）}"
  } > "$TASKS_DIR/$TASK_ID.md"
  bash "$AGORA_HOME/scripts/derive-board.sh" >/dev/null   # 创建与看板重推导同锁完成：返回时新任务已在 todo 可见
  cd "$AGORA_HOME"
  export AGORA_MECHANICAL=1
  git add "wiki/tasks/$TASK_ID.md" board/
  git commit -q -m "task: create $TASK_ID $TITLE"
  bash "$AGORA_HOME/scripts/sync.sh" post >/dev/null 2>&1 || true
) 9>"$AGORA_HOME/.git/post.lock" )
if [ -n "$SHORTOUT" ]; then printf '%s\n' "$SHORTOUT"; exit 0; fi

printf '{"task":"%s","path":"wiki/tasks/%s.md"}\n' "$TASK_ID" "$TASK_ID"
