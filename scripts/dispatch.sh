#!/usr/bin/env bash
# dispatch.sh —— 跨项目派生一次性工作会话（规格 §4.7，四保险丝全在机械层）
# 用法: dispatch.sh --actor NAME@PROJ --project DIR --task gt-xxxx [--prompt "..."]
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 单源自定位：兄弟脚本/库一律本仓 scripts（gt-f6e4）
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——裸调用已禁用（静默错路径教训 gt-ca34）：export AGORA_HOME=$HOME/plaza 后重试，或经 MCP server env 注入}"
MAX_DEPTH="${AGORA_MAX_DEPTH:-5}"; MAX_SPAWN="${AGORA_MAX_SPAWN:-30}"; MAX_GLOBAL="${AGORA_MAX_SPAWN_GLOBAL:-60}"
RUNTIME="${AGORA_RUNTIME:-opencode}"

ACTOR=""; PDIR=""; TASK=""; PROMPT=""; DTASK=""
while [[ $# -gt 0 ]]; do case "$1" in
  --actor) ACTOR="$2";; --project) PDIR="$2";; --task) TASK="$2";; --prompt) PROMPT="$2";; --dispatcher-task) DTASK="$2";;
  *) echo '{"code":"VALIDATION_FAILED","message":"unknown arg"}' >&2; exit 2;;
esac; shift 2; done
fail() { python3 -c 'import json,sys; print(json.dumps({"code":sys.argv[1],"message":sys.argv[2]}, ensure_ascii=False), file=sys.stderr)' "$1" "$2"; exit "${3:-2}"; }   # $POUT 等嵌值含引号亦合法（评审 MINOR：错误通道 JSON）
# 配额双闸（gt-8c5b 分域）：$1=本 actor 域活跃 vs MAX_SPAWN（他人占满不挡我）；$2=全机活跃总和 vs MAX_GLOBAL（防多会话叠加失控）——两档措辞供调用方辨识
quota_check() {
  (( ${1:-0} >= MAX_SPAWN )) && fail QUOTA_EXCEEDED "分域满：actor $ACTOR 活跃 $1/$MAX_SPAWN（他人域不受影响，仅本 actor 域额尽）" 8
  (( ${2:-0} >= MAX_GLOBAL )) && fail QUOTA_EXCEEDED "总量满：全机活跃总和 $2/$MAX_GLOBAL（各 actor 域未超，叠加达闸）" 8
  return 0
}

NAME="${ACTOR%%@*}"
ENTITY="$AGORA_HOME/wiki/entities/$NAME.md"
[[ -f "$ENTITY" ]] || fail NOT_REGISTERED "caller not in roster: $NAME"

# 注入防御：TASK/DTASK 是外部输入（可能来自他机邮件摘要），进 bash -c 前强制格式
[[ "$TASK" =~ ^gt-[0-9a-f]{4,}$ ]] || fail VALIDATION_FAILED "bad task id: $TASK" 2
[[ -z "$DTASK" || "$DTASK" =~ ^gt-[0-9a-f]{4,}$ ]] || fail VALIDATION_FAILED "bad dispatcher task id: $DTASK" 2

# 保险丝 1：权限（身份页 can_spawn: true）
grep -qE '^can_spawn:[[:space:]]*true' "$ENTITY" || fail SPAWN_FORBIDDEN "$NAME lacks can_spawn" 6

# 派发准入门（gt-6bef）：调用方会话在册未超龄才可派发。MCP serve 模式 server 无会话上下文
# （env/进程树均无区分度，/proc 实证）——空 AGORA_SID 无法识别调用方，跳过（会话级主闸在
# enforcer 插件层：原生持 sessionID）；非空（直调 bash/CI 以 sid 显式自证）则严检，同步拒于
# 落账前（不产生半派发态），hint 给精确修复命令（REGISTER_REQUIRED 错误契约）；门内非 3 退出
# 不吞——校验/锁忙误报成「不在册」会引错修复方向，GATE_ERROR 透传内层 rc（gt-e96d）
if [[ -n "${AGORA_SID:-}" ]]; then
  GATE_RC=0
  bash "$SCRIPTS_DIR/register-session.sh" --sid "$AGORA_SID" --entity "$NAME" --check-only >/dev/null || GATE_RC=$?
  case "$GATE_RC" in
    0) ;;
    3) fail REGISTER_REQUIRED "caller session 不在册或已超龄（AGORA_SID=$AGORA_SID，entity=$NAME）；修复命令见上行 hint" 10 ;;
    *) fail GATE_ERROR "准入门异常退出 rc=$GATE_RC（2 校验/4 锁忙/1 环境，非不在册误报；详情见上行 stderr）" 10 ;;
  esac
fi

