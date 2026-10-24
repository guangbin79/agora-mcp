#!/usr/bin/env bash
# post.sh —— 广场事件唯一合法写入入口（机械层核心，线性化点）
# 用法: post.sh --actor NAME@PROJ --project PROJ --event TYPE [条件字段...]
# 输出: stdout 为 JSON；失败时 stderr 为 {"code":...,"message":...} 且退出码非零
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 单源自定位：兄弟脚本/库一律本仓 scripts（gt-f6e4）

AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
LOCK_WAIT="${AGORA_LOCK_WAIT:-5}"

# 机械层确定性：跨分片检索/glob 序不受宿主 locale 影响（collation 硬化，T1 存量发现）
# 注意：verify 门与全部子进程（sync/derive/用户 verify 命令）均在 C locale 下执行——collation 敏感的 verify 写法需自证
export LC_ALL=C
fail() { python3 -c 'import json,sys; print(json.dumps({"code":sys.argv[1],"message":sys.argv[2]}, ensure_ascii=False), file=sys.stderr)' "$1" "$2"; exit "${3:-2}"; }   # 值经 json.dumps 全量转义：stderr 恒为合法 JSON（含任意控制字符），无手写转义可漂移
# ---------- 参数解析 ----------
ACTOR=""; PROJECT=""; EVENT=""; TASK=""; COMMIT=""; EVIDENCE=""
CONCLUSION=""; REASON=""; BODY=""; MENTION=""; IDEM=""; TARGET=""; CHILD=""; RUN=""; DTASK=""; BRANCH=""; SESSION=""
SETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --actor) ACTOR="$2";; --project) PROJECT="$2";; --event) EVENT="$2";;
    --task) TASK="$2";; --commit) COMMIT="$2";; --evidence) EVIDENCE="$2";;
    --conclusion) CONCLUSION="$2";; --reason) REASON="$2";; --body) BODY="$2";;
    --mention) MENTION="$2";; --idem) IDEM="$2";; --target) TARGET="$2";;
    --child) CHILD="$2";; --run) RUN="$2";; --dispatcher-task) DTASK="$2";; --branch) BRANCH="$2";; --session) SESSION="$2";;
    --set) SETS+=("$2");;
    *) fail VALIDATION_FAILED "unknown arg: $1";;
  esac; shift 2
done


# ---------- 文法校验（宣言 §5.2） ----------
case "$EVENT" in
  claimed|done|blocked|diagnosed|escalated|retired|proposal|ack|dispatched|progress|cancelled|reopened|attached|plan|merged|amended) ;;
  *) fail VALIDATION_FAILED "bad event: $EVENT";;
esac
[[ -n "$ACTOR" && -n "$PROJECT" ]] || fail VALIDATION_FAILED "actor/project required"

TASK_CLASS="claimed done blocked diagnosed escalated dispatched progress cancelled reopened attached plan merged amended"
if [[ " $TASK_CLASS " == *" $EVENT "* ]]; then
  [[ "$TASK" =~ ^gt-[a-z0-9]+$ ]] || fail VALIDATION_FAILED "task id must match gt-xxxx"
  [[ -f "$AGORA_HOME/wiki/tasks/$TASK.md" ]] || fail UNKNOWN_TASK "task not found: $TASK"
fi
[[ "$EVENT" == done && ( -z "$COMMIT" || -z "$EVIDENCE" ) ]] && fail VALIDATION_FAILED "done requires commit+evidence"
[[ "$EVENT" == plan && -z "$BODY" ]] && fail VALIDATION_FAILED "plan requires body（实施计划内容）"
[[ "$EVENT" == attached && -z "$EVIDENCE" ]] && fail VALIDATION_FAILED "attached requires evidence（<url>@<commit>，一般由 agora_attach 生成）"
[[ "$EVENT" == diagnosed && -z "$CONCLUSION" ]] && fail VALIDATION_FAILED "diagnosed requires conclusion"
[[ "$EVENT" == retired && -z "$REASON" ]] && fail VALIDATION_FAILED "retired requires reason"
[[ "$EVENT" == dispatched && -z "$TARGET" ]] && fail VALIDATION_FAILED "dispatched requires target"
[[ "$EVENT" == merged && -z "$COMMIT" ]] && fail VALIDATION_FAILED "merged requires commit（合并后分支 HEAD；集成 verify 由 merge.sh 顺序契约前置）"
[[ "$MENTION" == *all* ]] && fail VALIDATION_FAILED "@all forbidden in v0"
# mention 即 inbox 目录名：拒绝路径成分（../ 与 /），防路由写出 inbox/ 之外
if [[ -n "$MENTION" ]]; then
  IFS=',' read -ra _MS <<< "$MENTION"
  for _m in "${_MS[@]}"; do
    [[ -z "$_m" || "$_m" == *"/"* || "$_m" == *".."* ]] \
      && fail VALIDATION_FAILED "bad mention: $_m（实体名不得含 / 或 ..）"
  done
