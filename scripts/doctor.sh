#!/usr/bin/env bash
# doctor.sh —— 自检与恢复（宣言 §6：任何故障 MUST 有文档化恢复路径）
# 用法: doctor.sh [--fix]；退出码 0=全绿 1=有 fail
set -euo pipefail
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
FIX="${1:-}"
FAIL=0

ok()   { echo "ok   | $1"; }
warn() { echo "warn | $1"; }
bad()  { echo "fail | $1 | 恢复: $2"; FAIL=1; }

# 1. seq 对账：每 actor 在每分片内 seq 连续无重号
SEQ_BAD=$(python3 - <<'PYEOF'
import glob, re, collections, os
HOME = os.environ["AGORA_HOME"]
bad = []
for f in glob.glob(f"{HOME}/log/*/*.md"):
    seqs = collections.defaultdict(list)
    for line in open(f, encoding="utf-8"):
        m = re.match(r'^- seq:(\d+) \| .*?\| actor:(\S+?) \|', line)
        if m: seqs[m.group(2)].append(int(m.group(1)))
    for actor, ss in seqs.items():
        if sorted(ss) != list(range(1, len(ss)+1)): bad.append(f"{f}:{actor}:{ss}")
print("\n".join(bad))
PYEOF
)
[[ -z "$SEQ_BAD" ]] && ok "seq 对账" || bad "seq 断档/重号: $SEQ_BAD" "doctor.sh --fix 无法修复时，查 doctor-runbook §seq"

# 2. idem 完整性：同一 (actor, task) 子序列内"连续"重复 idem 才是重试残留异常；
#    隔着其他事件的相同 idem 是合法状态迁移（如 reopen 后再次 claimed），不算异常
IDEM_BAD=$(python3 - <<'PYEOF'
import glob, re, os, collections
HOME = os.environ["AGORA_HOME"]
LINE_RE = re.compile(r'^- seq:\d+ \| ts:\S+ \| actor:(\S+) \| event:\w+ \| idem:(\S+) \| seen:\S+(.*)$')
KV_RE = re.compile(r'(\w+):((?:[^|]|\|(?!\s*\w+:))*?)(?=\s*\|\s*\w+:|$)')
bad = []
for f in sorted(glob.glob(f"{HOME}/log/*/*.md")):
    last = {}  # (actor, task) -> (idem, lineno)
    for i, line in enumerate(open(f, encoding="utf-8"), 1):
        m = LINE_RE.match(line.strip())
        if not m: continue
        actor, idem, rest = m.groups()
        task = dict(KV_RE.findall(rest)).get("task", "")
        key = (actor, task)
        if last.get(key, (None,))[0] == idem:
            bad.append(f"{f}:{i} idem:{idem}")
        last[key] = (idem, i)
print("\n".join(bad))
PYEOF
)
[[ -z "$IDEM_BAD" ]] && ok "idem 完整性" || bad "连续重复 idem（重试残留）: $IDEM_BAD" "保留首条，人工删除后续行（doctor-runbook §idem）"

# 3. board 对账：重推导与现有 board 一致性
TMP=$(mktemp -d)
cp -r "$AGORA_HOME/board" "$TMP/board.orig"
AGORA_HOME="$AGORA_HOME" bash "$AGORA_HOME/scripts/derive-board.sh" >/dev/null 2>&1
if diff -rq "$TMP/board.orig" "$AGORA_HOME/board" >/dev/null 2>&1; then
  ok "board 对账"
else
  if [[ "$FIX" == "--fix" ]]; then ok "board 对账（已重建修复）"; else
    cp -r "$TMP/board.orig/." "$AGORA_HOME/board/"  # 还原，保持只报告
    bad "board 与日志不一致" "doctor.sh --fix（重建 board）"
  fi
fi
rm -rf "$TMP"

# 4. flock 活性（flock 的锁在 fd 上不在文件上：文件存在属正常，长期不可获取才是故障）
LOCK="$AGORA_HOME/.git/post.lock"
if [[ -f "$LOCK" ]]; then
  if flock -w 3 "$LOCK" -c true 2>/dev/null; then ok "flock（可正常获取）"
  else bad "flock 被持有超过 3s（可能有进程卡死）" "ps 查找持锁进程并 kill；MUST NOT 删除锁文件（会破坏锁语义）"; fi