# 保险丝 2/3：深度与配额——env 与账本推导取更大值（v1.32 账本化：L2/API 模式无 env 通道时账本为唯一来源）
# 账本口径：深度=dispatched 事件 dispatcher_task 链逐跳计数（任务最新 dispatched 为准，环检测兜底）；
#          配额活跃=dispatched 集 ∩ 无终态事件（done/merged/cancelled 任一即出集）
LEDGER_NEXT=1; LEDGER_ME=0; LEDGER_TOT=0; LEDGER_SELF=0; LDT=""
ledger_scan() {
PYTHONPATH="$SCRIPTS_DIR${PYTHONPATH:+:$PYTHONPATH}" \
python3 - "$AGORA_HOME" "${DTASK:-}" "$ACTOR" "$PDIR" "$TASK" <<'PYEOF'
import glob, os, re, sys
from agora_lib import main_repo_of
home = sys.argv[1]; dtask = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else ""
actor = sys.argv[3] if len(sys.argv) > 3 else ""
pdir = sys.argv[4] if len(sys.argv) > 4 else ""
ttask = sys.argv[5] if len(sys.argv) > 5 else ""
def _norm(p):   # worktree 路径归一主仓后 realpath（actor 碰撞同项目判据用）
    if not p: return ""
    try: m = main_repo_of(p) or p
    except Exception: m = p
    try: return os.path.realpath(m)
    except Exception: return m
cur = _norm(pdir)
disp, terminal, last_alive, claimed, dact, runs, tproj = {}, set(), {}, {}, {}, {}, {}
scan_i = 0   # gt-6769：全局扫描序（文件序×行序＝append-only 写入因果序），ts 同秒并列时的确定性次键
for f in sorted((glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md"))):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError: continue
    for line in lines:
        scan_i += 1
        if "event:" not in line: continue
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line:
            d = re.search(r"dispatcher_task:(gt-[0-9a-f]{4,})", line)
            disp[t] = d.group(1) if d else ""   # 文件序+行序扫描，后见覆盖=最新派发
            am = re.search(r"\| actor:(\S+)", line); dact[t] = am.group(1) if am else ""
            rm_ = re.search(r"\| run:(\S+)", line)
            if rm_: runs[rm_.group(1)] = dact[t]   # .live→actor 归属（分域 .live 计数用）
            tm_ = re.search(r"\| target:(\S+)", line)
            if tm_: tproj[t] = tm_.group(1)   # 派发目标项目路径（actor 碰撞判据用）
            last_alive[t] = True
        elif "event:claimed" in line:
            am = re.search(r'\| actor:(\S+)', line)
            tmz = re.search(r"\| ts:([^|]+)", line)
            claimed[t] = (am.group(1) if am else "", tmz.group(1).strip() if tmz else "", scan_i)
            last_alive[t] = True
        elif any(f"event:{e}" in line for e in ("done", "merged", "cancelled")):
            terminal.add(t); claimed.pop(t, None)
        elif "event:diagnosed" in line:
            last_alive[t] = False   # 子会话已死（秒死/stale）——配额出集，占位释放
        elif "event:progress" in line or "event:plan" in line:
            last_alive[t] = True
def depth(t, seen, budget=100):   # 链长上限 100：账本他机可写不可信，超预算返回超深值按 DEPTH_EXCEEDED 拒（同 poll.sh 防递归爆栈）
    if budget <= 0: return 100
    if t not in disp or t in seen: return 0
    d = disp[t]
    return 1 if not d else 1 + depth(d, seen | {t}, budget - 1)
# dispatcher_task 机械推导（终审 A-W1）：未显式传入时取本 actor 最近 claimed 且无终态的任务。
# gt-7ca0 场景a（actor 碰撞）：同名 actor 的主会话与派生子会话共享身份——claimed 目标与本派发
# 同项目且该 claimed 无自身链证据（disp 为空＝根任务工人）时，那是子会话的 claim 不是本会话的，排除；
# 跨项目 claimed（真委托链）与同项目但有链证据（链上工人同仓再派）保留。
# gt-6769：「最近」按事件 ts 判（tz-aware 解析，+00:00/+08:00 混排可比），不按文件扫描序——
# 跨 UTC 日期边界时账本分片分裂（log/10-25 与 10-26 并存），文件序≠时序，插序尾会取错对象（F5 三连挂实证）
if not dtask and actor:
    from datetime import datetime
    def _pts(s):
        try:
            d = datetime.fromisoformat(s)
            return d if d.tzinfo else d.astimezone()
        except Exception:
            return None
    cands = [t for t, (a, _, _) in claimed.items()
             if a == actor and not (cur and _norm(tproj.get(t, "")) == cur and not disp.get(t))]
    if cands:
        # 同 ts 并列时以扫描序（写入因果序）破平——append-only 账本后写者更近（gt-6769 同秒并列实证）
        dtask = max(cands, key=lambda t: ((_pts(claimed[t][1]) or _pts("1970-01-01T00:00:00+00:00")).timestamp(), claimed[t][2]))
nxt = depth(dtask, frozenset()) + 1 if dtask in disp else 1
# 配额活跃＝dispatched ∩ 无终态 ∩ 非僵尸（last_alive=False＝已死出集；真活由 .live 计数兜底取 max）
# 分域口径（gt-8c5b）：活跃按 actor 归组（dispatched 行 actor 字段，claimed 兜底）；.live 按 run 路径归属 actor；
# 域值＝域内两组取大；总量＝全局两组取大——总量闸（MAX_SPAWN_GLOBAL）防多会话叠加失控
by_actor = {}
for t in disp:
    if t in terminal or not last_alive.get(t, True): continue
    a = dact.get(t) or claimed.get(t, ("",))[0]
    by_actor[a] = by_actor.get(a, 0) + 1
live_by, live_tot = {}, 0
for lf in glob.glob(f"{home}/raw/dispatches/*.live"):
    live_tot += 1
    a = runs.get(os.path.relpath(lf[:-5], home))
    if a is not None: live_by[a] = live_by.get(a, 0) + 1
me = max(by_actor.get(actor, 0), live_by.get(actor, 0))
total = max(live_tot, sum(by_actor.values()))
# gt-7ca0 场景c：目标任务自身活跃（在飞无终态）＝恢复性重派对象自己的旧槽，配额闸豁免。
# 域归属校验（终闸 C-F2）：任务须计入本 actor 域（dispatched 行 actor 或 claimed 兜底==本 actor）
# 才豁免——堵伪造无 actor 行借豁免净赚 +1 槽，亦防跨 actor 重派误扣他域槽
selfact = 1 if (ttask and ttask in disp and ttask not in terminal and last_alive.get(ttask, True)
                and (dact.get(ttask) or claimed.get(ttask, ("",))[0]) == actor) else 0
print(nxt, me, total, selfact, dtask)
PYEOF
}
SCAN_OUT="$(ledger_scan)" || SCAN_OUT=""   # 扫描崩溃不致命：空输出落退化分支（评审 B1：here-string 空 stdout read 仍 rc=0，必须显式判空）
if [ -n "$SCAN_OUT" ] && read -r LN LME LTOT LSELF LDT <<<"$SCAN_OUT"; then [ -n "$LN" ] && LEDGER_NEXT=$LN; LEDGER_ME=${LME:-0}; LEDGER_TOT=${LTOT:-0}; LEDGER_SELF=${LSELF:-0}
else LEDGER_TOT=$(find "$AGORA_HOME/raw/dispatches" -name '*.live' 2>/dev/null | wc -l) || LEDGER_TOT=0; fi   # 扫描失败/空输出退化：.live 总数兜底总量闸（分域漏检可容忍，总量不失守；|| 防 find 失败×pipefail 杀死 set -e）
# gt-7ca0 场景c：恢复性重派豁免自身槽位——目标任务占的正是本次要重发的旧槽，不豁免则
# done-unmerged/孤儿恢复重派被自己锁死（QUOTA_EXCEEDED 自锁×2 实证）。退化分支无法判自身，不豁免
if [ "$LEDGER_SELF" = "1" ]; then
  (( LEDGER_ME > 0 )) && LEDGER_ME=$((LEDGER_ME-1))
  (( LEDGER_TOT > 0 )) && LEDGER_TOT=$((LEDGER_TOT-1))
fi
# 推导回填（A-W1）：显式传入优先，机械推导兜底——两者都进 dispatched 落账
[ -z "$DTASK" ] && [ -n "${LDT:-}" ] && [ "$LDT" != "None" ] && DTASK="$LDT"
DEPTH="${AGORA_DEPTH:-0}"; NEXT=$((DEPTH+1))
(( NEXT < LEDGER_NEXT )) && NEXT=$LEDGER_NEXT
[[ $NEXT -ge $MAX_DEPTH ]] && fail DEPTH_EXCEEDED "depth $NEXT >= max $MAX_DEPTH" 7

quota_check "$LEDGER_ME" "$LEDGER_TOT"   # 分域＋总量双闸（gt-8c5b）；.live 计数已并入扫描（域内/全局各自取大）

# 子会话身份：名册目录前缀匹配（最深优先）；worktree 路径归一主 repo（口径在 agora_lib.resolve_entity，gt-ac14）
R=$(PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - "$AGORA_HOME" "$PDIR" <<'PYEOF'
import sys
import agora_lib as lib
home, path = sys.argv[1], sys.argv[2]
r = lib.resolve_entity(home, path)
print(f"{r[0]}\n{r[1]}\n{r[2]}" if r else "")
PYEOF
)
CHILD=$(sed -n 1p <<<"$R"); PROOT=$(sed -n 3p <<<"$R")
[[ -z "$CHILD" || -z "$PROOT" ]] && fail NOT_REGISTERED "no roster entry for $PDIR" 9

# 保险丝 4：落账（dispatched 事件）——数组拼参＋条件追加 dispatcher_task（链深度登记面）
DID="d-$(date +%s%N | sha1sum | cut -c1-8)"
LOG="raw/dispatches/$DID.log"

PROJNAME=$(basename "$PROOT")

# L2 API 通道门（设计 §三）：默认开；RUNTIME=opencode 且适配器在场且 health 通才启用（stub/替代 runtime 零扰动）
RT="$SCRIPTS_DIR/runtime/opencode.sh"
API=0
if [ "$RUNTIME" = "opencode" ] && [ "${AGORA_RUNTIME_API:-1}" != "0" ] && [ -f "$RT" ]; then
  timeout "${AGORA_API_TIMEOUT:-15}" bash "$RT" health >/dev/null 2>&1 && API=1
fi

# 任务页 wt 感知：wt_dir 在场 → 凭据预写/树重建预检/免在场优先（设计 §四/§五/§六）
PAGE="$AGORA_HOME/wiki/tasks/$TASK.md"
WT_DIR=""
[ -f "$PAGE" ] && WT_DIR=$(sed -n 's/^wt_dir:[[:space:]]*//p' "$PAGE" | head -1)
NOWT=""
[ -f "$PAGE" ] && NOWT=$(sed -n 's/^nowt:[[:space:]]*//p' "$PAGE" | head -1)
WT_MAIN=""
if [ -n "$WT_DIR" ]; then
  RB_IN=$(realpath "$PDIR" 2>/dev/null) || RB_IN="$PDIR"   # 父链删净时保底裸路径（评审 R2-F1：stderr JSON 契约）
  WT_MAIN=$(PYTHONPATH="$SCRIPTS_DIR" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "$RB_IN")
fi
# 子会话命名（gt-2845②）：create/--title 同名 "agora: <task-id> <任务title截60字>"（title 按码点截断防劈字）
CTITLE=""
if [ -f "$PAGE" ]; then
  _TT=$(sed -n 's/^title:[[:space:]]*//p' "$PAGE" | head -1 | sed 's/^"\(.*\)"$/\1/; s/[[:space:]]*$//')
  CTITLE=$(python3 -c 'import sys;print(("agora: "+sys.argv[1]+" "+sys.argv[2][:60]).rstrip())' "$TASK" "$_TT")
fi

# verify 合同静态守卫（gt-b9fb 三实例成律 gt-6cad/e4f3/944f）：绝对路径／$AGORA_HOME 引用在 wt 树内
# 与他机不可达——落账前静态检查，warnings 非阻断提示改仓内相对路径（wt 树内执行语义）
VWARN=()
if [ -f "$PAGE" ]; then
  _V=$(sed -n 's/^verify:[[:space:]]*//p' "$PAGE" | head -1)   # sed -n 形态：无 verify 行不触发 pipefail（gt-b9fb 首跑实证）
  set -f
  for _w in $_V; do
    _t=$(printf '%s' "$_w" | tr -d "\"'")   # 剥引号后再判：引号包裹的绝对路径同防
    case "$_t" in
      '$AGORA_HOME'/*|'${AGORA_HOME}'/*) VWARN+=("verify 含 \$AGORA_HOME/… 路径（派生树内/他机不可达），建议改仓内相对路径（wt 树内执行语义）") ;;
      /*) VWARN+=("verify 含绝对路径 $_t（wt 树内/他机不可达），建议改仓内相对路径（wt 树内执行语义）") ;;
    esac
  done
  set +f
fi

# 预检（落账前，失败零账本残留；SPAWN_PRECHECK 同步可见——失败必须响）
"$RUNTIME" --version >/dev/null 2>&1 || fail SPAWN_PRECHECK "runtime 不可用: $RUNTIME" 9
[ -d "$PDIR" ] || fail SPAWN_PRECHECK "project_dir 不存在: $PDIR" 9

# 在场优先：目标项目已有「委托子会话」在场 → 只通知不派生（wt 任务豁免——在场会话无树凭据，notified 必死）
# gt-0ed3：alive 带 delegated 过滤（title 前缀 "agora: gt-"，两 spawn 通道统一命名 gt-2845②）——
# 用户交互会话占坑不算在场（通知信消费绑定交互会话下一回合 check_mail，异步任务必滞留；实狗粮 d-dc64196f/d-4255f3e3）。
# gt-762a：delegated 在场再收窄 status=running——worker done 退场后持久会话 title 不变，残留命中把 notified 投给已退场会话（575d/8fe1/7cd9/e96d 四笔死信实证）。
# API 不通＝通知桥同依赖 API、无法触达——不算在场，总是 spawn（旧 sessions.map 回退删除：交互注册面≠委托在场）；
VWARN_EXT=""   # set -u：notified 提前出口先就地序列化（verify 合同告警在 notified 亦不丢，ocr-20）；
               # auto-wt 追加告警后 306 行处重算覆盖
if [ ${#VWARN[@]} -gt 0 ]; then
  VWARN_EXT=",\"warnings\":$(printf '%s\n' "${VWARN[@]}" | python3 -c 'import json,sys;print(json.dumps([l.strip() for l in sys.stdin if l.strip()],ensure_ascii=False))')"
fi
if [ -z "$WT_DIR" ]; then
  if [ "$API" = 1 ] && timeout "${AGORA_API_TIMEOUT:-15}" bash "$RT" alive "$PDIR" delegated >/dev/null 2>&1; then
    bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PROJNAME" --event ack \
      --body "dispatch $TASK notified via bridge" --mention "$CHILD" >/dev/null
    echo "{\"dispatch_id\":\"$DID\",\"mode\":\"notified\",\"child_actor\":\"$CHILD@$PROJNAME\"${VWARN_EXT}}"
    exit 0
  fi
fi

# gt-85c3：非 wt 任务 spawn 强制树隔离——wt_dir 缺省自动补建（混分支根治：gt-236a 两任务混一条
# 分支／gt-762a 复合 commit 出票失败实证）。豁免：nowt: true（纯文档/知识积累/单文件微改）＋
# 非 git 仓／unborn HEAD（无从建树，降级 warn）。在场优先判定先行——notified 不占树。
if [ -z "$WT_DIR" ] && [ -f "$PAGE" ]; then
  if [ "$NOWT" = "true" ]; then
    VWARN+=("nowt: true 豁免——无树隔离，worker 将在目标检出当前分支提交（分支混入风险）")
  else
    AW_MAIN=$(PYTHONPATH="$SCRIPTS_DIR" python3 -c 'import sys, agora_lib
p = sys.argv[1]; m = agora_lib.main_repo_of(p); print(m or p)' "$PDIR" 2>/dev/null || true)
    if [ -z "$AW_MAIN" ] || [ ! -d "$AW_MAIN/.git" ]; then
      VWARN+=("auto-wt 跳过——目标非 git 仓（无树隔离，分支混入风险）")
    elif ! git -C "$AW_MAIN" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      VWARN+=("auto-wt 跳过——主仓无提交（unborn HEAD 无基点，无树隔离）")
    else
      AW_RC=0
      (
        flock -w "${AGORA_LOCK_WAIT:-5}" 7 || exit 3
        # 锁内重读：并发对手方（同任务并发派发）可能已补建回填——复用其树，防分支独占撞车
        _AW2=$(sed -n 's/^wt_dir:[[:space:]]*//p' "$PAGE" | head -1)
        [ -n "$_AW2" ] && { echo "$_AW2"; exit 0; }
        git -C "$AW_MAIN" worktree prune
        _WTD="$(dirname "$AW_MAIN")/$(basename "$AW_MAIN")__wt-${TASK}__$(date +%m%d%H%M)"
        if git -C "$AW_MAIN" show-ref --verify --quiet "refs/heads/wt/$TASK"; then
          git -C "$AW_MAIN" worktree add -q "$_WTD" "wt/$TASK" || exit 9
        else
          _DEFBR=""
          for _c in "$(git -C "$AW_MAIN" config --get init.defaultBranch 2>/dev/null)" main master; do
            [ -n "$_c" ] && git -C "$AW_MAIN" show-ref --verify --quiet "refs/heads/$_c" && { _DEFBR="$_c"; break; }
          done
          [ -n "$_DEFBR" ] || exit 8
          git -C "$AW_MAIN" worktree add -q -b "wt/$TASK" "$_WTD" "$_DEFBR" || exit 7
        fi
        # amended 任务页回填 wt_dir（机械层；sed 即幂等锚——并发对手方下次派发复用本树不重复建）。
        # ocr-18：sed 无匹配仍 rc0——显式验锚落地，防「树已建页未回填」令下次派发 exit9 死锁
        _WTD_ESC="${_WTD//\\/\\\\}"; _WTD_ESC="${_WTD_ESC//&/\\&}"; _WTD_ESC="${_WTD_ESC//|/\\|}"
        sed -i "2,/^---\$/s|^---\$|wt_dir: ${_WTD_ESC}\n---|" "$PAGE"
        grep -q "^wt_dir:" "$PAGE" || exit 6
        # 账本同步提交：post.lock 内与 post.sh/task-create 同锁互斥（并发 git index 竞争根除）；
        # 锁忙/提交失败仅失同步不失锚（页已回填）——降级尽力而为，不阻断派发（九派风暴实证）。
        # 输出重定向 /dev/null：git commit 空提交时 "On branch master" 状态文本不走 -q，会污染
        # 本子壳 stdout 的路径回传（AW_OUT 多行→WT_DIR 垃圾→rebuild 打飞，风暴四连败实证）
        (
          flock -w "${AGORA_LOCK_WAIT:-5}" 8 || exit 0
          (cd "$AGORA_HOME" && git add "wiki/tasks/$TASK.md" \
            && AGORA_MECHANICAL=1 git commit -qm "task: amend $TASK wt_dir auto-provision（gt-85c3）") >/dev/null 2>&1 || exit 0
        ) 8>"$AGORA_HOME/.git/post.lock"
        echo "$_WTD"
      ) 7>"$AW_MAIN/.git/agora-auto-wt.lock" >"$AGORA_HOME/.git/wt-$TASK.$$.out" || AW_RC=$?
      AW_OUT="$(cat "$AGORA_HOME/.git/wt-$TASK.$$.out" 2>/dev/null | tail -1 || true)"; rm -f "$AGORA_HOME/.git/wt-$TASK.$$.out"
      case "$AW_RC" in
        0) WT_DIR="$AW_OUT"; WT_MAIN="$AW_MAIN" ;;
        3) fail SPAWN_PRECHECK "auto-wt 锁超时（agora-auto-wt.lock ${AGORA_LOCK_WAIT:-5}s）" 9 ;;
        8) fail SPAWN_PRECHECK "auto-wt 默认分支不可解析（init.defaultBranch/main/master 均缺）" 9 ;;
        7) fail SPAWN_PRECHECK "auto-wt 树创建失败（默认分支基点）: $AW_MAIN" 9 ;;
        9) fail SPAWN_PRECHECK "auto-wt 树挂载失败（既有分支）: $AW_MAIN" 9 ;;
        6) fail SPAWN_PRECHECK "auto-wt 任务页回填失败: $PAGE" 9 ;;
        *) fail SPAWN_PRECHECK "auto-wt 补建失败 rc=$AW_RC: $AW_MAIN" 9 ;;
      esac
    fi
  fi
