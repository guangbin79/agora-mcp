#!/usr/bin/env bash
# doctor.sh —— 自检与恢复（宣言 §6：任何故障 MUST 有文档化恢复路径）
# 用法: doctor.sh [--fix]；退出码 0=全绿 1=有 fail
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 单源自定位：兄弟脚本/库一律本仓 scripts（gt-f6e4）
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——裸调用已禁用（静默错路径教训 gt-ca34）：export AGORA_HOME=$HOME/plaza 后重试，或经 MCP server env 注入}"; export AGORA_HOME   # heredoc python 经 os.environ 读取——裸调用不再 KeyError（与 wiki-write r1 修法同类）
FIX="${1:-}"
FAIL=0

ok()   { echo "ok   | $1"; }
warn() { echo "warn | $1"; }
bad()  { echo "fail | $1 | 恢复: $2"; FAIL=1; }

# 1. seq 对账：每 actor 在每分片内 seq 连续无重号。
#    核销通道（gt-8fe1 C2，runbook §seq「不删行，发 diagnosed 记录」口径）：账本 diagnosed 事件
#    conclusion 含 seq-waive=<分片名>:<actor> 标注＝该 (分片, actor) 的存量断档/重号已人工核对
#    git log 定位并留痕——doctor 转 ok（注明已核销）不再置红；未核销的照旧红。
#    粒度取分片 basename＋actor（date 目录不入键：标注针对该分片文件的存量事实）。
SEQ_OUT=$(PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import glob, os, collections, re, sys
import agora_lib as lib
HOME = os.environ["AGORA_HOME"]
waived = set()
for f in (glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md")):
    with open(f, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            e = lib.parse_event(line)
            if e and e["event"] == "diagnosed":
                for m in re.finditer(r"seq-waive=([^\s:|]+):(\S+)", e.get("conclusion") or ""):
                    waived.add((m.group(1), m.group(2)))
bad, waived_n = [], 0
for f in (glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md")):
    seqs = collections.defaultdict(list)
    with open(f, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            e = lib.parse_event(line)
            if e: seqs[e["actor"]].append(e["seq"])
    for actor, ss in seqs.items():
        if sorted(ss) != list(range(1, len(ss)+1)):
            if (os.path.basename(f), actor) in waived: waived_n += 1
            else: bad.append(f"{f}:{actor}:{ss}")
print("\n".join(bad))
print(f"WAIVED_HITS={waived_n}")
PYEOF
)
SEQ_BAD=$(printf '%s\n' "$SEQ_OUT" | grep -v '^WAIVED_HITS=' || true)
SEQ_WAIVE_N=$(printf '%s\n' "$SEQ_OUT" | sed -n 's/^WAIVED_HITS=//p')
[[ -z "$SEQ_BAD" ]] && { [[ "${SEQ_WAIVE_N:-0}" -gt 0 ]] \
  && ok "seq 对账（存量红已核销 ${SEQ_WAIVE_N} 项——diagnosed seq-waive 留痕，runbook §seq）" \
  || ok "seq 对账"; } \
  || bad "seq 断档/重号: $SEQ_BAD" "doctor.sh --fix 无法修复时，查 doctor-runbook §seq（核销：diagnosed conclusion 附 seq-waive=<分片名>:<actor>）"

# 2. idem 完整性：同一 (actor, task) 子序列内"连续"重复 idem 才是重试残留异常；
#    隔着其他事件的相同 idem 是合法状态迁移（如 reopen 后再次 claimed），不算异常
IDEM_BAD=$(PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import os, glob
import agora_lib as lib
HOME = os.environ["AGORA_HOME"]
bad = []
for f in sorted((glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md"))):
    last = {}  # (actor, task) -> 上一条 idem
    with open(f, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh, 1):
            e = lib.parse_event(line)
            if not e: continue
            key = (e["actor"], e.get("task", ""))
            if last.get(key) == e["idem"]:
                bad.append(f"{f}:{i} idem:{e['idem']}")
            last[key] = e["idem"]
print("\n".join(bad))
PYEOF
)
[[ -z "$IDEM_BAD" ]] && ok "idem 完整性" || bad "连续重复 idem（重试残留）: $IDEM_BAD" "保留首条，后续行发 diagnosed 标注无效行 ref（doctor-runbook §idem；不删行）"

# 3. board 对账：cp/推导/diff 全程持 post.lock——对账窗口对写路径完全闭合
TMP=$(mktemp -d)
BOARD_STATE=ok
{
  flock -w "${AGORA_LOCK_WAIT:-5}" 9 || true   # 拿不到锁仍继续（只报告）；锁内 cp→推导→diff 原子
  cp -r "$AGORA_HOME/board" "$TMP/board.orig"
  AGORA_HOME="$AGORA_HOME" bash "$SCRIPTS_DIR/derive-board.sh" >/dev/null 2>&1
  if ! diff -rq "$TMP/board.orig" "$AGORA_HOME/board" >/dev/null 2>&1; then
    if [[ "$FIX" == "--fix" ]]; then BOARD_STATE=fixed
    else cp -r "$TMP/board.orig/." "$AGORA_HOME/board/"; BOARD_STATE=bad; fi   # 还原，保持只报告
  fi
    } 9>"$AGORA_HOME/.git/post.lock"
    if [[ "$BOARD_STATE" == ok ]]; then ok "board 对账"
  elif [[ "$BOARD_STATE" == fixed ]]; then ok "board 对账（已重建修复）"
else bad "board 与日志不一致" "doctor.sh --fix（重建 board）"; fi
rm -rf "$TMP"

# 4. flock 活性（flock 的锁在 fd 上不在文件上：文件存在属正常，长期不可获取才是故障）
LOCK="$AGORA_HOME/.git/post.lock"
if [[ -f "$LOCK" ]]; then
  if flock -w 3 "$LOCK" -c true 2>/dev/null; then ok "flock（可正常获取）"
  else bad "flock 被持有超过 3s（可能有进程卡死）" "ps 查找持锁进程并 kill；MUST NOT 删除锁文件（会破坏锁语义）"; fi
else ok "flock（尚未初始化）"; fi

# 5. 派生会话 stalled 检测：活性以论坛事件（progress/done 等）计，不看 commit
TIMEOUT="${AGORA_DISPATCH_TIMEOUT:-30}"
STALLED=$(PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import glob, os, re, time, datetime
import agora_lib as lib
HOME = os.environ["AGORA_HOME"]
timeout = int(os.environ.get("AGORA_DISPATCH_TIMEOUT", "30"))
last = {}
for f in (glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md")):
    with open(f, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            e = lib.parse_event(line)
            if e: last[e["actor"]] = max(last.get(e["actor"], ""), e["ts"])
now = time.time()
out = []
for live in glob.glob(f"{HOME}/raw/dispatches/*.live"):
    did = os.path.basename(live)[:-5]
    child = None
    for f in (glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md")):
        for line in open(f, encoding="utf-8", errors="replace"):
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

# 7. 证据引用推送对账（attach 的物证在项目仓库 refs/agora/evidence/*；只存本地 = 他机不可见）
#    warn 级：不影响 ALL GREEN；离线/无远端静默跳过
EV_BAD=$(PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import glob, os, re, subprocess
import agora_lib as lib
HOME = os.environ["AGORA_HOME"]
dirs = set()
for f in glob.glob(f"{HOME}/wiki/entities/*.md") + glob.glob(f"{HOME}/wiki/projects/*.md"):
    txt = open(f, encoding="utf-8", errors="replace").read()
    for d in lib.entity_dirs(txt) + re.findall(r'^path:\s*(\S+)\s*$', txt, re.M):
        d = os.path.realpath(os.path.expanduser(d))
        if os.path.isdir(os.path.join(d, ".git")): dirs.add(d)
out = []
for d in sorted(dirs):
    if subprocess.run(["git", "-C", d, "remote", "get-url", "origin"],
                      capture_output=True).returncode != 0: continue
    r = subprocess.run(["timeout", "10", "git", "-C", d, "ls-remote", "origin",
                        "refs/agora/evidence/*"], capture_output=True, text=True)
    if r.returncode != 0: continue  # 离线/超时：静默跳过
    remote = {ln.split()[1] for ln in r.stdout.splitlines() if ln.strip()}
    local = set(subprocess.run(["git", "-C", d, "for-each-ref", "--format=%(refname)",
                                "refs/agora/evidence/"], capture_output=True, text=True).stdout.split())
    missing = local - remote
    if missing: out.append(f"{d}: {len(missing)} 条证据引用未推送（{sorted(missing)[0]} 等）")
print("\n".join(out))
PYEOF
)
[[ -z "$EV_BAD" ]] && ok "证据引用推送对账" || warn "未推送的证据引用: $EV_BAD（恢复: 在对应项目仓库 git push origin 'refs/agora/evidence/*'）"

# 8. 中断的合并（sync pre 失败后残留 MERGING 状态：后续写入全被阻塞，且半合并内容会卷入下次提交）
if [[ -f "$AGORA_HOME/.git/MERGE_HEAD" ]]; then
  if [[ "$FIX" == "--fix" ]]; then
    git -C "$AGORA_HOME" merge --abort >/dev/null 2>&1 \
      && ok "合并状态（已 merge --abort 恢复）" \
      || bad "合并中断且 abort 失败" "人工 git status 核查后 git merge --abort（doctor-runbook §sync）"
  else
    bad "合并中断（MERGE_HEAD 残留）" "doctor.sh --fix（git merge --abort）后重跑 sync"
  fi
else ok "合并状态（无中断残留）"; fi

# 9. 孤儿 wt 树（__wt-gt-* 目录在、任务页缺失——FMEA B4：只报告不删，poll GC 亦不删此类）
WT_ORPHAN=$(PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import glob, os, re
import agora_lib as lib
HOME = os.environ["AGORA_HOME"]
roots = set()
for f in glob.glob(f"{HOME}/wiki/entities/*.md") + glob.glob(f"{HOME}/wiki/projects/*.md"):
    txt = open(f, encoding="utf-8", errors="replace").read()
    for d in lib.entity_dirs(txt) + re.findall(r'^path:\s*(\S+)\s*$', txt, re.M):
        roots.add(os.path.dirname(os.path.realpath(os.path.expanduser(d))))
out = []
for r in sorted(roots):
    for wd in glob.glob(os.path.join(r, "*__wt-gt-*")):
        if not os.path.isdir(wd): continue
        m = re.search(r'__wt-(gt-[0-9a-f]{4,})__', os.path.basename(wd))
        if m and not os.path.exists(f"{HOME}/wiki/tasks/{m.group(1)}.md"):
            out.append(wd)
print("\n".join(out))
PYEOF
)
[[ -z "$WT_ORPHAN" ]] && ok "孤儿 wt 树（缺任务页）" || warn "缺任务页的 wt 树（B4 只报告不删）: $WT_ORPHAN（人工确认后 git worktree remove）"

# 10. 名册卫生：owner 实体页 dirs 指向 /tmp/*（测试/临时残留）或不存在目录 → warn 只报告不删
#    os.listdir 而非 glob：点前缀实体页（如 .dotfiles.md）glob 默认致盲（Python<3.11，gt-abe8 教训）
#    dirs 与 /tmp 根都经 realpath(expanduser) 归一化再比（防 symlink/穿越绕过，含 /tmp 本身是链接的环境；与 lib.covers() 同口径）
ROSTER_BAD=$(PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PYEOF'
import os
import agora_lib as lib
HOME = os.environ["AGORA_HOME"]
entdir = f"{HOME}/wiki/entities"
tmproot = os.path.realpath("/tmp")
def esc(s):
    return "".join(c if c.isprintable() else f"\\x{ord(c):02x}" for c in s)  # 非打印字符统一转义，防伪造输出行/ANSI 注入
out = []
try:
    entries = sorted(os.listdir(entdir))
except OSError:
    print(f"{entdir}（entities 目录缺失或不可枚举）")
    raise SystemExit(0)
for fn in entries:
    p = os.path.join(entdir, fn)
    if not fn.endswith(".md") or not os.path.isfile(p): continue  # archived/ 等子目录天然排除
    fn = esc(fn)
    try:
        txt = open(p, encoding="utf-8", errors="replace").read()
    except FileNotFoundError:
        continue  # 枚举与读取间被并发 mv/删（归档常态）——本轮跳过
    except OSError as e:
        out.append(f"{fn}: 读失败（{e.strerror}）——巡检盲区，人工核查")
        continue
    for d in lib.entity_dirs(txt):
        if "\x00" in d:
            out.append(f"{fn}: {d!r}（dirs 含 NUL，路径不可归一化）")
            continue
        rd = os.path.realpath(os.path.expanduser(d))
        if rd == tmproot or rd.startswith(tmproot + "/"):
            out.append(f"{fn}: {esc(d)}（/tmp 临时目录）")
        elif not os.path.isdir(rd):
            out.append(f"{fn}: {esc(d)}（目录不存在）")
print("\n".join(out))
PYEOF
)
[[ -z "$ROSTER_BAD" ]] && ok "名册卫生（dirs 存在且非 /tmp）" || warn "名册卫生异常（只报告不删）: $ROSTER_BAD（人工确认后归档 wiki/entities/archived/）"

# 11. 账本面 dirty 审计（gt-2508：enforcer 拦工具写，但 bash 子进程盲区——python heredoc 直写 wiki/tasks 两次实证）。
#     机械写即 commit（post.sh git add -A 全收），未提交改动=绕过工具直写痕迹。报告器语义：只报告不回滚不置 FAIL
LEDGER_DIRTY=""
{
  flock -w "${AGORA_LOCK_WAIT:-5}" 9 || true   # 锁内读与 post.sh 线性化点互斥：防把机械写中窗误报为绕写（评审环 R1-B-F3）
  LEDGER_DIRTY=$(git -C "$AGORA_HOME" status --porcelain -- log board wiki inbox raw 2>/dev/null || true)
} 9>"$AGORA_HOME/.git/post.lock"
[[ -z "$LEDGER_DIRTY" ]] && ok "账本面（无绕写直改痕迹）" \
  || warn "账本面 dirty——绕过工具直写痕迹（bash 盲区），git 可回滚: $(echo "$LEDGER_DIRTY" | head -5 | tr '\n' '；')（先复核非 post 写入中窗再 git checkout -- 处置）"

[[ $FAIL -eq 0 ]] && echo "== doctor: ALL GREEN ==" || { echo "== doctor: FAILURES PRESENT =="; exit 1; }
