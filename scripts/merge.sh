#!/usr/bin/env bash
# merge.sh —— 合并闭环（全量委托 L1，设计 v1.2.1 §六）：
#   ff-only 合并 wt/<task> 分支到合并目标 → 集成 verify 在目标目录真跑 → merged 落账 → 清树
#   合并目标二分：同仓链（上游 dispatcher 任务主仓==本任务主仓且上游有 wt_dir）→ 上游 wt 分支；
#               跨仓链/无上游 → project_dir 默认分支
#   失败路径：集成 verify FAIL → reset --hard 原子回滚零痕迹 → blocked(附 verify 尾) → reopened；
#            non-ff → blocked(冲突摘要) → reopened；脏目标 → TARGET_DIRTY 拒合并（防 reset --hard 吞未提交改动）
#   幂等：目标分支已含本任务提交 → 只补 merged 落账（不重合并不重验）
# 用法: merge.sh --actor NAME@PROJ --task gt-xxxx
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
ACTOR=""; TASK=""
while [[ $# -gt 0 ]]; do case "$1" in
  --actor) ACTOR="$2";; --task) TASK="$2";;
  *) echo '{"code":"VALIDATION_FAILED","message":"unknown arg"}' >&2; exit 2;;
esac; shift 2; done
fail() { python3 -c 'import json,sys; print(json.dumps({"code":sys.argv[1],"message":sys.argv[2]}, ensure_ascii=False), file=sys.stderr)' "$1" "$2"; exit "${3:-2}"; }

[ -n "$ACTOR" ] || fail VALIDATION_FAILED "需要 --actor"
[[ "$TASK" =~ ^gt-[0-9a-f]{4,}$ ]] || fail VALIDATION_FAILED "bad task id: $TASK"
NAME="${ACTOR%%@*}"
[ -f "$AGORA_HOME/wiki/entities/$NAME.md" ] || fail NOT_REGISTERED "caller not in roster: $NAME"
PAGE="$AGORA_HOME/wiki/tasks/$TASK.md"
[ -f "$PAGE" ] || fail TASK_NOT_FOUND "task page missing: $TASK"
FM() { grep -m1 "^$1:" "$PAGE" | sed "s/^$1:[[:space:]]*//; s/^\"\(.*\)\"\$/\1/" || true; }
WTD="$(FM wt_dir)"; PD="$(FM project_dir)"; VF="$(FM verify)"
[ -n "$WTD" ] || fail VALIDATION_FAILED "task $TASK 无 wt_dir（非 wt 任务不走 merge.sh）"
[ -n "$VF" ]  || fail VALIDATION_FAILED "task $TASK has no verify"
[ -d "$PD" ]  || fail VALIDATION_FAILED "project_dir 不存在: $PD"

MAIN=$(PYTHONPATH="$AGORA_HOME/scripts" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "$(realpath "$PD")")