fi
VWARN_EXT=""
if [ ${#VWARN[@]} -gt 0 ]; then
  VWARN_EXT=",\"warnings\":$(printf '%s\n' "${VWARN[@]}" | python3 -c 'import json,sys;print(json.dumps([l.strip() for l in sys.stdin if l.strip()],ensure_ascii=False))')"
fi
AW_EXT=""   # auto-wt 通知面（新建与并发锁内复用同报；ocr-21：去 AW_CREATED 死状态）
if [ -n "$WT_DIR" ]; then
  AW_EXT=",\"wt_created\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$WT_DIR")"   # ocr-19：json 序列化防路径引号破坏 JSON
fi

if [ -n "$WT_DIR" ]; then
  [ -e "$WT_MAIN/.git" ] || fail SPAWN_PRECHECK "wt 主仓不可用: $WT_MAIN" 9
  if [ ! -d "$WT_DIR" ]; then
    # 锚点重建（FMEA D2）：分支在→直挂既有分支；分支已删→默认分支重建分支
    # （S1：基点=init.defaultBranch/main/master 序探，不用主仓当前 HEAD——主仓停他支时防漂移）。
    # prune 先行：目录被 rm 后 .git/worktrees 注册残留会让 add 拒绝同路径重建。
    # post.lock 同锁互斥（评审 B-1/ocr-6：与 post.sh verify 重建段收敛并发窗）
    RB_RC=0
    (
      flock -w "${AGORA_LOCK_WAIT:-5}" 9 || exit 3
      git -C "$WT_MAIN" worktree prune
      if git -C "$WT_MAIN" show-ref --verify --quiet "refs/heads/wt/$TASK"; then
        git -C "$WT_MAIN" worktree add -q "$WT_DIR" "wt/$TASK" || exit 9
      else
        DEFBR=""
        for _c in "$(git -C "$WT_MAIN" config --get init.defaultBranch 2>/dev/null)" main master; do
          [ -n "$_c" ] && git -C "$WT_MAIN" show-ref --verify --quiet "refs/heads/$_c" && { DEFBR="$_c"; break; }
        done
        [ -n "$DEFBR" ] || exit 8
        echo "rebuild: 默认分支基点=$DEFBR" >&2   # 评审 R2-F3：rc7 诊断保住基点名（子壳变量不出壳）
        git -C "$WT_MAIN" worktree add -q -b "wt/$TASK" "$WT_DIR" "$DEFBR" || exit 7
      fi
    ) 9>"$AGORA_HOME/.git/post.lock" || RB_RC=$?
    case "$RB_RC" in
      0) ;;
      3) fail SPAWN_PRECHECK "树重建锁超时（post.lock ${AGORA_LOCK_WAIT:-5}s）" 9 ;;
      8) fail SPAWN_PRECHECK "默认分支不可解析（init.defaultBranch/main/master 均缺）" 9 ;;
      7) fail SPAWN_PRECHECK "树重建失败（默认分支基点）: $WT_DIR" 9 ;;
      *) fail SPAWN_PRECHECK "树重建失败（挂既有分支）: $WT_DIR" 9 ;;
    esac
  fi
  # setup 钩子（设计 §五环境完备）：项目页 setup: 命令在树内先跑（装环境；预检段执行＝失败零落账）
  SETUPCMD=""
  for pf in "$AGORA_HOME"/wiki/projects/*.md; do
    [ -f "$pf" ] || continue
    _pp=$(sed -n 's/^path:[[:space:]]*//p' "$pf" | head -1)
    [ -z "$_pp" ] && continue
    [ "$(realpath "$_pp" 2>/dev/null)" = "$WT_MAIN" ] && { SETUPCMD=$(sed -n 's/^setup:[[:space:]]*//p' "$pf" | head -1); break; }
  done
  if [ -n "$SETUPCMD" ]; then
    (cd "$WT_DIR" && timeout "${AGORA_SETUP_TIMEOUT:-600}" bash -c "$SETUPCMD") >/dev/null 2>&1 \
      || fail SETUP_FAILED "项目页 setup: 在树内失败（cmd: $SETUPCMD；装环境未完成不派生）" 9
  fi