else ok "flock（尚未初始化）"; fi

# 5. 派生会话 stalled 检测：活性以论坛事件（progress/done 等）计，不看 commit
TIMEOUT="${AGORA_DISPATCH_TIMEOUT:-30}"
STALLED=$(python3 - <<'PYEOF'
import glob, os, re, time, datetime
HOME = os.environ["AGORA_HOME"]
timeout = int(os.environ.get("AGORA_DISPATCH_TIMEOUT", "30"))
last = {}
for f in glob.glob(f"{HOME}/log/*/*.md"):
    for line in open(f, encoding="utf-8"):
        m = re.match(r'^- seq:\d+ \| ts:(\S+) \| actor:(\S+?) \|', line)
        if m: last[m.group(2)] = max(last.get(m.group(2), ""), m.group(1))
now = time.time()
out = []
for live in glob.glob(f"{HOME}/raw/dispatches/*.live"):
    did = os.path.basename(live)[:-5]
    child = None
    for f in glob.glob(f"{HOME}/log/*/*.md"):
        for line in open(f, encoding="utf-8"):
            if did in line and "event:dispatched" in line:
                cm = re.search(r'child:(\S+)', line)
                if cm: child = cm.group(1)
    ts = None
    for actor, t in last.items():
        if child and actor.startswith(child + "@"): ts = t
    base = ts or datetime.datetime.fromtimestamp(os.path.getmtime(live)).astimezone().isoformat(timespec="seconds")
    age = (now - datetime.datetime.fromisoformat(base).timestamp()) / 60
    if age > timeout: out.append(f"{did}({child or '?'} 沉默 {int(age)}min)")
print("\n".join(out))
PYEOF
)
[[ -z "$STALLED" ]] && ok "派生会话活性（以广场事件计）" || warn "stalled 派生: $STALLED（人工核查或 kill 后 rm .live 标记）"

# 6. 远端与签名纪律（无远端 = 单机模式，跳过）
REMOTE_URL=$(git -C "$AGORA_HOME" remote get-url origin 2>/dev/null || true)
if [[ -n "$REMOTE_URL" ]]; then
  case "$REMOTE_URL" in
    git@*|ssh://*) ok "远端 SSH 纪律（$REMOTE_URL）" ;;
    file://*|/*|./*) warn "远端是本地传输（$REMOTE_URL），无加密与认证——仅测试/本地备份适用" ;;
    *) bad "远端非 SSH: $REMOTE_URL" "git remote set-url origin git@host:path（必须 SSH）" ;;
  esac
  if timeout 10 git -C "$AGORA_HOME" ls-remote origin >/dev/null 2>&1; then
    git -C "$AGORA_HOME" fetch origin >/dev/null 2>&1
    DIV=$(git -C "$AGORA_HOME" rev-list --left-right --count HEAD...FETCH_HEAD 2>/dev/null | tr '\t' ' ' || echo "?")
    AHEAD=${DIV%% *}
    [[ "$AHEAD" == "0" ]] && ok "与远端一致" || warn "本地领先远端 $AHEAD 个提交（下次写入自动 push）"
  else
    warn "远端当前不可达（离线模式，事件只落本地）"
  fi
else
  ok "远端（未配置 = 单机模式；配 AGORA_REMOTE 启用同步）"
fi
if [[ "$(git -C "$AGORA_HOME" config commit.gpgsign)" == "true" ]]; then
  # 签名纪律管"启用之后"：最新机械提交必须有有效签名；启用前的历史提交不算违例
  SIG=$(git -C "$AGORA_HOME" log --format='%G?' -1 2>/dev/null)
  [[ "$SIG" == "G" || "$SIG" == "U" ]] && ok "提交签名（HEAD 有效: %G?=$SIG）" \
    || bad "最新提交无有效签名（%G?=$SIG）" "查 git log --show-signature；可能的非机械写入"
else
  warn "提交签名未启用（init.sh 配 AGORA_SIGN_KEY 或放 ~/.ssh/id_ed25519.pub 后重跑 init）"
fi

[[ $FAIL -eq 0 ]] && echo "== doctor: ALL GREEN ==" || { echo "== doctor: FAILURES PRESENT =="; exit 1; }
