#!/usr/bin/env bash
# register-session.sh —— sessions.map 单源注册面（gt-6bef）：注册/刷新/校验三合一
# 用法: register-session.sh --sid ID (--cwd DIR | --entity NAME) [--check-only]
#   注册（缺省）＝幂等 upsert：同 (host,entity,sid) 行原位刷 ts（idle 活性语义——poll 保洁按
#   最后刷新算，长活会话不超龄），缺行补登（掉册自愈）。实体缺省由 --cwd 经 resolve_entity
#   裁决（worktree 归一主仓，与 dispatch 同口径）；--entity 显式指定（调用方已持裁决结果时免重解析）。
#   --check-only＝只校验在册＋未超龄（AGORA_SESSION_TTL_H，缺省 24，与 poll 同源；<=0＝不设 TTL
#   在册即新，与 poll「0=不清」同义——两消费点同一契约），不过→
#   stderr JSON {"code":"REGISTER_REQUIRED","hint":…}，rc=3。
# 通道契约（gt-6bef）：MCP serve 模式 server 进程无会话上下文（env/进程树均无区分度，/proc 实证），
# 会话级绑定唯一落点=enforcer 插件（原生持 sessionID）。本脚本是插件/CI（WRAP_ID 等外部 id 作
# sid 同注册，零特判）/dispatch 子会话（gt-8a3c）登记的统一写入口。
set -euo pipefail
AGORA_HOME="${AGORA_HOME:?AGORA_HOME 未设置——export AGORA_HOME=\$HOME/plaza 后重试，或经 MCP server env 注入}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SID=""; CWD=""; ENT=""; CHECK=0
while [[ $# -gt 0 ]]; do case "$1" in
  --sid) SID="$2"; shift 2;; --cwd) CWD="$2"; shift 2;; --entity) ENT="$2"; shift 2;; --check-only) CHECK=1; shift;;
  *) echo '{"code":"VALIDATION_FAILED","message":"unknown arg"}' >&2; exit 2;;
esac; done
[[ -n "$SID" && ( -n "$ENT" || -n "$CWD" ) ]] || { echo '{"code":"VALIDATION_FAILED","message":"--sid 与 --cwd/--entity 必填"}' >&2; exit 2; }
[[ "$SID" =~ ^[^[:space:][:cntrl:]]{1,128}$ ]] || { echo '{"code":"VALIDATION_FAILED","message":"--sid 含空白/控制字符或超 128 字符（sessions.map 行伪造面），拒绝"}' >&2; exit 2; }
HINT="bash $SCRIPTS_DIR/register-session.sh --sid <会话id> --cwd <项目目录> 注册；或重启会话（注册 hook 自动登记）；或 post(proposal) 自报名"
req() { python3 -c 'import json,sys; print(json.dumps({"code":"REGISTER_REQUIRED","hint":sys.argv[1]},ensure_ascii=False),file=sys.stderr)' "$1"; exit 3; }
if [[ -z "$ENT" ]]; then
  ENT=$(PYTHONPATH="$SCRIPTS_DIR" python3 - "$AGORA_HOME" "$CWD" <<'PYEOF'
import sys, agora_lib as lib
r = lib.resolve_entity(sys.argv[1], sys.argv[2])
print(r[0] if r else "")
PYEOF
)
  [[ -n "$ENT" ]] || req "caller not in roster（无实体覆盖 $CWD）：$HINT"
fi
[[ "$ENT" =~ ^[^[:space:][:cntrl:]]{1,128}$ ]] || { echo '{"code":"VALIDATION_FAILED","message":"--entity 含空白/控制字符或超 128 字符（sessions.map 行伪造面），拒绝"}' >&2; exit 2; }
SMAP="$AGORA_HOME/sessions.map"
mkdir -p "$AGORA_HOME/.git" 2>/dev/null || true
(
  flock -w "${AGORA_LOCK_WAIT:-5}" 9 || { echo '{"code":"LOCK_TIMEOUT","message":"sessions.map 锁忙"}' >&2; exit 4; }
  [[ -f "$SMAP" ]] || printf '# <机器名>  <agent名>  <opencode session id>  <登记时间>（多机：仅本机条目算"在场"）\n' > "$SMAP"
  PYTHONPATH="$SCRIPTS_DIR" python3 - "$SMAP" "$(hostname)" "$ENT" "$SID" "$CHECK" "${AGORA_SESSION_TTL_H:-24}" "$HINT" <<'PYEOF'
import json, sys, os
from datetime import datetime
smap, host, ent, sid, check, ttl_h, hint = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1", float(sys.argv[6]), sys.argv[7]
for v in (sid, ent):   # 消费端语义二次闸（评审R1 W1/W2/W3）：bash [[:class:]] 随调用方 locale 退化——C locale 放行 U+2028/U+3000/无效字节，NBSP 任何 locale 放行而 python split/splitlines 认其为分隔符；isprintable 连带拒控制符/代理字符（无效字节）/零宽
    if not (v.isprintable() and v.split() == [v] and 1 <= len(v) <= 128):
        print(json.dumps({"code": "VALIDATION_FAILED", "message": "sid/entity 含不可打印或空白分隔字符（sessions.map 行伪造面）"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(2)
def die(reason):
    print(json.dumps({"code": "REGISTER_REQUIRED", "reason": reason, "hint": hint}, ensure_ascii=False), file=sys.stderr)
    sys.exit(3)
lines = open(smap, encoding="utf-8").read().splitlines() if os.path.exists(smap) else []
idx = next((i for i, l in enumerate(lines)
            if not l.startswith("#") and len(l.split()) >= 3 and l.split()[:3] == [host, ent, sid]), None)
if check:
    if idx is None:
        die(f"session 不在册（host={host} entity={ent} sid={sid}）")
    p = lines[idx].split()
    try:
        ts = datetime.fromisoformat(p[3]).timestamp()
    except Exception:
        try: ts = float(p[3])
        except Exception: ts = None
    if ts is None or (ttl_h > 0 and (datetime.now().timestamp() - ts) / 3600 > ttl_h):
        die(f"session 在册但已超龄或时间戳不可解析（TTL={ttl_h:g}h）")
    print(json.dumps({"registered": True, "fresh": True, "entity": ent}, ensure_ascii=False))
    sys.exit(0)
now = datetime.now().astimezone().isoformat(timespec="seconds")
refreshed = idx is not None
if refreshed:
    p = lines[idx].split()
    lines[idx] = " ".join([host, ent, sid, now] + p[4:])   # 原位刷 ts，保留扩展列
else:
    lines.append(f"{host} {ent} {sid} {now}")
tmp = smap + ".tmp"   # 原子写（评审R1 W3）：open("w") 先截断后写，写路径任何异常都会放大成全表清零——tmp+replace 使异常只留旧表
open(tmp, "w", encoding="utf-8").write("\n".join(lines) + "\n")
os.replace(tmp, smap)
print(json.dumps({"registered": True, "refreshed": refreshed, "entity": ent}, ensure_ascii=False))
PYEOF
) 9>"$AGORA_HOME/.git/sessions.map.lock"