fi

BOOT="你是广场派生的一次性工作会话。按开场仪式查收信、看看板；你的任务是 $TASK（读 wiki/tasks/$TASK.md，按 verify 要求验收）。若任务页有 wt_dir：你在该专用树内开发——新鲜树缺 node_modules/venv 等环境，先装环境再验收（项目页 setup: 已由 dispatch 预跑）。认领即 agora_post(event=claimed, task=$TASK)。动手实施前先 agora_post(event=plan, task=$TASK) 落实施计划并 mention 任务页 dispatcher——等 ack 不是官僚流程，是不可逆操作的前置保险。plan 落账后回合保持活跃轮询等 ack：定时（60–240s）双通道查询——agora_history(task=$TASK) 出现 event:ack 且 mention 命中自己 ∨ agora_check_mail 有未读 mention 信（dispatcher 修正信不可逆步骤前必须消费，步骤中可延至步骤边界）；等待期每 30min agora_post(event=progress, task=$TASK) 心跳（防看门狗误报）；超 30min 无 ack 走自放行条款开工并在账本注明。收到 ack 即按计划执行；收到 cancelled 即终止。commit 前重读账本。每完成一个里程碑或每 30min agora_post(event=progress, task=$TASK) 刷新看板——心跳硬性要求，超时即看门狗诊断。你不自己合并——done 即止（树上 commit＋自验），合并由 dispatcher 走 merge.sh；需改第三仓照常 task_create＋dispatch 下钻（受深度/配额约束）；等待下级时 post progress 后退出，由 poll 恢复性重派唤醒。若你是恢复性重派：先 agora_history(task=$TASK) 自查进度、git status/log 查半成品，接着做。合并阶段 non-ff 冲突：先在原树 rebase 到合并目标分支，重走 verify 再试。退场收尾三查（done 前逐项确认，gt-575d）：①知识积累已提交——非 trivial 任务的经验/知识页 commit 在场，无积累则在 done evidence 注明「无」；②worktree 清理确认——专属树状态注记（你不自己合并，残留树交 dispatcher/merge.sh 处置，evidence 注明树在/已清）；③遗留项显式注明（无则写无）。完成后 agora_post(event=done, task=$TASK, commit=…, evidence=…) 并一律 mention 任务页 dispatcher 字段——blocked/cancelled 等终态与受阻事件同理，worker 终态必推送。${PROMPT:+ 补充指示：$PROMPT}"
# 注入防御：PROMPT/PDIR 均不可信（PROMPT 可能来自他机邮件摘要）。一律走 env 传数据 +
# 单引号脚本，bash -c 体内不出现任何外部插值