fi
# 字段值禁止 | 与换行（ABNF: value 不含 "|" 与 LF）——MENTION/ACTOR/PROJECT/IDEM 同环（账本行完整性；idem 换行=整行伪造原语）
for v in "$TASK" "$COMMIT" "$EVIDENCE" "$CONCLUSION" "$REASON" "$BODY" "$TARGET" "$CHILD" "$RUN" "$DTASK" "$BRANCH" "$SESSION" "$MENTION" "$ACTOR" "$PROJECT" "$IDEM"; do
  [[ "$v" == *"|"* || "$v" == *$'\n'* ]] && fail VALIDATION_FAILED "field value contains | or newline"
done
# IDEM 亦占 \S+ 槽（idem:）：空白撕裂行解析
# ACTOR/PROJECT 占 LINE_RE 的 \S+ 槽：任何空白（空格/制表等）都会撕裂行解析
for v in "$ACTOR" "$PROJECT" "$IDEM"; do
  [[ "$v" == *[[:space:]]* ]] && fail VALIDATION_FAILED "actor/project/idem must not contain whitespace"
done
# PROJECT 兼作 shard 文件名（log/<date>/<PROJECT>.md）：拒绝路径成分，防越界写 .md 绕过 wiki-write owner 校验
[[ "$PROJECT" == *"/"* || "$PROJECT" == *".."* ]] && fail VALIDATION_FAILED "project must not contain / or .."
# dispatched 写入侧防线（前移至预锁校验段——fail=零写入契约）：dispatcher 名来自 --actor 名部，坏名在任何写入前拒绝
if [[ "$EVENT" == dispatched ]]; then
  _DN="${ACTOR%%@*}"
  [[ -z "$_DN" || "$_DN" == *"|"* || "$_DN" == *$'\n'* || "$_DN" == *"/"* || "$_DN" == *".."* || "$_DN" == *,* || "$_DN" == *"\\"* ]] \
    && fail VALIDATION_FAILED "bad dispatcher name from actor: $_DN（实体名不得含 | / .. , \\ 或换行）"
fi

