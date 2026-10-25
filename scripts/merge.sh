#!/usr/bin/env bash
# merge.sh —— 合并闭环（全量委托 L1，设计 v1.2.1 §六）：
#   ff-only 合并 wt/<task> 分支到合并目标 → 集成 verify 在目标目录真跑 → merged 落账 → 清树
#   合并目标二分：同仓链（上游 dispatcher 任务主仓==本任务主仓且上游有 wt_dir）→ 上游 wt 分支；
#               跨仓链/无上游 → project_dir 默认分支
#   非 wt 闭环（gt-7117）：页无 wt_dir＝直改仓任务——done commit 已被主仓默认分支包含
#               → 出票补 merged（verify 背书＝done 时机械 verify 锚 project_dir，等价 wt 幂等路径
#               「已含→只补账不重验」；无树操作）
#   失败路径：集成 verify FAIL → reset --hard 原子回滚零痕迹 → blocked(附 verify 尾) → reopened；
#            non-ff → blocked(冲突摘要) → reopened；脏目标 → TARGET_DIRTY 拒合并（防 reset --hard 吞未提交改动）
#   幂等：目标分支已含本任务提交 → 只补 merged 落账（不重合并不重验）
# 用法: merge.sh --actor NAME@PROJ --task gt-xxxx
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 单源自定位：兄弟脚本/库一律本仓 scripts（gt-f6e4）
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——裸调用已禁用（静默错路径教训 gt-ca34）：export AGORA_HOME=$HOME/plaza 后重试，或经 MCP server env 注入}"
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
[ -n "$VF" ]  || fail VALIDATION_FAILED "task $TASK has no verify"
[ -d "$PD" ]  || fail VALIDATION_FAILED "project_dir 不存在: $PD"
# wt_host 守卫（S3）：跨机 wt 任务不在本机合并（wt_dir 锚点会在本机重建树＝错误现场）
WHOST="$(FM wt_host)"
[ -z "$WHOST" ] || [ "$WHOST" = "$(hostname)" ] || fail WT_HOST_MISMATCH "wt_host=$WHOST ≠ 本机 $(hostname)——跨机 wt 任务不本机合并" 9

MAIN=$(PYTHONPATH="$SCRIPTS_DIR" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "$(realpath "$PD")")

# ---- gt-7117 非 wt 闭环：页无 wt_dir＝直改仓任务（无树可清）。done 已由 post.sh
# 机械 verify 锚 project_dir 真跑背书；此处验 done commit 已被主仓默认分支包含
# 即出票补 merged——对齐 wt 幂等路径「已含→只补账不重验」（无可合并新状态）。
if [ -z "$WTD" ]; then
  # B-1（gt-7117 评审）：find 空时裸 cat $(find) 吞调用方 stdin/挂起——post.sh T1 同款硬化；
  # LC_ALL=C 钉分片序（R1 评审 C-F2：collation 漂移会改「首个 claimed」判定）
  LEDCAT() { find "$AGORA_HOME/log" -mindepth 2 -name "*.md" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r cat 2>/dev/null || true; }
  # R1 评审（ocr/B-F2/C-F1）：结构字段双侧定界锚——自由文本（禁 | 但可含字段形 token）不得伪造 event:/actor:/commit: 信号；
  # R2 评审（ocr-F1/F2/F3）：actor sed 左锚升结构位 [|] actor:（右锚可由后续字段供给）；DONEC/DONEA 同源 LASTDONE 快照防异源行配对
  TASKL=$(LEDCAT | grep -E "(^|[|] )task:$TASK( |$)" || true)
  DONEL=$(printf '%s\n' "$TASKL" | grep -E "[|] event:done( |$)" || true)
  LASTDONE=$(printf '%s\n' "$DONEL" | tail -1 || true)
  DONEC=$(printf '%s\n' "$LASTDONE" \
    | awk '{ if (match($0, /[|] commit:[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+/)) print substr($0, RSTART+9, RLENGTH-9) }' \
    || true)
  [ -n "$DONEC" ] || fail VALIDATION_FAILED "task $TASK 账本无 done commit（非 wt 闭环缺锚点）"
  # C-1（gt-7117 评审）actor 链闸：无锚制品时 claimed→done 链＝wt 路径「锚制品仅派发链可造」的替代闸，fail-closed；
  # sed 双侧结构锚（值禁 |，「| actor:x |」字面序自由文本不可得）
  DONEA=$(printf '%s\n' "$LASTDONE" | sed -n 's/.*[|] actor:\([^ |]*\) [|].*/\1/p' || true)
  CLAIMA=$(printf '%s\n' "$TASKL" | grep -E "[|] event:claimed( |$)" | head -1 \
    | sed -n 's/.*[|] actor:\([^ |]*\) [|].*/\1/p' || true)
  [ -n "$CLAIMA" ] || fail VALIDATION_FAILED "task $TASK 账本无 claimed 事件（无认领链拒，fail-closed）"
  [ "$DONEA" = "$CLAIMA" ] || fail DONE_ACTOR_MISMATCH "done actor ${DONEA:-∅} ≠ 首个 claimed actor $CLAIMA" 4
  TBRANCH=$(git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || echo HEAD)
  TARG=$(git -C "$MAIN" rev-parse --verify --quiet "$TBRANCH") || fail VALIDATION_FAILED "目标分支不可解析: $MAIN@$TBRANCH"
  git -C "$MAIN" merge-base --is-ancestor "$DONEC" "$TARG" 2>/dev/null \
    || fail NOT_IN_TARGET "done commit $DONEC 不在 $MAIN:$TBRANCH——非 wt 任务无可合并动作，产出先落主支再闭环" 4
  mkdir -p "$AGORA_HOME/.git/merge-tickets"
  : > "$AGORA_HOME/.git/merge-tickets/$TASK"
  bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$(basename "$MAIN")" --event merged \
    --task "$TASK" --commit "$TARG" --branch "$TBRANCH" >/dev/null \
    || { rm -f "$AGORA_HOME/.git/merge-tickets/$TASK"; fail LEDGER_FAILED "merged 补账失败（post.sh 详见 stderr）" 4; }
  rm -f "$AGORA_HOME/.git/merge-tickets/$TASK"
  printf '{"result":"merged","task":"%s","branch":"%s","commit":"%s","nonwt":true}\n' "$TASK" "$TBRANCH" "$TARG"
  exit 0