# 补偿落账顺序：dispatched 先行（LEDGER_FAILED → 零 spawn，无孤儿会话；孤儿 dispatched 由 poll 档兜底）
# L2 两段化（D1）：create 惰性（无 prompt）先行 → dispatched(session:) 落账 → inject 投 boot——
# 保 LEDGER_FAILED→零工作不变量；create/health 失败发生在落账前 → API=0 回落 run（账本与纯 run 一致，零残留）
SID=""
if [ "$API" = 1 ]; then
  SID=$(timeout 20 bash "$RT" create "$PDIR" "$CTITLE" 2>/dev/null) || SID=""
  [ -z "$SID" ] && API=0
fi
# gt-2845③：run 通道预生成外部 sid——spike 实证服务端接受 run --session 外部 id（2026-10-23，ses_<26> rc0 回显同 id）；
# dispatched session: 两通道统一承载子 sid（api=create 返回，run=预生成经 --session 落会话）
[ -z "$SID" ] && SID="ses_$(head -c64 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c26)"
PARGS=(--actor "$ACTOR" --project "$PROJNAME" --event dispatched --task "$TASK" --target "$PDIR" --child "$CHILD" --run "$LOG" --session "$SID")
[[ -n "$DTASK" ]] && PARGS+=(--dispatcher-task "$DTASK")
# 落账前保险丝复核（gt-2e4f TOCTOU 收口）：dispatch.lock 内重扫账本——检查与落账原子化，
# 并发风暴下先到者占额、后到者 QUOTA 前置拒绝零残留；即落即放，不覆盖 spawn 验证窗
exec 8>"$AGORA_HOME/.git/dispatch.lock"
flock -w "${AGORA_LOCK_WAIT:-5}" 8 || fail QUOTA_LOCK "dispatch 锁超时（${AGORA_LOCK_WAIT:-5}s）；可安全重试" 3
_LS2=$(ledger_scan || true)
[ -n "$_LS2" ] || fail QUOTA_SCAN "锁内账本扫描失败（fail-closed，配额闸拒绝降级）；可安全重试" 3   # ocr-R0/A-F3：空输出若放行＝.live 恒 0 退化→TOCTOU 复辟；|| true 使崩溃场景也达 QUOTA_SCAN（set -e 否则先杀）
read -r _LN2 _ME2 _TOT2 _SELF2 _LDT2 <<<"$_LS2"
if [ "${_SELF2:-0}" = "1" ]; then   # gt-7ca0 场景c 同豁免：锁内复核口径与外闸一致
  (( ${_ME2:-0} > 0 )) && _ME2=$((_ME2-1))
  (( ${_TOT2:-0} > 0 )) && _TOT2=$((_TOT2-1))
