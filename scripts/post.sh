#!/usr/bin/env bash
# post.sh —— 广场事件唯一合法写入入口（机械层核心，线性化点）
# 用法: post.sh --actor NAME@PROJ --project PROJ --event TYPE [条件字段...]
# 输出: stdout 为 JSON；失败时 stderr 为 {"code":...,"message":...} 且退出码非零
set -euo pipefail

AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
LOCK_WAIT="${AGORA_LOCK_WAIT:-5}"

# 机械层确定性：跨分片检索/glob 序不受宿主 locale 影响（collation 硬化，T1 存量发现）
# 注意：verify 门与全部子进程（sync/derive/用户 verify 命令）均在 C locale 下执行——collation 敏感的 verify 写法需自证
export LC_ALL=C
fail() { python3 -c 'import json,sys; print(json.dumps({"code":sys.argv[1],"message":sys.argv[2]}, ensure_ascii=False), file=sys.stderr)' "$1" "$2"; exit "${3:-2}"; }   # 值经 json.dumps 全量转义：stderr 恒为合法 JSON（含任意控制字符），无手写转义可漂移
# ---------- 参数解析 ----------
ACTOR=""; PROJECT=""; EVENT=""; TASK=""; COMMIT=""; EVIDENCE=""
CONCLUSION=""; REASON=""; BODY=""; MENTION=""; IDEM=""; TARGET=""; CHILD=""; RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --actor) ACTOR="$2";; --project) PROJECT="$2";; --event) EVENT="$2";;
    --task) TASK="$2";; --commit) COMMIT="$2";; --evidence) EVIDENCE="$2";;
    --conclusion) CONCLUSION="$2";; --reason) REASON="$2";; --body) BODY="$2";;
    --mention) MENTION="$2";; --idem) IDEM="$2";; --target) TARGET="$2";;
    --child) CHILD="$2";; --run) RUN="$2";;
    *) fail VALIDATION_FAILED "unknown arg: $1";;
  esac; shift 2
done


# ---------- 文法校验（宣言 §5.2） ----------
case "$EVENT" in
  claimed|done|blocked|diagnosed|escalated|retired|proposal|ack|dispatched|progress|cancelled|reopened|attached|plan) ;;
  *) fail VALIDATION_FAILED "bad event: $EVENT";;
esac
[[ -n "$ACTOR" && -n "$PROJECT" ]] || fail VALIDATION_FAILED "actor/project required"

TASK_CLASS="claimed done blocked diagnosed escalated dispatched progress cancelled reopened attached plan"
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
for v in "$TASK" "$COMMIT" "$EVIDENCE" "$CONCLUSION" "$REASON" "$BODY" "$TARGET" "$CHILD" "$RUN" "$MENTION" "$ACTOR" "$PROJECT" "$IDEM"; do
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

# ---------- 验证门（宣言 §6：done 由机械层执行 verify 背书） ----------
DERIVED=()
if [[ "$EVENT" == done ]]; then
  TASK_PAGE="$AGORA_HOME/wiki/tasks/$TASK.md"
  VERIFY=$(grep -m1 '^verify:' "$TASK_PAGE" | sed 's/^verify:[[:space:]]*//; s/^"\(.*\)"$/\1/' || true)
  PROJDIR=$(grep -m1 '^project_dir:' "$TASK_PAGE" | sed 's/^project_dir:[[:space:]]*//; s/^"\(.*\)"$/\1/' || true)
  [[ -z "$VERIFY" ]] && fail VALIDATION_FAILED "task $TASK has no verify: command"
  VERIFY_OUT=$(cd "${PROJDIR:-$AGORA_HOME}" && timeout "${AGORA_VERIFY_TIMEOUT:-300}" bash -c "$VERIFY" 2>&1 | tail -c 2048) && RC=0 || RC=$?
  if [[ $RC -ne 0 ]]; then
    EVENT="verify_failed"; DERIVED+=("verify_failed")
    VERIFY_NOTE=$(echo "$VERIFY_OUT" | tail -5 | tr '\n' ' ' | tr -d '|')
  fi
fi

# ---------- 线性化点：flock 内完成 拉取+校验+写入+提交+推导+推送 ----------
exec 9>"$AGORA_HOME/.git/post.lock"
flock -w "$LOCK_WAIT" 9 || fail LOCK_TIMEOUT "flock timeout after ${LOCK_WAIT}s；可安全重试，反复失败先 agora_doctor" 3

# 同步纪律：写前必见全网最新（sync.sh 在无远端时零开销返回 off）
SYNC_PRE=$(bash "$AGORA_HOME/scripts/sync.sh" pre 2>/dev/null || true)
SW=$(echo "$SYNC_PRE" | sed -n 's/.*"warn:\([a-z_]*\)".*/\1/p')
[[ -n "$SW" ]] && DERIVED+=("sync_warn:$SW")