# ---------- amended：任务页机械字段修正通道（gt-b9fb 三实例成律） ----------
# 权限收窄=仅该任务页 dispatcher: actor（名部相等）；仅 wt_dir/verify/project_dir 三机械字段；
# 字段行须已存在（修正非新增）；页 frontmatter 原位改写＋amended 事件留痕——账本只追加，不改历史行
[[ ${#SETS[@]} -gt 0 && "$EVENT" != amended ]] && fail VALIDATION_FAILED "--set 仅 amended 事件可用（本次: $EVENT）"   # F3：显式拒，防静默丢弃误导操作者
_wt_dir_guard() {   # $1=value $2=page —— ocr2-H1/H2：主仓同级＋<REPO>__wt-<TASK>__* 本任务专属命名；锚点 project_dir 需名册注册域
  local _v="$1" _pg="$2" _pd _mr _vd
  _pd=$(sed -n "2,/^---\$/p" "$_pg" | grep -m1 '^project_dir:' | sed 's/^project_dir:[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/')
  _mr=$(PYTHONPATH="$SCRIPTS_DIR" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "${_pd:-/nonexistent}" 2>/dev/null || true)
  [[ -n "$_mr" && -d "$_mr" ]] || fail VALIDATION_FAILED "wt_dir 修正需任务页 project_dir 可解析主仓"
  _vd=$(realpath "$(dirname "$_v")" 2>/dev/null) || _vd=$(dirname "$_v")
  [[ "$_vd" == "$(dirname "$_mr")" ]] || fail VALIDATION_FAILED "wt_dir 须为主仓同级命名域（../<REPO>__wt-*）: $_v"
  case "$(basename "$_v")" in
    "$(basename "$_mr")"__wt-"${TASK}"__*) ;;
    *) fail VALIDATION_FAILED "wt_dir 须为 <REPO>__wt-${TASK}__* 本任务专属命名（防指他任务树/主仓本体）: $_v" ;;
  esac
}
if [[ "$EVENT" == amended ]]; then
  [[ ${#SETS[@]} -gt 0 ]] || fail VALIDATION_FAILED "amended 需要至少一个 --set key=value"
  PAGE_A="$AGORA_HOME/wiki/tasks/$TASK.md"
  [[ $(head -1 "$PAGE_A") == "---" ]] || fail VALIDATION_FAILED "任务页缺 frontmatter（修正无锚）: $TASK"   # ocr2：锚定段须以开界符为前提
  _HAS_WT=0; _HAS_PD=0
  for _s in "${SETS[@]}"; do case "${_s%%=*}" in wt_dir) _HAS_WT=1;; project_dir) _HAS_PD=1;; esac; done
  [[ $_HAS_WT -eq 1 && $_HAS_PD -eq 1 ]] && fail VALIDATION_FAILED "project_dir 与 wt_dir 不得同次混改（锚点漂移窗，ocr2）"
  # ocr-D：dispatcher 权威读同锚 frontmatter——正文 prose 行 `dispatcher: x` 不得充当授权锚
  DISP_A=$(sed -n "2,/^---\$/p" "$PAGE_A" | grep -m1 '^dispatcher:' | sed 's/^dispatcher:[[:space:]]*//; s/[[:space:]]*$//' || true)
  [[ -n "$DISP_A" ]] || fail AMEND_FORBIDDEN "任务页无 dispatcher 标注（未派发过，无修正主体）: $TASK"
  [[ "$DISP_A" == "${ACTOR%%@*}" ]] || fail AMEND_FORBIDDEN "仅该任务 dispatcher actor 可修正（page: $DISP_A ≠ actor: ${ACTOR%%@*}）"
  for _s in "${SETS[@]}"; do
    [[ "$_s" == *=* ]] || fail VALIDATION_FAILED "--set 需要 key=value 形态: $_s"
    _K="${_s%%=*}"; _V="${_s#*=}"
    case "$_K" in wt_dir|verify|project_dir) ;; *) fail VALIDATION_FAILED "不可修正字段: $_K（仅 wt_dir/verify/project_dir）";; esac
    # C-F1（C 册）：守卫同锚 frontmatter 区——正文 prose 行不得让「行已存在」误放行（否则 amend 静默 no-op，账页背离）
    sed -n "2,/^---\$/p" "$PAGE_A" | grep -q "^${_K}:" || fail VALIDATION_FAILED "frontmatter 字段行不存在（修正非新增）: $_K"
    if [[ "$_K" == wt_dir ]]; then   # C-F3（C 册）＋ocr2-H1/H2：命名域收敛
      _wt_dir_guard "$_V" "$PAGE_A"
    fi
    if [[ "$_K" == project_dir ]]; then   # ocr2-H2：project_dir 是命名域锚点，改它须落名册注册域（防两跳迁锚绕过 C-F3）
      _ER=$(PYTHONPATH="$SCRIPTS_DIR" python3 - "$AGORA_HOME" "$_V" <<'PYEOF'
import sys
import agora_lib   # 经 PYTHONPATH=本仓 scripts 导入（单源，gt-f6e4）
r = agora_lib.resolve_entity(sys.argv[1], sys.argv[2])
print(r[0] if r else "")
PYEOF
)
      [[ -n "$_ER" ]] || fail VALIDATION_FAILED "project_dir 修正须指向名册已注册目录（防迁锚绕过命名域）: $_V"
    fi
    # gt-064b：| 放行（页 YAML 域合法）——账本留痕走 b64 转义（见 SETS_ENC）；换行/回车仍拒（页单行＋账本 ABNF，对齐 task-create 不变量）
    [[ "$_V" == *$'\n'* || "$_V" == *$'\r'* ]] && fail VALIDATION_FAILED "set 值含换行/回车"
    _VT="${_V#"${_V%%[![:space:]]*}"}"   # R2 评审：先去前导空白再判——YAML 分隔空格不改变首标量字符
    [[ "$_VT" == [\|\>\&\*#\%\@\`]* ]] && fail VALIDATION_FAILED "set 值不得以 YAML 指示符开头（| > & * # % @ 反引号，含前导空白变体）: $_K"   # R1/R2 评审：块标量/锚/注释指示符致严格解析器下契约失真；[ { ! 等合法命令起始符为记录在案残留（根治=落页加引号，涉他脚本读者，另立任务）
    [[ -n "$_V" ]] || fail VALIDATION_FAILED "set 值不得为空: $_K"   # ocr-B：空值静默造不一致契约态（wt_dir=空→wt:true 残留）
    [[ "$_K" == verify || "$_V" != *".."* ]] || fail VALIDATION_FAILED "$_K 路径不得含 ..: $_V"
  done
  # gt-064b 留痕转义：值落事件行一律 key=base64(值)——| 受事件行域禁令，b64 后零 |；key 明文保 C-F2 set:verify= 锚
  SETS_ENC=()
  for _s in "${SETS[@]}"; do
    SETS_ENC+=("$(printf '%s=' "${_s%%=*}")$(printf '%s' "${_s#*=}" | base64 | tr -d '\n')")
  done
  [[ -z "$BODY" ]] && BODY=$(printf '%s' "${SETS_ENC[*]}")   # 留痕行缺省携带修正对（b64 形态）
  _SETS_IN_IDEM=1   # 标记：idem 段与 LINE 段消费（sets 必须进 idem 材料，防同 body 异 set 撞 dedup 吞修正）
fi

# ---------- 验证门（宣言 §6：done 由机械层执行 verify 背书；两段制——wt_dir 优先） ----------
DERIVED=()
if [[ "$EVENT" == done ]]; then
  # C-F2（C 册）＋ocr2：任务曾 amend verify 合同 → derived 显式标注。判读走专用 set: 字段（body 可被 --body 覆盖，
  # 子串误判由字段定界消除）；find -print0|xargs -0 -r 防空 find 挂 stdin 与路径空格撕裂
  _AMV=$(find "$AGORA_HOME/log" -mindepth 2 -name "*.md" -type f -print0 2>/dev/null | sort -z | xargs -0 -r cat 2>/dev/null \
    | grep -E "(^|[|] )task:$TASK( |$)" | grep "event:amended" | grep -cE "\| set:(verify=|[^|]* verify=)" || true)
  [[ "${_AMV:-0}" -gt 0 ]] && DERIVED+=("verify_amended")
  TASK_PAGE="$AGORA_HOME/wiki/tasks/$TASK.md"
  VERIFY=$(grep -m1 '^verify:' "$TASK_PAGE" | sed 's/^verify:[[:space:]]*//; s/^"\(.*\)"$/\1/' || true)
  PROJDIR=$(grep -m1 '^project_dir:' "$TASK_PAGE" | sed 's/^project_dir:[[:space:]]*//; s/^"\(.*\)"$/\1/' || true)
  WTDIR=$(grep -m1 '^wt_dir:' "$TASK_PAGE" | sed 's/^wt_dir:[[:space:]]*//; s/^"\(.*\)"$/\1/' || true)
  [[ -z "$VERIFY" ]] && fail VALIDATION_FAILED "task $TASK has no verify: command"
  # verify 锚点重建（gt-2845①）：wt_dir 缺失→按 wt/<task> 分支原地重建（复用 dispatch/merge 既有锚点逻辑）；
  # 分支亦缺失→VERIFY_FAILED 明确报错（禁回退 project_dir——gt-ac14 假绿教训）。
  # 重建段与 dispatch.sh 预检重建同锁互斥（评审 B-1/ocr-6：prune/add 毫秒级并发窗收敛）
  if [[ -n "$WTDIR" && ! -d "$WTDIR" ]]; then
    RB_IN=$(realpath "${PROJDIR:-$WTDIR}" 2>/dev/null) || RB_IN="${PROJDIR:-$WTDIR}"   # 父链删净时保底裸路径（评审 R2-F1：stderr JSON 契约＋cwd 污染）
    WT_MAIN=$(PYTHONPATH="$SCRIPTS_DIR" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "$RB_IN")
    [[ -e "$WT_MAIN/.git" ]] || fail VERIFY_FAILED "verify 锚点重建失败：主仓不可用: $WT_MAIN" 4
    RB_RC=0
    (
      flock -w "$LOCK_WAIT" 9 || exit 3
      git -C "$WT_MAIN" worktree prune
      git -C "$WT_MAIN" show-ref --verify --quiet "refs/heads/wt/$TASK" || exit 5
      git -C "$WT_MAIN" worktree add -q "$WTDIR" "wt/$TASK" || exit 9
    ) 9>"$AGORA_HOME/.git/post.lock" || RB_RC=$?
    case "$RB_RC" in
      0) DERIVED+=("wt_rebuilt:$TASK") ;;
      3) fail VERIFY_FAILED "verify 锚点重建锁超时（${LOCK_WAIT}s）" 4 ;;
      5) fail VERIFY_FAILED "wt_dir 与 wt/$TASK 分支双缺失（禁回退 project_dir）: $WTDIR" 4 ;;
      *) fail VERIFY_FAILED "verify 锚点重建失败（挂 wt/$TASK 分支）: $WTDIR" 4 ;;
    esac
    # setup 钩子（对齐 dispatch.sh：重建树缺 node_modules/venv，env 依赖的 verify 否则假失败——评审 ocr-5）
    SETUPCMD=""
    for pf in "$AGORA_HOME"/wiki/projects/*.md; do
      [[ -f "$pf" ]] || continue
      _pp=$(sed -n 's/^path:[[:space:]]*//p' "$pf" | head -1)
      [[ -z "$_pp" ]] && continue
      [[ "$(realpath "$_pp" 2>/dev/null)" = "$WT_MAIN" ]] && { SETUPCMD=$(sed -n 's/^setup:[[:space:]]*//p' "$pf" | head -1); break; }
    done
    if [[ -n "$SETUPCMD" ]]; then
      (cd "$WTDIR" && timeout "${AGORA_SETUP_TIMEOUT:-600}" bash -c "$SETUPCMD") >/dev/null 2>&1 \
        || fail VERIFY_FAILED "重建树 setup: 失败（cmd: $SETUPCMD；env 不全不假验收）" 4
    fi
  fi
  VERIFY_OUT=$(cd "${WTDIR:-${PROJDIR:-$AGORA_HOME}}" && timeout "${AGORA_VERIFY_TIMEOUT:-300}" bash -c "$VERIFY" 2>&1 | tail -c 2048) && RC=0 || RC=$?
  if [[ $RC -ne 0 ]]; then
    EVENT="verify_failed"; DERIVED+=("verify_failed")
    VERIFY_NOTE=$(echo "$VERIFY_OUT" | tail -5 | tr '\n' ' ' | tr -d '|')
  fi
fi

# ---------- merged 机械校验（v1.32：顺序契约——post.sh 不跑 verify，只验 commit==目标分支 HEAD 防绕过；
# C-W2 机械票：merged 仅可经 merge.sh 落账——$AGORA_HOME/.git/merge-tickets/<task> 由 merge.sh 出票） ----------
if [[ "$EVENT" == "merged" ]]; then
  [[ -e "$AGORA_HOME/.git/merge-tickets/$TASK" ]] \
    || fail MERGE_TICKET_REQUIRED "merged 仅可经 merge.sh 落账（机械票缺失；直接 post 会被拒）" 4
  MPAGE="$AGORA_HOME/wiki/tasks/$TASK.md"
  [[ -f "$MPAGE" ]] || fail VALIDATION_FAILED "task page missing: $TASK"
  MPDIR=$(grep -m1 '^project_dir:' "$MPAGE" | sed 's/^project_dir:[[:space:]]*//; s/^"\(.*\)"$/\1/' || true)
  [[ -z "$MPDIR" ]] && fail VALIDATION_FAILED "merged 需要任务页 project_dir（无 project 上下文不可验分支）"
  MBR="$BRANCH"
  if [ -z "$MBR" ]; then
    MBR=$(git -C "$MPDIR" symbolic-ref -q --short HEAD 2>/dev/null || echo HEAD)
  fi
  MHEAD=$(git -C "$MPDIR" rev-parse --verify --quiet "$MBR" 2>/dev/null) \
    || fail VALIDATION_FAILED "branch 不可解析: $MBR（project_dir=$MPDIR）"
  [[ "$COMMIT" = "$MHEAD" ]] || fail MERGE_COMMIT_MISMATCH "commit≠branch HEAD（$COMMIT vs $MBR=$MHEAD）" 4
fi

# ---------- 线性化点：flock 内完成 拉取+校验+写入+提交+推导+推送 ----------
exec 9>"$AGORA_HOME/.git/post.lock"
flock -w "$LOCK_WAIT" 9 || fail LOCK_TIMEOUT "flock timeout after ${LOCK_WAIT}s；可安全重试，反复失败先 agora_doctor" 3

# 同步纪律：写前必见全网最新（sync.sh 在无远端时零开销返回 off）
SYNC_PRE=$(bash "$SCRIPTS_DIR/sync.sh" pre 2>/dev/null || true)
SW=$(echo "$SYNC_PRE" | sed -n 's/.*"warn:\([a-z_]*\)".*/\1/p')
[[ -n "$SW" ]] && DERIVED+=("sync_warn:$SW")

# 幂等 idem 先行计算（v1.31：不含 dispatcher 自动追加的 MENTION——幂等语义与 v1.30 前一致）
if [[ -z "$IDEM" ]]; then
  IDEM_INPUT="$ACTOR|$EVENT|$TASK|$COMMIT|$EVIDENCE|$CONCLUSION|$REASON|$BODY|$MENTION|$TARGET|$CHILD"
  [[ -n "$RUN" ]] && IDEM_INPUT="$IDEM_INPUT|$RUN"
  [[ -n "$SESSION" ]] && IDEM_INPUT="$IDEM_INPUT|$SESSION"
  IDEM=$(printf '%s' "$IDEM_INPUT" | sha1sum | cut -c1-8)
  _IDEM_DERIVED=1
fi
[[ -n "${_SETS_IN_IDEM:-}" && -n "${_IDEM_DERIVED:-}" ]] && { IDEM_INPUT="$IDEM_INPUT|${SETS[*]}"; IDEM=$(printf '%s' "$IDEM_INPUT" | sha1sum | cut -c1-8); }   # ocr2：sets 进 idem 材料（显式 --idem 尊重调用方）

# 派生回报链：dispatched 时把 dispatcher 写入任务页；done/plan 时自动 @提及 dispatcher（plan 的 ack 回路由机制保证，v1.30）
# 前移至写入前段（fail=零写入契约，v1.31）：dispatcher 读取+校验+拼接不产生任何落盘副作用
if [[ ( "$EVENT" == done || "$EVENT" == plan ) && -n "$TASK" ]]; then
  DISP=$(grep -m1 '^dispatcher:' "$AGORA_HOME/wiki/tasks/$TASK.md" | sed 's/^dispatcher:[[:space:]]*//; s/[[:space:]]*$//' || true)
  # 读取侧兜底：dispatcher 来自任务页（历史脏数据/手改可达），先校验再使用——与写入侧同口径（含反斜杠）
  if [[ -n "$DISP" ]]; then
    [[ "$DISP" == *"|"* || "$DISP" == *$'\n'* || "$DISP" == *"/"* || "$DISP" == *".."* || "$DISP" == *,* || "$DISP" == *\\* ]] \
      && fail VALIDATION_FAILED "bad dispatcher on task page: $DISP（实体名不得含 | / .. , \\ 或换行）"
    [[ "$DISP" != "${ACTOR%%@*}" ]] || DISP=""
  fi
  # 精确匹配（逗号分隔逐项+trim）：防子串误吞与空白漏配（mention 已含 bossy / " boss" 不误吞 boss）
  if [[ -n "$DISP" ]]; then
    if [[ -z "$MENTION" ]]; then MENTION="$DISP"
    else
      _HAS=0; IFS=',' read -ra _MS2 <<< "$MENTION"
      for _m in "${_MS2[@]}"; do
        _m="${_m#"${_m%%[![:space:]]*}"}"; _m="${_m%"${_m##*[![:space:]]}"}"
        [[ "$_m" == "$DISP" ]] && { _HAS=1; break; }
      done
      [[ $_HAS -eq 0 ]] && MENTION="$MENTION,$DISP"
    fi
  fi
fi

DATE=$(date +%F)   # 单点取值：午夜翻牌窗口内 SHARD 与 REF 必须同日
SHARD_DIR="$AGORA_HOME/log/$DATE"; mkdir -p "$SHARD_DIR"
SHARD="$SHARD_DIR/$PROJECT.md"
[[ -f "$SHARD" ]] || echo '<!-- format: git-agora-log v1 -->' > "$SHARD"

# 幂等：idem 已于写入前段计算（见上「幂等 idem 先行计算」）。
# 去重窗口 = 该 actor 在该 task 上的"最近一条"事件：连续重复 = 重试，静默成功；
# 中间隔了别的事件的相同 idem = 合法的新状态迁移（如 reopen 后再次 claim），必须落账。
if [[ -n "$TASK" ]]; then
  LAST_EV=$(grep -F " | actor:$ACTOR | " "$SHARD" 2>/dev/null | grep -E 'task:'"$TASK"'( \||$)' | tail -1 || true)
else
  LAST_EV=$(grep -F " | actor:$ACTOR | " "$SHARD" 2>/dev/null | tail -1 || true)
fi
if [[ -n "$LAST_EV" ]] && echo "$LAST_EV" | grep -qF "idem:$IDEM"; then
  EXIST=$(echo "$LAST_EV" | sed -n 's/.*seq:\([0-9]*\).*/\1/p')
  echo "{\"seq\":$EXIST,\"dedup\":true,\"derived\":[]}"
  exit 0
fi

# per-actor seq 与 seen（seen = 分片当前事件数）
# 双侧 " | " 定界：防前缀撞名（wd@a vs wd@ab），也防 body/conclusion 引用 actor 令牌造成计数虚高断档
SEQ=$(grep -cF " | actor:$ACTOR | " "$SHARD" 2>/dev/null || true); SEQ=$((SEQ+1))
SEEN=$(grep -c '^- seq:' "$SHARD" 2>/dev/null || true)
TS=$(date --iso-8601=seconds)

LINE="- seq:$SEQ | ts:$TS | actor:$ACTOR | event:$EVENT | idem:$IDEM | seen:$PROJECT@$SEEN"
[[ -n "$TASK" ]] && LINE="$LINE | task:$TASK"
[[ -n "$COMMIT" ]] && LINE="$LINE | commit:$COMMIT"
[[ -n "$EVIDENCE" ]] && LINE="$LINE | evidence:$EVIDENCE"
[[ -n "$CONCLUSION" ]] && LINE="$LINE | conclusion:$CONCLUSION"
[[ -n "$REASON" ]] && LINE="$LINE | reason:$REASON"
[[ -n "$TARGET" ]] && LINE="$LINE | target:$TARGET"
[[ -n "$CHILD" ]] && LINE="$LINE | child:$CHILD"
[[ -n "$RUN" ]] && LINE="$LINE | run:$RUN"
[[ -n "$SESSION" ]] && LINE="$LINE | session:$SESSION"
[[ -n "$DTASK" ]] && LINE="$LINE | dispatcher_task:$DTASK"
[[ -n "$BRANCH" ]] && LINE="$LINE | branch:$BRANCH"
[[ -n "${VERIFY_NOTE:-}" ]] && LINE="$LINE | verify_output:$VERIFY_NOTE"
[[ -n "$BODY" ]] && LINE="$LINE | body:$BODY"
[[ -n "$MENTION" ]] && LINE="$LINE | mention:$MENTION"
[[ -n "${_SETS_IN_IDEM:-}" ]] && LINE="$LINE | set:$(printf '%s' "${SETS_ENC[*]}")"   # ocr2：修正对专用留痕字段（C-F2 判读锚点；值 b64 转义 gt-064b）

# amended：页 frontmatter 原位改写——F2（B 册）：置于账本 append 之前，中断（append 前 sed 后）时
# 页领先账本、同参重试无 dedup 挡路幂等收敛；反序则 dedup 静默吞修复致账本↔页永久分歧。
# F1（B 册）：sed 锚定 2,/^---$/（frontmatter 区）——正文引用旧合同的 `verify:` 行不被连带改写。
# 校验已前移；| 定界防值注入——set 值拒换行（| 自 gt-064b 放行），& | \ sed 转义后原值落页
if [[ "$EVENT" == amended ]]; then
  # ocr-A：锁内复核——sync pre 可拉远端页变更，授权与字段存在性以写前一刻为准（反例：远端改派后旧授权改写）
  DISP_B=$(sed -n "2,/^---\$/p" "$PAGE_A" | grep -m1 '^dispatcher:' | sed 's/^dispatcher:[[:space:]]*//; s/[[:space:]]*$//' || true)
  [[ "$DISP_B" == "${ACTOR%%@*}" ]] || fail AMEND_FORBIDDEN "锁内复核 dispatcher 不符（page: ${DISP_B:-∅} ≠ ${ACTOR%%@*}）"
  for _s in "${SETS[@]}"; do   # ocr2：先全量复核再统一改写——set#1 已改 set#2 复核败的半应用态不落盘
    _K="${_s%%=*}"
    sed -n "2,/^---\$/p" "$PAGE_A" | grep -q "^${_K}:" || fail VALIDATION_FAILED "字段行不存在（锁内复核）: $_K"
    [[ "$_K" == wt_dir ]] && _wt_dir_guard "${_s#*=}" "$PAGE_A"   # 命名域以写前一刻页值为准（sync 漂移窗）
  done
  for _s in "${SETS[@]}"; do
    _K="${_s%%=*}"; _V="${_s#*=}"
    _E="${_V//\\/\\\\}"; _E="${_E//&/\\&}"; _E="${_E//|/\\|}"   # gt-064b：竖线为 sed 分隔符，replacement 内转义为字面
    sed -i "2,/^---\$/s|^${_K}:.*|${_K}: ${_E}|" "$PAGE_A"
  done
fi

echo "$LINE" >> "$SHARD"
REF="log/$DATE/$PROJECT.md:$(grep -c '^- seq:' "$SHARD")"

# claim 冲突检测（账本是事实：仍落账，只标注 derived）
# 跨分片检索：任务可能被其他项目的 actor 认领，只看本分片会漏报（§3.4 副作用可见性）
if [[ "$EVENT" == claimed ]]; then
  FIRST=$(cat $(find "$AGORA_HOME/log" -mindepth 2 -name "*.md" -type f 2>/dev/null | sort) 2>/dev/null | grep -E 'task:'"$TASK"'( \||$)' | grep 'event:claimed' | head -1 | sed -n 's/.*actor:\([^ |]*\).*/\1/p' || true)
  if [[ -n "$FIRST" && "$FIRST" != "$ACTOR" ]]; then DERIVED+=("claim_conflict:$FIRST"); fi
fi

if [[ "$EVENT" == dispatched && -n "$TASK" ]]; then
  TP="$AGORA_HOME/wiki/tasks/$TASK.md"
  # 守卫已前移至预锁校验段（fail=零写入契约）；此处仅落 dispatcher 标注
  grep -q '^dispatcher:' "$TP" || { [[ $(head -1 "$TP") == "---" ]] && sed -i "1a dispatcher: $_DN" "$TP"; } || true
fi

# @提及路由：inbox 指针（不复制内容）
if [[ -n "$MENTION" ]]; then
  IFS=',' read -ra MS <<< "$MENTION"
  for m in "${MS[@]}"; do
    m="${m#"${m%%[![:space:]]*}"}"; m="${m%"${m##*[![:space:]]}"}"   # trim：mention 项可带空白（校验只拒空项）
    [[ -z "$m" ]] && continue
    mkdir -p "$AGORA_HOME/inbox/$m"
    printf -- '- from:%s | ts:%s | ref:%s | summary:%s %s\n' "$ACTOR" "$TS" "$REF" "$EVENT" "$TASK" \
      > "$AGORA_HOME/inbox/$m/$(date +%s%N).md"
  done
  DERIVED+=("routed:${#MS[@]}")
fi

cd "$AGORA_HOME"
export AGORA_MECHANICAL=1   # pre-commit hook 的机械层凭证（install-hooks.sh）
git add -A >/dev/null
git -c user.name="$ACTOR" -c user.email="$ACTOR@local" commit -qm "event:$EVENT ${TASK:-} by $ACTOR"
bash "$SCRIPTS_DIR/derive-board.sh" >/dev/null 2>&1 || true
git add -A >/dev/null; git commit -qm "derive: board" >/dev/null 2>&1 || true

# T3 ack→注入（L2）：任务最新 dispatched 带 session: 且 API 开 → inject「ack 已落账，继续」best-effort；
# 失败仅 derived 注记不阻塞 ack；注入侧按 sid 幂等去重（inject-tickets，沿 merge-tickets 先例 host-local）。
# 这是 plan-ack 死锁窗的闭合面：ack 无需子会话轮询收件箱，经注入直达活会话（delegation §七 的 L2 补偿）。
if [[ "$EVENT" == "ack" && -n "$TASK" && "${AGORA_RUNTIME_API:-1}" != "0" && "${AGORA_RUNTIME:-opencode}" == "opencode" && -f "$SCRIPTS_DIR/runtime/opencode.sh" ]]; then
  INJ_SID=$(cat $(find "$AGORA_HOME/log" -mindepth 2 -name "*.md" -type f 2>/dev/null | sort) 2>/dev/null \
    | grep -E "(^|[|] )task:$TASK( |\$)" | grep "event:dispatched" \
    | grep -o "session:[^| ]*" | tail -1 | cut -d: -f2 || true)
  if [[ -n "$INJ_SID" ]]; then
    if [[ -e "$AGORA_HOME/.git/inject-tickets/$INJ_SID" ]]; then
      DERIVED+=("inject_dedup")
    elif timeout "${AGORA_INJECT_TIMEOUT:-15}" bash "$SCRIPTS_DIR/runtime/opencode.sh" inject "$INJ_SID" "ack 已落账，继续" >/dev/null 2>&1; then
      mkdir -p "$AGORA_HOME/.git/inject-tickets"; : > "$AGORA_HOME/.git/inject-tickets/$INJ_SID"
      DERIVED+=("injected")
    else
      DERIVED+=("inject_failed")
    fi
  fi
fi

DJSON="[]"
if [[ ${#DERIVED[@]} -gt 0 ]]; then
  DJSON=$(printf '%s\n' "${DERIVED[@]}" | python3 -c 'import json,sys;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
fi

# 同步纪律：写后推送（失败不拒事件，下次 pre 合并重试）
SYNC_POST=$(bash "$SCRIPTS_DIR/sync.sh" post 2>/dev/null || true)
SW=$(echo "$SYNC_POST" | sed -n 's/.*"warn:\([a-z_]*\)".*/\1/p')
if [[ -n "$SW" ]]; then
  DJSON=$(echo "$DJSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.append("sync_warn:'"$SW"'"); print(json.dumps(d))')
fi
python3 - "$SEQ" "log/$DATE/$PROJECT.md" "$REF" "$TS" "$DJSON" <<'PY'
import json, sys
print(json.dumps({"seq": int(sys.argv[1]), "shard": sys.argv[2], "ref": sys.argv[3],
                  "ts": sys.argv[4], "derived": json.loads(sys.argv[5]), "dedup": False},
                 ensure_ascii=False, separators=(",", ":")))  # 紧凑分隔符：dispatch sed / REF 提取按无空格契约解析
PY

[[ "$EVENT" == verify_failed ]] && fail VERIFY_FAILED "verify 失败（见事件 verify_output）；先本地复现修复再发 done" 4
exit 0