fi
quota_check "${_ME2:-0}" "${_TOT2:-0}"   # 分域＋总量双闸复核（gt-8c5b 口径；.live 归属已并入扫描）
POUT=$(bash "$SCRIPTS_DIR/post.sh" "${PARGS[@]}" 2>&1) \
  || { printf '%s\n' "$POUT" >&2; fail LEDGER_FAILED "dispatched 落账失败（详情见 stderr 上一行）" 4; }
DEDUP=$(echo "$POUT" | sed -n 's/.*"dedup":\(true\|false\).*/\1/p')
case "$DEDUP" in true|false) ;; *) fail LEDGER_FAILED "post.sh 输出异常（无 dedup 键）: $POUT" 4;; esac
exec 8>&-

# gt-8a3c：spawn 成功后登记子会话进 sessions.map——通知桥唯一路由源，此前全链无写入方（通知静默根因）；
# gt-6bef：写入口收敛 register-session.sh（注册/刷新/upsert 单源，幂等同 (host,entity,sid) 原位刷 ts，
# 重派新 sid 自然换绑——桥取同实体最新一条）。gt-236a：--role worker（兜底广播行级角色过滤）＋
# task-routing (task,worker) 亲和行（桥精准层定向；重派 spawn 即刷新——worker 重绑同一写入点）。
# 尽力而为：写失败不翻转已成功的派发（账本已 dispatched，假失败引发重复重派）；锁忙＝保洁进行中，
# 跳过本轮登记
register_session() {
  AGORA_HOME="$AGORA_HOME" bash "$SCRIPTS_DIR/register-session.sh" --sid "$SID" --entity "$CHILD" --role worker >/dev/null 2>&1 || :
  AGORA_HOME="$AGORA_HOME" bash "$SCRIPTS_DIR/task-routing.sh" upsert "$TASK" worker "$CHILD" "$SID" >/dev/null 2>&1 || :
}