DATE=$(date +%F)   # 单点取值：午夜翻牌窗口内 SHARD 与 REF 必须同日
SHARD_DIR="$AGORA_HOME/log/$DATE"; mkdir -p "$SHARD_DIR"
SHARD="$SHARD_DIR/$PROJECT.md"
[[ -f "$SHARD" ]] || echo '<!-- format: git-agora-log v1 -->' > "$SHARD"

# 幂等：默认 idem = sha1(actor|event|task|条件字段)。
# 去重窗口 = 该 actor 在该 task 上的"最近一条"事件：连续重复 = 重试，静默成功；
# 中间隔了别的事件的相同 idem = 合法的新状态迁移（如 reopen 后再次 claim），必须落账。
if [[ -z "$IDEM" ]]; then
  IDEM_INPUT="$ACTOR|$EVENT|$TASK|$COMMIT|$EVIDENCE|$CONCLUSION|$REASON|$BODY|$MENTION|$TARGET|$CHILD"
  [[ -n "$RUN" ]] && IDEM_INPUT="$IDEM_INPUT|$RUN"
  IDEM=$(printf '%s' "$IDEM_INPUT" | sha1sum | cut -c1-8)
fi
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

# 派生回报链：dispatched 时把 dispatcher 写入任务页；done/plan 时自动 @提及 dispatcher（plan 的 ack 回路由机制保证，v1.30）
if [[ ( "$EVENT" == done || "$EVENT" == plan ) && -n "$TASK" ]]; then
  DISP=$(grep -m1 '^dispatcher:' "$AGORA_HOME/wiki/tasks/$TASK.md" | sed 's/^dispatcher:[[:space:]]*//' || true)
  if [[ -n "$DISP" && "$DISP" != "${ACTOR%%@*}" && "$MENTION" != *"$DISP"* ]]; then
    # 读取侧兜底：dispatcher 来自任务页（历史脏数据/手改可达），追加前按 mention 同口径校验
    [[ -z "$DISP" || "$DISP" == *"|"* || "$DISP" == *$'\n'* || "$DISP" == *"/"* || "$DISP" == *".."* || "$DISP" == *,* ]] \
      && fail VALIDATION_FAILED "bad dispatcher on task page: $DISP（实体名不得含 | / .. 或换行）"
    MENTION="${MENTION:+$MENTION,}$DISP"
  fi
fi

LINE="- seq:$SEQ | ts:$TS | actor:$ACTOR | event:$EVENT | idem:$IDEM | seen:$PROJECT@$SEEN"
[[ -n "$TASK" ]] && LINE="$LINE | task:$TASK"
[[ -n "$COMMIT" ]] && LINE="$LINE | commit:$COMMIT"
[[ -n "$EVIDENCE" ]] && LINE="$LINE | evidence:$EVIDENCE"
[[ -n "$CONCLUSION" ]] && LINE="$LINE | conclusion:$CONCLUSION"
[[ -n "$REASON" ]] && LINE="$LINE | reason:$REASON"
[[ -n "$TARGET" ]] && LINE="$LINE | target:$TARGET"
[[ -n "$CHILD" ]] && LINE="$LINE | child:$CHILD"
[[ -n "$RUN" ]] && LINE="$LINE | run:$RUN"
[[ -n "${VERIFY_NOTE:-}" ]] && LINE="$LINE | verify_output:$VERIFY_NOTE"
[[ -n "$BODY" ]] && LINE="$LINE | body:$BODY"
[[ -n "$MENTION" ]] && LINE="$LINE | mention:$MENTION"
echo "$LINE" >> "$SHARD"
REF="log/$DATE/$PROJECT.md:$(grep -c '^- seq:' "$SHARD")"

# claim 冲突检测（账本是事实：仍落账，只标注 derived）
# 跨分片检索：任务可能被其他项目的 actor 认领，只看本分片会漏报（§3.4 副作用可见性）
if [[ "$EVENT" == claimed ]]; then
  FIRST=$(cat "$AGORA_HOME"/log/*/*.md 2>/dev/null | grep -E 'task:'"$TASK"'( \||$)' | grep 'event:claimed' | head -1 | sed -n 's/.*actor:\([^ |]*\).*/\1/p' || true)
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
bash "$AGORA_HOME/scripts/derive-board.sh" >/dev/null 2>&1 || true
git add -A >/dev/null; git commit -qm "derive: board" >/dev/null 2>&1 || true

DJSON="[]"
if [[ ${#DERIVED[@]} -gt 0 ]]; then
  DJSON=$(printf '%s\n' "${DERIVED[@]}" | python3 -c 'import json,sys;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
fi

# 同步纪律：写后推送（失败不拒事件，下次 pre 合并重试）
SYNC_POST=$(bash "$AGORA_HOME/scripts/sync.sh" post 2>/dev/null || true)
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