fi

# ---- 合并目标二分：任务链 dispatcher_task → 上游任务页 ----
# 字段边界匹配 (^|[|] )task:<id>( |$)：防 dispatcher_task: 字段子串误中（gt-ab12 前缀撞 gt-ab1234 同防）
UP=$( { cat $(find "$AGORA_HOME/log" -mindepth 2 -name "*.md" -type f 2>/dev/null | sort) 2>/dev/null || true; } | grep -E "(^|[|] )task:$TASK( |$)" | grep "event:dispatched" \
     | sed -n 's/.*dispatcher_task:\(gt-[0-9a-f]\{4,\}\).*/\1/p' | tail -1 || true)
TARGET_DIR="$MAIN"; TARGET_BRANCH=""
if [ -n "${UP:-}" ]; then
  UPAGE="$AGORA_HOME/wiki/tasks/$UP.md"
  if [ -f "$UPAGE" ]; then
    UPWTD=$(grep -m1 '^wt_dir:' "$UPAGE" | sed 's/^wt_dir:[[:space:]]*//' || true)
    UPPD=$(grep -m1 '^project_dir:' "$UPAGE" | sed 's/^project_dir:[[:space:]]*//' || true)
    UPMAIN=""
    [ -n "${UPPD:-}" ] && UPMAIN=$(PYTHONPATH="$SCRIPTS_DIR" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "$(realpath "$UPPD")" || true)
    if [ -n "${UPWTD:-}" ] && [ "$UPMAIN" = "$MAIN" ]; then
      # gt-7ca0 场景b（链目标死循环）祖先检查：上游 tip 已并入主仓默认分支（已并）或分支已清
      # （并后清理）→ 链目标已死，目标回落主仓默认分支——不再锚点重建复活上游分支
      # （gt-2b25 补票三连 NOT_FF 根因）。分支在场且 tip 未并入 → 活链锚点照旧
      UP_LIVE=0
      if git -C "$MAIN" show-ref --verify --quiet "refs/heads/wt/$UP"; then
        DEFTGT=$(git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || echo "")
        if [ -n "$DEFTGT" ] && git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$DEFTGT" >/dev/null 2>&1 \
           && git -C "$MAIN" merge-base --is-ancestor "refs/heads/wt/$UP" "refs/heads/$DEFTGT"; then
          :   # 上游已并：目标回落默认分支
        else
          UP_LIVE=1
        fi
      fi
      if [ "$UP_LIVE" = 1 ]; then
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
fi
[ -n "$TARGET_BRANCH" ] || TARGET_BRANCH=$(git -C "$MAIN" symbolic-ref -q --short HEAD 2>/dev/null || echo HEAD)

# ---- 本任务树缺失→锚点重建（FMEA D2；S1 基点=默认分支序探） ----
if [ ! -d "$WTD" ]; then
  git -C "$MAIN" worktree prune
  if git -C "$MAIN" show-ref --verify --quiet "refs/heads/wt/$TASK"; then
    git -C "$MAIN" worktree add -q "$WTD" "wt/$TASK" || fail WORKTREE_REBUILD_FAILED "树重建失败（挂既有分支）: $WTD"
  else
    DEFBR=""
    for _c in "$(git -C "$MAIN" config --get init.defaultBranch 2>/dev/null)" main master; do
      [ -n "$_c" ] && git -C "$MAIN" show-ref --verify --quiet "refs/heads/$_c" && { DEFBR="$_c"; break; }
    done
    [ -n "$DEFBR" ] || fail WORKTREE_REBUILD_FAILED "默认分支不可解析（重建基点缺失）"
    git -C "$MAIN" worktree add -q -b "wt/$TASK" "$WTD" "$DEFBR" || fail WORKTREE_REBUILD_FAILED "树重建失败（默认分支基点 $DEFBR）: $WTD"
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
  mkdir -p "$AGORA_HOME/.git/merge-tickets"
  : > "$AGORA_HOME/.git/merge-tickets/$TASK"
  bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PNAME" --event merged \
    --task "$TASK" --commit "$TARG" --branch "$TARGET_BRANCH" >/dev/null \
    || { rm -f "$AGORA_HOME/.git/merge-tickets/$TASK"; fail LEDGER_FAILED "merged 补账失败（post.sh 详见 stderr）" 4; }
  rm -f "$AGORA_HOME/.git/merge-tickets/$TASK"
  git -C "$MAIN" worktree remove "$WTD" 2>/dev/null || true
  git -C "$MAIN" branch -q -D "wt/$TASK" 2>/dev/null || true
  printf '{"result":"merged","task":"%s","branch":"%s","commit":"%s","idempotent":true}\n' "$TASK" "$TARGET_BRANCH" "$TARG"
  exit 0