# 凭据预写（幂等重写）＋ spawn ＋ 验证窗 ＋ 有界重试（一次）
# --auto：无人值守权限放行（未显式 deny 即放行）；子会话 cwd 由 cd 提供（--dir 随 opencode 2.0.32 移除，2026-10-20 实证 exit 1）；AGORA_RUNTIME 覆写为非 opencode 时旗标兼容性自担
# 验证窗口径：本尝试的 EXIT:<try>=<rc> 行——0=过、非零=秒死、窗口尽仍活=过（长任务）
spawn_attempt() {
  local _try="$1" _rc="" _w _pgid
  if [ -n "$WT_DIR" ]; then
    mkdir -p "$WT_DIR/.omo/agora-delegation"
    printf 'gt: %s\nworktree: %s\ndispatched: %s\n' "$TASK" "$(realpath "$WT_DIR")" "$(date -Is)" \
      > "$WT_DIR/.omo/agora-delegation/$TASK.md"
  fi
  echo "SESSION:$_try=$SID" >> "$AGORA_HOME/$LOG"
  # C 二期（gt-0a34）：spawn 落子进程组 id 进 .live（cancel --kill 进程面锚点）；AGORA_TASK 进 argv 使 cmdline 含任务标识（pid 复用防线）
  setsid env AGORA_DEPTH=$NEXT AGORA_HOME="$AGORA_HOME" AGORA_RUNTIME="$RUNTIME" \
    AGORA_BOOT="$BOOT" AGORA_PDIR="$PDIR" AGORA_LIVEF="$AGORA_HOME/$LOG.live" \
    AGORA_LOGF="$AGORA_HOME/$LOG" AGORA_TRY="$_try" AGORA_SID="$SID" AGORA_CTITLE="$CTITLE" \
    AGORA_TASK="$TASK" \
    bash -c 'cd "$AGORA_PDIR" && "$AGORA_RUNTIME" run --auto --session "$AGORA_SID" --title "$AGORA_CTITLE" "$AGORA_BOOT"; rc=$?; echo "EXIT:$AGORA_TRY=$rc" >> "$AGORA_LOGF"; rm -f "$AGORA_LIVEF"' \
    "$TASK" \
    >>"$AGORA_HOME/$LOG" 2>&1 < /dev/null &
  _pgid=$(ps -o pgid= -p "$!" 2>/dev/null | tr -d "[:space:]"); _pgid=${_pgid:-$!}
  printf '%s\n' "$_pgid" > "$AGORA_HOME/$LOG.live"
  grep -q "^EXIT:$_try=" "$AGORA_HOME/$LOG" 2>/dev/null && rm -f "$AGORA_HOME/$LOG.live" || true   # 秒死竞态：子进程自删 .live 后又被本写入复活
  for _w in $(seq 1 "${AGORA_VERIFY_WIN:-10}"); do
    _rc=$(sed -n "s/^EXIT:$_try=//p" "$AGORA_HOME/$LOG" 2>/dev/null | tail -1)
    [ -n "$_rc" ] && { [ "$_rc" = "0" ] && return 0 || return 1; }
    sleep 1
  done
  return 0
}
spawn_died_diag() {   # 秒死→日志尾落 diagnosed（失败必须响；重试间幂等窗天然去重同文落账）
  bash "$SCRIPTS_DIR/post.sh" --actor "$ACTOR" --project "$PROJNAME" --event diagnosed \
    --task "$TASK" --conclusion "$(tail -n 5 "$AGORA_HOME/$LOG" | tr '\n' ' ' | tr -d '|')" >/dev/null 2>&1 || true
}
api_alive_wait() {  # D7 验证窗：轮询 idle——dead=秒死；idle=过；窗口尽仍 running=过（与 run「窗口尽仍活=过」同口径）
  local _try="$1" _w _st
  for _w in $(seq 1 "${AGORA_VERIFY_WIN:-10}"); do
    _st=$(timeout "${AGORA_API_TIMEOUT:-15}" bash "$RT" status "$SID" 2>/dev/null || echo dead)
    case "$_st" in
      idle) echo "ALIVE:$_try=idle" >> "$AGORA_HOME/$LOG"; return 0 ;;
      dead) echo "ALIVE:$_try=dead" >> "$AGORA_HOME/$LOG"; return 1 ;;
    esac
    sleep 1
  done
  echo "ALIVE:$_try=running" >> "$AGORA_HOME/$LOG"; return 0
}
api_spawn_attempt() {  # D2：log/.live/凭据与 run 通道对称（poll 孤儿判据与配额计数不破）
  local _try="$1" _rc _ipid
  if [ -n "$WT_DIR" ]; then
    mkdir -p "$WT_DIR/.omo/agora-delegation"
    printf 'gt: %s\nworktree: %s\ndispatched: %s\n' "$TASK" "$(realpath "$WT_DIR")" "$(date -Is)" \
      > "$WT_DIR/.omo/agora-delegation/$TASK.md"
  fi
  echo "SESSION:$_try=$SID" >> "$AGORA_HOME/$LOG"
  # C 二期（gt-0a34）：setsid 独立进程组（kill -- -pgid 安全），pgid 同落 .live（与 run 通道对称）
  setsid timeout 30 bash "$RT" inject "$SID" "$BOOT" >>"$AGORA_HOME/$LOG" 2>&1 &
  _ipid=$!
  printf '%s\n' "$_ipid" > "$AGORA_HOME/$LOG.live"
  if ! wait "$_ipid"; then
    echo "INJECT:$_try=fail" >> "$AGORA_HOME/$LOG"; rm -f "$AGORA_HOME/$LOG.live"; return 1
  fi
  api_alive_wait "$_try"; _rc=$?
  rm -f "$AGORA_HOME/$LOG.live"
  return $_rc
}
if [ "$API" = 1 ]; then
  if ! api_spawn_attempt 1; then
    spawn_died_diag
    if ! api_spawn_attempt 2; then
      spawn_died_diag
      # D3：落账后 API 两连败 → run 通道兜底（dispatched 已落账不重发；session: 指向死 sid 为已知极限，diagnosed 已响）
      if ! spawn_attempt 1; then
        spawn_died_diag
        if ! spawn_attempt 2; then
          spawn_died_diag
          fail SPAWN_DIED "子会话 API+run 四连秒死（run log: $LOG；diagnosed 已落账）" 9
        fi
      fi
    fi
  fi
  register_session
  echo "{\"dispatch_id\":\"$DID\",\"mode\":\"spawned\",\"channel\":\"api\",\"session\":\"$SID\",\"child_actor\":\"$CHILD@$PROJNAME\",\"run\":\"$LOG\",\"dedup\":${DEDUP:-false}${AW_EXT}${VWARN_EXT}}"
  exit 0
fi
if ! spawn_attempt 1; then
  spawn_died_diag
  if ! spawn_attempt 2; then
    spawn_died_diag
    fail SPAWN_DIED "子会话两连秒死（run log: $LOG；diagnosed 已落账）" 9
  fi
fi

register_session
echo "{\"dispatch_id\":\"$DID\",\"mode\":\"spawned\",\"child_actor\":\"$CHILD@$PROJNAME\",\"run\":\"$LOG\",\"dedup\":${DEDUP:-false}${AW_EXT}${VWARN_EXT}}"