# ---- 合并目标二分：任务链 dispatcher_task → 上游任务页 ----
# 字段边界匹配 (^|[|] )task:<id>( |$)：防 dispatcher_task: 字段子串误中（gt-ab12 前缀撞 gt-ab1234 同防）
UP=$( { cat "$AGORA_HOME"/log/*/*.md 2>/dev/null || true; } | grep -E "(^|[|] )task:$TASK( |$)" | grep "event:dispatched" \
     | sed -n 's/.*dispatcher_task:\(gt-[0-9a-f]\{4,\}\).*/\1/p' | tail -1 || true)
TARGET_DIR="$MAIN"; TARGET_BRANCH=""
if [ -n "${UP:-}" ]; then
  UPAGE="$AGORA_HOME/wiki/tasks/$UP.md"
  if [ -f "$UPAGE" ]; then
    UPWTD=$(grep -m1 '^wt_dir:' "$UPAGE" | sed 's/^wt_dir:[[:space:]]*//' || true)
    UPPD=$(grep -m1 '^project_dir:' "$UPAGE" | sed 's/^project_dir:[[:space:]]*//' || true)
    UPMAIN=""
    [ -n "${UPPD:-}" ] && UPMAIN=$(PYTHONPATH="$AGORA_HOME/scripts" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "$(realpath "$UPPD")" || true)
    if [ -n "${UPWTD:-}" ] && [ "$UPMAIN" = "$MAIN" ]; then
      # 同仓链：目标=上游 wt 分支（目录=上游树）。上游树缺失→锚点重建
      if [ ! -d "$UPWTD" ]; then
        git -C "$MAIN" worktree prune
        git -C "$MAIN" show-ref --verify --quiet "refs/heads/wt/$UP" \
          && git -C "$MAIN" worktree add -q "$UPWTD" "wt/$UP" \
          || git -C "$MAIN" worktree add -q -b "wt/$UP" "$UPWTD" \
          || fail WORKTREE_REBUILD_FAILED "上游树重建失败: $UPWTD"
      fi
      TARGET_DIR="$UPWTD"; TARGET_BRANCH="wt/$UP"
    fi
  fi
fi
[ -n "$TARGET_BRANCH" ] || TARGET_BRANCH=$(git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || echo HEAD)

# ---- 本任务树缺失→锚点重建（FMEA D2） ----
if [ ! -d "$WTD" ]; then
  git -C "$MAIN" worktree prune
  if git -C "$MAIN" show-ref --verify --quiet "refs/heads/wt/$TASK"; then
    git -C "$MAIN" worktree add -q "$WTD" "wt/$TASK" || fail WORKTREE_REBUILD_FAILED "树重建失败（挂既有分支）: $WTD"
  else
    git -C "$MAIN" worktree add -q -b "wt/$TASK" "$WTD" || fail WORKTREE_REBUILD_FAILED "树重建失败（重建分支）: $WTD"
  fi
fi

# ---- 脏目标守卫：reset --hard 只威胁已跟踪文件的未提交改动（未跟踪文件 reset 不触碰，
#      且 ff 合并撞未跟踪同名文件时 git 自拒）——只拦 staged/modified，放行 untracked ----
[ -z "$(git -C "$TARGET_DIR" status --porcelain 2>/dev/null | grep -v '^??')" ] \
  || fail TARGET_DIRTY "合并目标有已跟踪文件未提交改动: $TARGET_DIR（先提交或暂存，再合并）"

PNAME=$(basename "$MAIN")
WTC=$(git -C "$WTD" rev-parse HEAD)
TARG=$(git -C "$TARGET_DIR" rev-parse "$TARGET_BRANCH")

# ---- 幂等：目标已含本任务提交 → 只补 merged（不重合并不重验）＋清树 ----
if [ "$WTC" = "$TARG" ] || git -C "$TARGET_DIR" merge-base --is-ancestor "$WTC" "$TARG" 2>/dev/null; then
  bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PNAME" --event merged \
    --task "$TASK" --commit "$TARG" --branch "$TARGET_BRANCH" >/dev/null \
    || fail LEDGER_FAILED "merged 补账失败（post.sh 详见 stderr）" 4
  git -C "$MAIN" worktree remove "$WTD" 2>/dev/null || true
  git -C "$MAIN" branch -q -D "wt/$TASK" 2>/dev/null || true
  printf '{"result":"merged","task":"%s","branch":"%s","commit":"%s","idempotent":true}\n' "$TASK" "$TARGET_BRANCH" "$TARG"
  exit 0
fi

# ---- ff-only 合并 ----
PRE=$(git -C "$TARGET_DIR" rev-parse "$TARGET_BRANCH")
if ! MERR=$(git -C "$TARGET_DIR" merge --ff-only "wt/$TASK" 2>&1); then
  bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PNAME" --event blocked \
    --task "$TASK" --reason "non-ff: $(echo "$MERR" | tail -2 | tr '\n' ' ' | tr -d '|')" >/dev/null 2>&1 || true
  bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PNAME" --event reopened \
    --task "$TASK" --reason "non-ff 返工：原树 rebase 到 $TARGET_BRANCH 后重走 verify" >/dev/null 2>&1 || true
  fail NOT_FF "目标 $TARGET_BRANCH 不能快进到 wt/$TASK（已落 blocked→reopened）" 4
fi

# ---- 集成 verify 在目标目录真跑；FAIL → 原子回滚＋blocked→reopened ----
if ! VOUT=$(cd "$TARGET_DIR" && timeout "${AGORA_VERIFY_TIMEOUT:-300}" bash -c "$VF" 2>&1 | tail -c 2048); then
  git -C "$TARGET_DIR" reset -q --hard "$PRE"
  bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PNAME" --event blocked \
    --task "$TASK" --reason "集成 verify FAIL: $(echo "$VOUT" | tail -5 | tr '\n' ' ' | tr -d '|')" >/dev/null 2>&1 || true
  bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PNAME" --event reopened \
    --task "$TASK" --reason "集成 verify 失败返工（主支已原子回滚）" >/dev/null 2>&1 || true
  fail VERIFY_FAILED "集成 verify 失败，$TARGET_BRANCH 已回滚至 $PRE（blocked→reopened 已落账）" 4
fi

# ---- merged 落账＋清树 ----
NEWH=$(git -C "$TARGET_DIR" rev-parse "$TARGET_BRANCH")
bash "$AGORA_HOME/scripts/post.sh" --actor "$ACTOR" --project "$PNAME" --event merged \
  --task "$TASK" --commit "$NEWH" --branch "$TARGET_BRANCH" >/dev/null \
  || fail LEDGER_FAILED "merged 落账失败（post.sh 详见 stderr）" 4
git -C "$MAIN" worktree remove "$WTD" 2>/dev/null || true
git -C "$MAIN" branch -q -D "wt/$TASK" 2>/dev/null || true

printf '{"result":"merged","task":"%s","branch":"%s","commit":"%s","idempotent":false}\n' "$TASK" "$TARGET_BRANCH" "$NEWH"