fi

# ---- ff-only 合并（B-W2 守卫：目标目录当前检出分支必须==TARGET_BRANCH，防并发漂移错并） ----
CURBR=$(git -C "$TARGET_DIR" symbolic-ref -q --short HEAD 2>/dev/null || echo "(detached)")
if [ "$CURBR" != "$TARGET_BRANCH" ]; then
  fail TARGET_DETACHED "目标目录当前检出 $CURBR ≠ $TARGET_BRANCH（并发漂移/脱出目标分支），拒绝合并" 4
fi
PRE=$(git -C "$TARGET_DIR" rev-parse "$TARGET_BRANCH")
if ! MERR=$(git -C "$TARGET_DIR" merge --ff-only "wt/$TASK" 2>&1); then
  bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PNAME" --event blocked \
    --task "$TASK" --reason "non-ff: $(echo "$MERR" | tail -2 | tr '\n' ' ' | tr -d '|')" >/dev/null 2>&1 || true
  bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PNAME" --event reopened \
    --task "$TASK" --reason "non-ff 返工：原树 rebase 到 $TARGET_BRANCH 后重走 verify" >/dev/null 2>&1 || true
  fail NOT_FF "目标 $TARGET_BRANCH 不能快进到 wt/$TASK（已落 blocked→reopened）" 4
fi

# ---- 集成 verify 在目标目录真跑；FAIL → 原子回滚＋blocked→reopened ----
# B-W3 并发守卫：verify 窗口内目标分支被推进（≠NEWH）时 reset 会吞掉并发工作——跳过回滚保现场
NEWH_PREV=$(git -C "$TARGET_DIR" rev-parse "$TARGET_BRANCH")
if ! VOUT=$(cd "$TARGET_DIR" && timeout "${AGORA_VERIFY_TIMEOUT:-300}" bash -c "$VF" 2>&1 | tail -c 2048); then
  CURH2=$(git -C "$TARGET_DIR" rev-parse "$TARGET_BRANCH")
  if [ "$CURH2" != "$NEWH_PREV" ]; then
    bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PNAME" --event blocked \
      --task "$TASK" --reason "集成 verify 失败且窗口内目标被并发推进（$NEWH_PREV→$CURH2），已跳过回滚保现场，人工核查" >/dev/null 2>&1 || true
    fail VERIFY_FAILED "集成 verify 失败＋目标并发推进——未回滚（现场保留），人工核查 $TARGET_BRANCH" 4
  fi
  git -C "$TARGET_DIR" reset -q --hard "$PRE"
  bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PNAME" --event blocked \
    --task "$TASK" --reason "集成 verify FAIL: $(echo "$VOUT" | tail -5 | tr '\n' ' ' | tr -d '|')" >/dev/null 2>&1 || true
  bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PNAME" --event reopened \
    --task "$TASK" --reason "集成 verify 失败返工（主支已原子回滚）" >/dev/null 2>&1 || true
  fail VERIFY_FAILED "集成 verify 失败，$TARGET_BRANCH 已回滚至 $PRE（blocked→reopened 已落账）" 4
fi

# ---- merged 落账（C-W2 机械票：出票→post（验票）→销票）＋清树 ----
NEWH=$(git -C "$TARGET_DIR" rev-parse "$TARGET_BRANCH")
mkdir -p "$AGORA_HOME/.git/merge-tickets"
: > "$AGORA_HOME/.git/merge-tickets/$TASK"
bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PNAME" --event merged \
  --task "$TASK" --commit "$NEWH" --branch "$TARGET_BRANCH" >/dev/null \
  || { rm -f "$AGORA_HOME/.git/merge-tickets/$TASK"; fail LEDGER_FAILED "merged 落账失败（post.sh 详见 stderr）" 4; }
rm -f "$AGORA_HOME/.git/merge-tickets/$TASK"
git -C "$MAIN" worktree remove "$WTD" 2>/dev/null || true
git -C "$MAIN" branch -q -D "wt/$TASK" 2>/dev/null || true

printf '{"result":"merged","task":"%s","branch":"%s","commit":"%s","idempotent":false}\n' "$TASK" "$TARGET_BRANCH" "$NEWH"
