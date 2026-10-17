#!/usr/bin/env bash
# smoke-test.sh —— agora-mcp 接口冒烟测试套件（自包含，不污染真实广场）
# 用法: bash tests/smoke-test.sh   （AGORA_PKG 缺省取包根目录）
# 覆盖：十二工具 + 事件全生命周期 + 幂等窗口 + 验证门 + 并发 + doctor + MCP 协议 + 双机同步 + HTTP 只读窗口
# 退出码：0 全绿；1 有 FAIL
set -u
PKG="${AGORA_PKG:-$(cd "$(dirname "$0")/.." && pwd)}"
T=$(mktemp -d)
export AGORA_HOME="$T/agora" AGORA_LOCK_WAIT=30 AGORA_VERIFY_TIMEOUT=30
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   | $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL | $1"; }
check() { # check <名称> <期望非空命令...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi
}

echo "===== 环境自举 ====="
bash "$PKG/scripts/init.sh" >/dev/null 2>&1
check "init.sh 自举" test -d "$AGORA_HOME/.git"
check "init 幂等（再跑一次）" bash "$PKG/scripts/init.sh"

# 测试项目与两个身份（tester=worker, rival=冲突者）
PROJ="$T/proj"; mkdir -p "$PROJ"; cd "$PROJ" && git init -q . && echo FIXED > app.txt && git add -A && git -c user.name=t -c user.email=t@local commit -qm init
PROJ2="$T/proj2"; mkdir -p "$PROJ2"; cd "$PROJ2" && git init -q .
mkdir -p "$AGORA_HOME/wiki/entities"
printf -- '---\nname: tester\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$PROJ" > "$AGORA_HOME/wiki/entities/tester.md"
printf -- '---\nname: rival\ndirs:\n  - %s\ncan_spawn: false\n---\n' "$PROJ2" > "$AGORA_HOME/wiki/entities/rival.md"
cd "$AGORA_HOME" && git add -A && AGORA_MECHANICAL=1 git commit -qm "entities"

POST() { local who="$1"; shift; bash "$AGORA_HOME/scripts/post.sh" --actor "$who" --project "${who#*@}" "$@"; }
TC()   { bash "$AGORA_HOME/scripts/task-create.sh"; }

echo "===== agora_task_create ====="
OUT=$(TITLE="计划根" TC); PLAN=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
[[ "$PLAN" =~ ^gt-[0-9a-f]{4}$ ]] && ok "task_create 分配 hash ID" || fail "task_create 分配 hash ID"
OUT=$(TITLE="任务A" VERIFY="grep -q FIXED app.txt" PROJECT_DIR="$PROJ" PARENT="$PLAN" TC)
A=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
OUT=$(TITLE="任务B" VERIFY="grep -q FIXED app.txt" PROJECT_DIR="$PROJ" PARENT="$PLAN" TC)
B=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
OUT=$(TITLE="任务C" TC); C=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
check "任务页已生成" test -f "$AGORA_HOME/wiki/tasks/$A.md"
grep -q "$C" "$AGORA_HOME/board/todo.md" && ok "task_create 后 todo 即时可见（同锁重推导）" || fail "task_create 后 todo 即时可见（同锁重推导）"
grep -q "^parent: $PLAN" "$AGORA_HOME/wiki/tasks/$A.md" && ok "parent 写入 frontmatter" || fail "parent 写入 frontmatter"
TITLE="坏" VERIFY="true" TC 2>/dev/null; [[ $? -eq 2 ]] && ok "verify 缺 project_dir 被拒(rc=2)" || fail "verify 缺 project_dir 被拒(rc=2)"
TITLE="坏" DEPS="gt-zzzz" TC 2>/dev/null; [[ $? -eq 5 ]] && ok "deps 引用不存在被拒(rc=5)" || fail "deps 引用不存在被拒(rc=5)"

echo "===== 认领 / done / verify 门 ====="
POST tester@proj --event claimed --task "$A" >/dev/null
POST tester@proj --event done --task "$A" --commit HEAD --evidence "通过" >/dev/null \
  && ok "done+verify 通过" || fail "done+verify 通过"
POST tester@proj --event claimed --task "$B" >/dev/null
OUT=$(POST rival@proj2 --event claimed --task "$B" 2>&1)
echo "$OUT" | grep -q "claim_conflict:tester@proj" && ok "claim 冲突派生 claim_conflict" || fail "claim 冲突派生 claim_conflict"
grep -q "claim_conflict" "$AGORA_HOME/board/conflicts.md" 2>/dev/null && ok "claim_conflict 已派生入板" || fail "claim_conflict 已派生入板"
printf 'BROKEN\n' > "$PROJ/app.txt"
OUT=$(POST tester@proj --event done --task "$B" --commit HEAD --evidence "假交付" 2>&1)
[[ $? -eq 4 ]] && echo "$OUT" | grep -q VERIFY_FAILED && ok "verify 失败拒 done(rc=4)" || fail "verify 失败拒 done(rc=4)"
grep -q "event:verify_failed" "$AGORA_HOME"/log/*/*.md && ok "verify_failed 落账" || fail "verify_failed 落账"
printf 'FIXED\n' > "$PROJ/app.txt"

echo "===== 幂等：连续窗口语义 ====="
POST tester@proj --event claimed --task "$C" >/dev/null
OUT=$(POST tester@proj --event claimed --task "$C")   # 立即重发，中间无事件 = 重试
echo "$OUT" | grep -q '"dedup":true' && ok "连续重复判重试（dedup:true）" || fail "连续重复判重试（dedup:true）"
POST tester@proj --event cancelled --task "$C" --reason "x" >/dev/null
POST tester@proj --event reopened --task "$C" --reason "y" >/dev/null
OUT=$(POST tester@proj --event claimed --task "$C")   # 内容与首次 claim 相同，但隔了事件 = 合法迁移
echo "$OUT" | grep -q '"dedup":true' && fail "reopen 后 re-claim 被误吞" || ok "reopen 后 re-claim 正常落账"

echo "===== cancelled / reopened 生命周期 ====="
POST tester@proj --event cancelled --task "$B" --reason "取消" >/dev/null
! grep -q "$B" "$AGORA_HOME/board/in-progress.md" && ok "cancelled 后出板" || fail "cancelled 后出板"
POST tester@proj --event reopened --task "$B" --reason "恢复" >/dev/null
OUT=$(POST tester@proj --event claimed --task "$B")   # 与首次 claim 内容相同但隔了事件
echo "$OUT" | grep -q '"dedup":true' && fail "B reopen 后 re-claim 被误吞" || ok "B reopen 后 re-claim 落账"
POST tester@proj --event done --task "$B" --commit HEAD --evidence "通过" >/dev/null && ok "reopen 后 done" || fail "reopen 后 done"

echo "===== 计划进度聚合 ====="
grep -q "2/2 完成" "$AGORA_HOME/board/todo.md" && ok "计划聚合 2/2" || fail "计划聚合 2/2"

echo "===== agora_history ====="
H=$(TASK="$B" bash "$AGORA_HOME/scripts/history.sh")
N=$(echo "$H" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")
[ "$N" -eq 7 ] && ok "history 事件链完整（7 条）" || fail "history 事件链完整（$N 条, want 7）"
echo "$H" | python3 -c "
import json,sys
evs=[e['event'] for e in json.load(sys.stdin)['events']]
want=['claimed','verify_failed','cancelled','reopened','claimed','done','claimed']  # rival 冲突 claim 在 proj2 分片，权威序排最后
assert evs==want, evs
" && ok "history 顺序权威" || fail "history 顺序权威"

echo "===== agora_attach（证据落项目库） ====="
cd "$PROJ" && echo "12 passed, 0 failed" > pytest-report.txt
HEAD_BEFORE=$(git -C "$PROJ" rev-parse HEAD)
OUT=$(ACTOR=tester@proj TASK="$A" FILES="pytest-report.txt" NOTE="测试报告" PROJECT_DIR="$PROJ" bash "$AGORA_HOME/scripts/attach.sh")
ATT_CMT=$(echo "$OUT" | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p')
[[ -n "$ATT_CMT" ]] && ok "attach 返回证据 commit" || fail "attach 返回证据 commit"
git -C "$PROJ" rev-parse -q --verify "refs/agora/evidence/$A" >/dev/null && ok "证据 ref 已建（orphan）" || fail "证据 ref 已建（orphan）"
[[ "$(git -C "$PROJ" rev-parse HEAD)" == "$HEAD_BEFORE" ]] && ok "工作区 HEAD 未动" || fail "工作区 HEAD 未动"
[[ "$(git -C "$PROJ" status --porcelain)" == "?? pytest-report.txt" ]] && ok "工作区/index 未污染" || fail "工作区/index 未污染"
git -C "$PROJ" show "$ATT_CMT:pytest-report.txt" | grep -q "12 passed" && ok "证据内容可取回" || fail "证据内容可取回"
cat "$AGORA_HOME"/log/*/*.md | grep "event:attached" | grep -q "@$ATT_CMT" && ok "attached 事件落账（URL@commit）" || fail "attached 事件落账（URL@commit）"
# 链式：第二次 attach 以第一次为父
echo "v2" > "$PROJ/pytest-report.txt"
OUT2=$(ACTOR=tester@proj TASK="$A" FILES="pytest-report.txt" PROJECT_DIR="$PROJ" bash "$AGORA_HOME/scripts/attach.sh")
ATT_CMT2=$(echo "$OUT2" | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p')
[[ "$(git -C "$PROJ" rev-parse "$ATT_CMT2^")" == "$ATT_CMT" ]] && ok "证据链式（二次 attach 以前次为父）" || fail "证据链式"
ACTOR=tester@proj TASK="$A" FILES="不存在.txt" PROJECT_DIR="$PROJ" bash "$AGORA_HOME/scripts/attach.sh" 2>/dev/null
[[ $? -eq 2 ]] && ok "attach 缺文件被拒(rc=2)" || fail "attach 缺文件被拒(rc=2)"
ACTOR=tester@proj TASK="gt-zzzz" FILES="pytest-report.txt" PROJECT_DIR="$PROJ" bash "$AGORA_HOME/scripts/attach.sh" 2>/dev/null
[[ $? -eq 5 ]] && ok "attach 未知任务被拒(rc=5)" || fail "attach 未知任务被拒(rc=5)"

echo "===== 并发写入 ====="
for i in $(seq 1 10); do POST tester@proj --event proposal --body "相同提案" >/dev/null 2>&1 & done; wait
for i in $(seq 1 10); do POST tester@proj --event proposal --body "提案$i" >/dev/null 2>&1 & done; wait
S=$(cat "$AGORA_HOME"/log/*/*.md | grep -c "相同提案"); D=$(cat "$AGORA_HOME"/log/*/*.md | grep -c "event:proposal")
[ "$S" -eq 1 ] && [ "$D" -eq 11 ] && ok "20 并发：相同×10→1，不同×10→10" || fail "20 并发（相同=$S 总=$D，want 1/11）"

echo "===== MCP 协议（十二工具 + 权限） ====="
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" "$PLAN" <<'PYEOF' && ok "MCP 全链" || fail "MCP 全链"
import json, subprocess, sys
srv, plan = sys.argv[1], sys.argv[2]
p = subprocess.Popen(["python3", srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
r = rpc("initialize", {"protocolVersion":"2025-03-26"})
assert "instructions" in r["result"] and len(r["result"]["instructions"]) < 600  # 含路径插值后的预算
assert "owner=me" in r["result"]["instructions"]  # 开场仪式含个人队列提示
tools = [t["name"] for t in rpc("tools/list", i=2)["result"]["tools"]]
assert len(tools) == 12, tools
r = rpc("tools/call", {"name":"agora_task_create","arguments":{"title":"MCP任务","parent":plan}}, 3)
tid = json.loads(r["result"]["content"][0]["text"])["task"]
rpc("tools/call", {"name":"agora_post","arguments":{"event":"claimed","task":tid}}, 4)
h = json.loads(rpc("tools/call", {"name":"agora_history","arguments":{"task":tid}}, 5)["result"]["content"][0]["text"])
assert h["count"] == 1 and h["events"][0]["event"] == "claimed"
b = json.loads(rpc("tools/call", {"name":"agora_board","arguments":{}}, 6)["result"]["content"][0]["text"])
assert "2/3 完成" in b["board"]["todo"], b["board"]["todo"]
open("mcp-evidence.txt","w").write("evidence via MCP")
r = rpc("tools/call", {"name":"agora_attach","arguments":{"task":tid,"files":["mcp-evidence.txt"],"note":"MCP 附件"}}, 7)
att = json.loads(r["result"]["content"][0]["text"])
assert "@" in att["url"] + "@" + att["commit"] and att["ref"].endswith(tid), att
p.stdin.close()
PYEOF
# 未注册目录调写工具被拒
cd "$T" && python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "未注册写工具被拒" || fail "未注册写工具被拒"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = rpc("tools/call", {"name":"agora_task_create","arguments":{"title":"x"}}, 2)
assert json.loads(r["result"]["content"][0]["text"]).get("code") == "NOT_REGISTERED"
p.stdin.close()
PYEOF

echo "===== 远端同步与 SSH 签名 ====="
REMOTE="$T/remote.git"; git init -q --bare "$REMOTE"
# 机器 A 先配远端并 push 全量历史
AGORA_HOME="$AGORA_HOME" AGORA_PKG="$PKG" AGORA_REMOTE="file://$REMOTE" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
git -C "$AGORA_HOME" remote get-url origin | grep -q "remote.git" && ok "已有仓库补配远端" || fail "已有仓库补配远端"
# 机器 B：clone 远端后 init（骨架必须幂等补齐 scripts/）
HOME2="$T/agora-b"; git clone -q "file://$REMOTE" "$HOME2" 2>/dev/null
AGORA_HOME="$HOME2" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
[[ -f "$HOME2/scripts/post.sh" ]] && ok "clone 后 init 补齐骨架" || fail "clone 后 init 补齐骨架"
# 非 SSH 远端被拒
AGORA_HOME="$T/agora-x" AGORA_PKG="$PKG" AGORA_REMOTE="https://github.com/x/y.git" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "https 远端被拒(rc=1)" || fail "https 远端被拒(rc=1)"
# 双机写入：B 发事件 → A 写前 pre-pull 应合并到 B 的事件
AGORA_HOME="$HOME2" bash "$HOME2/scripts/post.sh" --actor rival@proj2 --project proj2 --event proposal --body "B机的提案" >/dev/null
POST tester@proj --event proposal --body "A机的提案" >/dev/null
cat "$AGORA_HOME"/log/*/*.md | grep -q "B机的提案" && ok "pre-pull 合并远端事件" || fail "pre-pull 合并远端事件"
git -C "$REMOTE" log --format=%s 2>/dev/null | grep -q "proposal" && ok "post 后 push 到远端" || fail "post 后 push 到远端"
# 读路径同步：B 再发一条，A 不写任何东西、只调 agora_sync 就应看到
AGORA_HOME="$HOME2" bash "$HOME2/scripts/post.sh" --actor rival@proj2 --project proj2 --event proposal --body "B机第二提案" >/dev/null
SYNCO=$(bash "$AGORA_HOME/scripts/sync.sh" pre)
echo "$SYNCO" | grep -q '"merged_new":true' && ok "agora_sync 显式拉取（merged_new=true）" || fail "agora_sync 显式拉取（$SYNCO）"
cat "$AGORA_HOME"/log/*/*.md | grep -q "B机第二提案" && ok "读路径同步后可见他机事件" || fail "读路径同步后可见他机事件"
# agora_who 名册发现（经 MCP）
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "agora_who 名册发现" || fail "agora_who 名册发现"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = json.loads(rpc("tools/call", {"name":"agora_who","arguments":{}}, 2)["result"]["content"][0]["text"])
names = {e["name"]: e for e in r["roster"]}
assert r["you"] == "tester@proj" and "rival" in names and names["tester"]["here"] is True and names["rival"]["here"] is False, r
r2 = json.loads(rpc("tools/call", {"name":"agora_sync","arguments":{}}, 3)["result"]["content"][0]["text"])
assert r2.get("sync") == "ok", r2
p.stdin.close()
PYEOF
# dispatch 机器隔离：他机的在场记录不触发 notified
printf '%s tester sess-1 2026-10-14\n' "foreign-host" > "$AGORA_HOME/scripts/sessions.map"
OUT=$(AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$C" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' && ok "他机在场记录被忽略（仍派生）" || fail "他机在场记录被忽略（$OUT）"
rm -f "$AGORA_HOME"/raw/dispatches/*.live
printf '%s tester sess-1 2026-10-14\n' "$(hostname)" > "$AGORA_HOME/scripts/sessions.map"
OUT=$(AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$C" 2>&1)
echo "$OUT" | grep -q '"mode":"notified"' && ok "本机在场降级为通知" || fail "本机在场降级为通知（$OUT）"
printf '# <机器名>  <agent名>  <opencode session id>  <登记时间>\n' > "$AGORA_HOME/scripts/sessions.map"
# SSH 签名
ssh-keygen -q -t ed25519 -N "" -f "$T/id_ed25519" 2>/dev/null
if [[ -f "$T/id_ed25519.pub" ]]; then
  AGORA_HOME="$AGORA_HOME" AGORA_PKG="$PKG" AGORA_SIGN_KEY="$T/id_ed25519.pub" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
  [[ "$(git -C "$AGORA_HOME" config commit.gpgsign)" == "true" ]] && ok "签名配置启用" || fail "签名配置启用"
  POST tester@proj --event proposal --body "签名提交测试" >/dev/null
  SIG=$(git -C "$AGORA_HOME" log --format='%G?' -1)
  [[ "$SIG" == "G" || "$SIG" == "U" ]] && ok "机械提交带有效签名（%G?=$SIG）" || fail "机械提交带有效签名（%G?=$SIG）"
else
  echo "warn | ssh-keygen 不可用，跳过签名测试"
fi

echo "===== HTTP 只读窗口（agora-http） ====="
HPORT=18471
AGORA_HOME="$AGORA_HOME" AGORA_HTTP_PORT=$HPORT python3 "$PKG/server/agora_http.py" >/dev/null 2>&1 &
HPID=$!
sleep 1
python3 - "$HPORT" "$PLAN" "$B" <<'PYEOF' && ok "HTTP 七端点 + Web 页" || fail "HTTP 七端点 + Web 页"
import json, sys, urllib.request
port, plan, taskb = sys.argv[1], sys.argv[2], sys.argv[3]
B = f"http://127.0.0.1:{port}"
def get(p):
    with urllib.request.urlopen(B+p, timeout=8) as r: return r.status, r.read()
s, body = get("/")
assert s == 200 and "Agora 广场".encode() in body  # Web 页可达
s, b = get("/api/board"); d = json.loads(b)
assert "2/3 完成" in d["views"]["todo"], d["views"]["todo"][:200]
s, b = get("/api/tasks"); d = json.loads(b)
assert any(t.get("id") == plan for t in d["tasks"])
s, b = get("/api/task?id="+plan); d = json.loads(b)  # 计划根只有页面没有事件
assert "计划根" in d["page"] and d["events"] == []
s, b = get("/api/task?id="+taskb); d = json.loads(b)  # B 有完整 7 事件链
assert len(d["events"]) == 7 and d["events"][0]["ref"].startswith("log/")
s, b = get("/api/events?limit=10"); d = json.loads(b)
assert d["count"] > 0 and d["events"][-1]["actor"]
s, b = get("/api/entities"); d = json.loads(b)
assert any(e["name"] == "tester" and e["can_spawn"] for e in d["roster"])
s, b = get("/api/inbox?name=tester"); d = json.loads(b)
assert d["count"] >= 0 and d["name"] == "tester"
PYEOF
python3 - "$HPORT" <<'PYEOF' && ok "wiki 路径穿越被拒（400）" || fail "wiki 路径穿越被拒"
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/api/wiki?path=../log/x.md", timeout=5)
    raise SystemExit(1)
except urllib.error.HTTPError as e:
    assert e.code == 400, e.code
PYEOF
kill $HPID 2>/dev/null || true
# 随机端口分配 + 端口发现（AGORA_HTTP_PORT=0 → .git/httpd.json → agora_who.http）
AGORA_HOME="$AGORA_HOME" AGORA_HTTP_PORT=0 python3 "$PKG/server/agora_http.py" >/dev/null 2>&1 &
HPID2=$!
sleep 1
python3 - "$AGORA_HOME" <<'PYEOF' && ok "随机端口分配 + 运行文件发现" || fail "随机端口分配 + 运行文件发现"
import json, os, sys, urllib.request
d = json.load(open(os.path.join(sys.argv[1], ".git", "httpd.json")))
assert d["port"] > 0 and d["url"].endswith(f":{d['port']}/")
with urllib.request.urlopen(d["url"], timeout=5) as r:
    assert r.status == 200
PYEOF
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "agora_who 报告 http 端口" || fail "agora_who 报告 http 端口"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = json.loads(rpc("tools/call", {"name":"agora_who","arguments":{}}, 2)["result"]["content"][0]["text"])
assert r.get("http", {}).get("port", 0) > 0 and r["http"]["url"].startswith("http://"), r.get("http")
p.stdin.close()
PYEOF
kill $HPID2 2>/dev/null || true
for i in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$AGORA_HOME/.git/httpd.json" ]] || break; sleep 0.3; done
[[ -f "$AGORA_HOME/.git/httpd.json" ]] && fail "退出后运行文件已清理" || ok "退出后运行文件已清理"
# 缺省即随机（不设 AGORA_HTTP_PORT）
env -u AGORA_HTTP_PORT AGORA_HOME="$AGORA_HOME" python3 "$PKG/server/agora_http.py" >/dev/null 2>&1 &
HPID3=$!
sleep 1
python3 - "$AGORA_HOME" <<'PYEOF' && ok "缺省端口即随机（≠8471）" || fail "缺省端口即随机"
import json, os, sys
d = json.load(open(os.path.join(sys.argv[1], ".git", "httpd.json")))
assert 0 < d["port"] != 8471, d
PYEOF
kill $HPID3 2>/dev/null || true
for i in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$AGORA_HOME/.git/httpd.json" ]] || break; sleep 0.3; done
# 运行文件绝不能进 git（跨机同步会带错端口）
git -C "$AGORA_HOME" status --porcelain | grep -q "httpd.json" && fail "运行文件未入库" || ok "运行文件未入库"

echo "===== poll.sh 唤醒与看门狗 ====="
# 外机实体（目录本机不存在）：mention 不被拾取
printf -- '---\nname: ghost\ndirs:\n  - /nonexistent-ghost-xyz\ncan_spawn: true\n---\n' > "$AGORA_HOME/wiki/entities/ghost.md"
cd "$AGORA_HOME" && git add -A >/dev/null && AGORA_MECHANICAL=1 git commit -qm "ghost entity"
POST rival@proj2 --event progress --task "$C" --mention ghost --body "给他机的活" >/dev/null
# 本机拾取：rival 派活给 tester（任务未认领、在 todo）
OUT=$(TITLE="poll唤醒任务" TC); POLLT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST rival@proj2 --event progress --task "$POLLT" --mention tester --body "来接活" >/dev/null
POLL_OUT=$(AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh")
echo "$POLL_OUT" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert any(s['task']=='$POLLT' and s.get('mode')=='spawned' for s in r['spawned']), r
" && ok "poll 拾取本机 mention 并派生" || fail "poll 拾取本机 mention 并派生（$POLL_OUT）"
echo "$POLL_OUT" | grep -q "复查该任务 owner" && ok "拉起模板内置复查 owner 惯例" || fail "拉起模板内置复查 owner 惯例"
echo "$POLL_OUT" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert not any(s['entity']=='ghost' for s in r['spawned']), r['spawned']
" && ok "外机实体不被拾取" || fail "外机实体不被拾取"
# 水位：第二次 poll 不重复派生
POLL_OUT2=$(AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh")
echo "$POLL_OUT2" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert r['spawned']==[], r['spawned']
" && ok "邮件水位不重复派生" || fail "邮件水位不重复派生（$POLL_OUT2）"
# stalled 看门狗（活性 = 本机观察时钟）：先跑一次建立基线（不得误报），
# 再把 poll-state 的 since 拨回 1 小时前模拟停滞 → 应派生 diagnosed
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md 2>/dev/null | grep -q "stalled" \
  && fail "基线 poll 误报 stalled" || ok "基线 poll 不误报（活性时钟自首次观察起计）"
python3 - "$AGORA_HOME" <<'PYEOF'
import json, sys, time
f = sys.argv[1] + "/.git/poll-state.json"
s = json.load(open(f))
assert s.get("_activity"), "无活性跟踪表"
for t in s["_activity"]: s["_activity"][t]["since"] = time.time() - 3600
json.dump(s, open(f, "w"))
PYEOF
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md 2>/dev/null | grep "event:diagnosed" | grep -q "stalled" \
  && ok "stalled 看门狗派生 diagnosed（本机观察时钟）" || fail "stalled 看门狗派生 diagnosed"
# cadence：刚诊断过的任务下轮不重复诊断（diagnosed 事件重建活性时钟）
W1=$(cat "$AGORA_HOME"/log/*/watchdog.md 2>/dev/null | grep -c "event:diagnosed")
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
W2=$(cat "$AGORA_HOME"/log/*/watchdog.md 2>/dev/null | grep -c "event:diagnosed")
[[ "$W1" == "$W2" ]] && ok "看门狗 cadence 不刷屏" || fail "看门狗 cadence 不刷屏（$W1→$W2）"

# 升级阶梯（ESCALATE_AFTER=1）：diagnosed → escalated →（AUTO_REOPEN=1）reopened 回池
OUT=$(TITLE="升级阶梯任务" TC); LADT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST tester@proj --event claimed --task "$LADT" >/dev/null
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null   # 建立活性基线
seed_old() { python3 - "$AGORA_HOME" "$LADT" <<'PYEOF'
import json, sys, time
f = sys.argv[1] + "/.git/poll-state.json"
s = json.load(open(f))
e = s.get("_activity", {}).get(sys.argv[2])
assert e, "无活性跟踪条目"
e["since"] = time.time() - 3600
json.dump(s, open(f, "w"))
PYEOF
}
seed_old; AGORA_WATCHDOG_ESCALATE_AFTER=1 AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md | grep "event:diagnosed" | grep -q "$LADT" \
  || { fail "阶梯第 1 级 diagnosed"; }
# 每次 fire 后看门狗把跟踪条目标记为待采纳；先跑一轮采纳新事件复位时钟，再播种再 fire
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
seed_old; AGORA_WATCHDOG_ESCALATE_AFTER=1 AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md | grep "event:escalated" | grep -q "$LADT" \
  && ok "stalled 升级阶梯：escalated" || fail "stalled 升级阶梯：escalated"
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
seed_old; AGORA_WATCHDOG_ESCALATE_AFTER=1 AGORA_WATCHDOG_AUTO_REOPEN=1 AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
grep -q "^- $LADT" "$AGORA_HOME/board/todo.md" \
  && ok "watchdog 自动回池（reopened → todo）" || fail "watchdog 自动回池（reopened → todo）"

# .live 滞留：超期 → 回溯 dispatched 事件 mention 派单方（每个 did 只提醒一次）
OUT=$(TITLE="stale-live任务" TC); SLT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST tester@proj --event claimed --task "$SLT" >/dev/null
DID_TEST="d-staletest"
POST tester@proj --event dispatched --task "$SLT" --target "$PROJ" --child tester --run "raw/dispatches/$DID_TEST.log" >/dev/null
touch -d "1 hour ago" "$AGORA_HOME/raw/dispatches/$DID_TEST.live"
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md | grep "event:diagnosed" | grep -q ".live 滞留" \
  && ok "stale .live 提醒派单方" || fail "stale .live 提醒派单方"
N1=$(cat "$AGORA_HOME"/log/*/watchdog.md | grep -c ".live 滞留")
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
N2=$(cat "$AGORA_HOME"/log/*/watchdog.md | grep -c ".live 滞留")
[[ "$N1" == "$N2" ]] && ok "stale .live 不重复提醒" || fail "stale .live 不重复提醒（$N1→$N2）"
# 只报告模式：SPAWN=0 → held 不派生
OUT=$(TITLE="poll只报告任务" TC); POLLT2=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST rival@proj2 --event progress --task "$POLLT2" --mention tester --body "再来一单" >/dev/null
POLL_OUT3=$(AGORA_POLL_SPAWN=0 AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh")
echo "$POLL_OUT3" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert any(h['task']=='$POLLT2' for h in r['held']), r
assert not any(s['task']=='$POLLT2' for s in r['spawned']), r
" && ok "POLL_SPAWN=0 只报告不派生" || fail "POLL_SPAWN=0 只报告不派生（$POLL_OUT3）"

echo "===== dispatch 注入防御 ====="
# 非法 task id（可能来自他机邮件摘要）→ 进 bash -c 前被拒
bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task 'gt-1;id' >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "dispatch 拒绝非法 task id" || fail "dispatch 拒绝非法 task id"
# prompt 中的命令替换绝不被执行（env 传数据 + 单引号脚本）
MARK="$T/pwned-$RANDOM"
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" \
  --task "$POLLT" --prompt '$(touch '"$MARK"')' >/dev/null 2>&1
[[ ! -e "$MARK" ]] && ok "dispatch prompt 注入不执行" || fail "dispatch prompt 注入不执行"
# 拉起形态：runtime 参数含 --auto（无人值守权限）与 --dir（echo stub 把参数回显进 dispatch 日志）
AGORA_RUNTIME=echo bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" \
  --task "$POLLT" >/dev/null 2>&1
sleep 1
RLOG=$(ls -t "$AGORA_HOME"/raw/dispatches/*.log | head -1)
grep -q -- '--auto' "$RLOG" && grep -q -- '--dir' "$RLOG" \
  && ok "dispatch 拉起参数含 --auto 与 --dir" || fail "dispatch 拉起参数缺 --auto/--dir（$RLOG）"

echo "===== poll 本地保洁 ====="
# sessions.map TTL：过期本机条目剔除；他机条目与新本机条目保留
H=$(hostname)
printf '# <机器名>  <agent名>  <opencode session id>  <登记时间>\n%s tester ses-old 2026-10-12T10:00:00+00:00\nforeign tester ses-f 2026-10-12T10:00:00+00:00\n%s tester ses-new %s\n' \
  "$H" "$H" "$(date -Iseconds)" > "$AGORA_HOME/scripts/sessions.map"
cd "$AGORA_HOME" && git add -A >/dev/null && AGORA_MECHANICAL=1 git commit -qm "seed sessions" >/dev/null
# inbox 归档：100 天前的邮件（文件名=纳秒时间戳）移入 archive/
mkdir -p "$AGORA_HOME/inbox/tester"
echo "- from:x | ts:y | ref:r | summary:ack none" > "$AGORA_HOME/inbox/tester/$(( $(date +%s) - 100*86400 ))000000000.md"
git add -A >/dev/null && AGORA_MECHANICAL=1 git commit -qm "seed old mail" >/dev/null
POLL_OUT4=$(AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh")
echo "$POLL_OUT4" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert r['sessions_reaped']==1, r
assert r['mails_archived']>=1, r
" && ok "poll 保洁计数（sessions+归档）" || fail "poll 保洁计数（$POLL_OUT4）"
! grep -q "ses-old" "$AGORA_HOME/scripts/sessions.map" \
  && grep -q "ses-new" "$AGORA_HOME/scripts/sessions.map" \
  && grep -q "ses-f" "$AGORA_HOME/scripts/sessions.map" \
  && ok "TTL 只清本机过期条目" || fail "TTL 只清本机过期条目"
ls "$AGORA_HOME/inbox/archive/tester/" 2>/dev/null | grep -q '\.md' \
  && ok "超期邮件入 archive" || fail "超期邮件入 archive"

echo "===== 通知桥（notify-opencode.sh，规格 §8.1） ====="
MOCK_LOG="$T/mock-http.log"; : > "$MOCK_LOG"
python3 - "$MOCK_LOG" "$T/mock-port" >/dev/null 2>&1 <<'PYEOF' &
import sys, http.server
logf, portf = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n).decode()
        auth = self.headers.get("Authorization") or "-"
        open(logf, "a").write(self.path + " | auth=" + auth + " | " + body + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portf, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
MOCK_PID=$!
for i in $(seq 1 20); do [[ -s "$T/mock-port" ]] && break; sleep 0.2; done
MOCK_PORT=$(cat "$T/mock-port")
printf '%s tester ses-test %s\n' "$(hostname)" "$(date -Iseconds)" >> "$AGORA_HOME/scripts/sessions.map"
NB() { AGORA_OPENCODE_URL="http://127.0.0.1:$1" AGORA_OPENCODE_PASSWORD=testpw bash "$AGORA_HOME/scripts/notify-opencode.sh" --once; }
echo "- from:x | ts:y | ref:log/z.md:1 | summary:ack gt-0000" > "$AGORA_HOME/inbox/tester/$(date +%s%N).md"
NB "$MOCK_PORT"
grep -q "/api/session/ses-test/prompt" "$MOCK_LOG" \
  && ok "通知桥注入运行中会话（v2 /api prompt 端点）" || fail "通知桥注入运行中会话"
grep -q '"delivery": "queue"' "$MOCK_LOG" && grep -q "auth=Basic" "$MOCK_LOG" \
  && ok "通知桥 queue 投递 + Basic 认证" || fail "通知桥 queue 投递 + Basic 认证"
echo "- from:x | ts:y | ref:log/z.md:2 | summary:ack gt-0000" > "$AGORA_HOME/inbox/tester/$(date +%s%N)n2.md"
NB "$MOCK_PORT"
[[ $(grep -c "/session/" "$MOCK_LOG") == 1 ]] && ok "通知桥 60s 去抖" || fail "通知桥 60s 去抖"
# TUI server 不可达：静默跳过，不报错不退出非零
printf '%s loner ses-x %s\n' "$(hostname)" "$(date -Iseconds)" >> "$AGORA_HOME/scripts/sessions.map"
mkdir -p "$AGORA_HOME/inbox/loner"
echo "- from:x | ts:y | ref:r | summary:ack gt-0000" > "$AGORA_HOME/inbox/loner/$(date +%s%N).md"
NB 1
[[ $? -eq 0 && $(grep -c "/session/" "$MOCK_LOG") == 1 ]] \
  && ok "通知桥不可达静默跳过" || fail "通知桥不可达静默跳过"
# 无 sessions.map 映射的实体：静默跳过
mkdir -p "$AGORA_HOME/inbox/ghost2"
echo "- from:x | ts:y | ref:r | summary:ack gt-0000" > "$AGORA_HOME/inbox/ghost2/$(date +%s%N).md"
NB "$MOCK_PORT"
[[ $(grep -c "/session/" "$MOCK_LOG") == 1 ]] \
  && ok "无映射实体静默跳过" || fail "无映射实体静默跳过"
kill $MOCK_PID 2>/dev/null || true

echo "===== 项目注册表（wiki/projects） ====="
# 注册项目页（tester 注册 $PROJ，带默认 verify）
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" "$PROJ" <<'PYEOF' && ok "项目页注册" || fail "项目页注册"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = rpc("tools/call", {"name":"agora_wiki_write","arguments":{"path":"projects/proj.md",
  "content":f"name: proj\npath: {sys.argv[2]}\ndesc: 测试项目\nverify: grep -q FIXED app.txt\n"}}, 2)
assert "projects/proj.md" in r["result"]["content"][0]["text"], r
p.stdin.close()
PYEOF
# verify fallback：只给 project_dir，机械层从项目页回填 verify
OUT=$(TITLE="fallback验收任务" PROJECT_DIR="$PROJ" TC)
FBT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
grep -q "^verify: grep -q FIXED app.txt" "$AGORA_HOME/wiki/tasks/$FBT.md" \
  && ok "verify 从项目页回填" || fail "verify 从项目页回填"
# fallback 未命中仍拒绝
TITLE="坏" PROJECT_DIR="$PROJ2" TC 2>/dev/null
[[ $? -eq 2 ]] && ok "无项目页无 verify 仍被拒(rc=2)" || fail "无项目页无 verify 仍被拒(rc=2)"
# agora_who 列出项目注册表
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "agora_who 含项目清单" || fail "agora_who 含项目清单"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = json.loads(rpc("tools/call", {"name":"agora_who","arguments":{}}, 2)["result"]["content"][0]["text"])
assert any(pj["name"]=="proj" and pj.get("verify") for pj in r.get("projects",[])), r.get("projects")
p.stdin.close()
PYEOF
# Q1 遗留：双清 claim（写时互不可见）由推导层回放兜底
POST tester@proj --event claimed --task "$POLLT2" >/dev/null
printf -- '- seq:1 | ts:%s | actor:intruder@proj2 | event:claimed | idem:zz | seen:[] | task:%s\n' \
  "$(date --iso-8601=seconds)" "$POLLT2" >> "$AGORA_HOME/log/$(date +%F)/proj2.md"
bash "$AGORA_HOME/scripts/derive-board.sh"
grep -q "$POLLT2" "$AGORA_HOME/board/conflicts.md" \
  && ok "双清 claim 回放兜底入 conflicts" || fail "双清 claim 回放兜底入 conflicts"

echo "===== 增量推导（derive-cache） ====="
python3 -c "import json;c=json.load(open('$AGORA_HOME/.git/derive-cache.json'));assert c['v']==2 and c['watermark']" \
  && ok "增量缓存已建立" || fail "增量缓存已建立"
S0=$(python3 -c "import json;print(json.load(open('$AGORA_HOME/.git/derive-cache.json'))['stats']['incr'])")
bash "$AGORA_HOME/scripts/derive-board.sh"
S1=$(python3 -c "import json;print(json.load(open('$AGORA_HOME/.git/derive-cache.json'))['stats']['incr'])")
[[ $S1 -gt $S0 ]] && ok "无新事件走增量路径" || fail "无新事件走增量路径（$S0→$S1）"
rm -rf "$T/board.snap"; cp -r "$AGORA_HOME/board" "$T/board.snap"
rm "$AGORA_HOME/.git/derive-cache.json"; bash "$AGORA_HOME/scripts/derive-board.sh"
diff -r "$T/board.snap" "$AGORA_HOME/board" >/dev/null && ok "增量与全量结果一致" || fail "增量与全量结果一致"
# 前缀被改（union 合并重排/脏写）→ 自动回退全量重放，结果不变
SHARD=$(LC_ALL=C ls "$AGORA_HOME"/log/*/*.md | head -1)
sed -i '1i <!-- tampered -->' "$SHARD" 2>/dev/null
F0=$(python3 -c "import json;print(json.load(open('$AGORA_HOME/.git/derive-cache.json'))['stats']['full'])")
bash "$AGORA_HOME/scripts/derive-board.sh"
F1=$(python3 -c "import json;print(json.load(open('$AGORA_HOME/.git/derive-cache.json'))['stats']['full'])")
[[ $F1 -gt $F0 ]] && diff -r "$T/board.snap" "$AGORA_HOME/board" >/dev/null \
  && ok "前缀篡改回退全量且结果一致" || fail "前缀篡改回退全量且结果一致（$F0→$F1）"

echo "===== doctor ====="
# 证据引用推送对账：PROJ 已有本地 evidence refs（attach 段产生）；配空远端 → warn 但不破 ALL GREEN
git init -q --bare "$T/proj-remote.git"
git -C "$PROJ" remote add origin "$T/proj-remote.git" 2>/dev/null || true
OUT=$(bash "$AGORA_HOME/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "warn | 未推送的证据引用" && echo "$OUT" | grep -q "ALL GREEN" \
  && ok "未推送证据 warn 不破 ALL GREEN" || { fail "未推送证据 warn 不破 ALL GREEN"; echo "$OUT"; }
git -C "$PROJ" push -q origin 'refs/agora/evidence/*' >/dev/null 2>&1
OUT=$(bash "$AGORA_HOME/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "ok   | 证据引用推送对账" \
  && ok "推送后证据对账转 ok" || { fail "推送后证据对账转 ok"; echo "$OUT"; }
OUT=$(bash "$AGORA_HOME/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "ALL GREEN" && ok "doctor 全绿" || { fail "doctor 全绿"; echo "$OUT"; }

echo "===== 审核修复回归（v1.17） ====="
# --- task-create 单行字段换行防御（frontmatter 注入） ---
TITLE=$'坏\ntitle: 注入' TC 2>/dev/null; [[ $? -eq 2 ]] && ok "TITLE 换行被拒(rc=2)" || fail "TITLE 换行被拒(rc=2)"
TITLE="换行verify" VERIFY=$'true\nevil: 1' PROJECT_DIR="$PROJ" TC 2>/dev/null
[[ $? -eq 2 ]] && ok "VERIFY 换行被拒(rc=2)" || fail "VERIFY 换行被拒(rc=2)"

# --- post.sh 任务词边界：task:gt-x 不得前缀撞 task:gt-x9 ---
printf -- '---\nid: gt-zzzz\ntitle: 词边界甲\nstatus: open\ndeps: []\n---\n' > "$AGORA_HOME/wiki/tasks/gt-zzzz.md"
printf -- '---\nid: gt-wwww\ntitle: 词边界乙\nstatus: open\ndeps: []\n---\n' > "$AGORA_HOME/wiki/tasks/gt-wwww.md"
printf -- '- seq:901 | ts:%s | actor:rival@proj2 | event:claimed | idem:zz1 | seen:r@1 | task:gt-zzzz9\n' \
  "$(date --iso-8601=seconds)" >> "$AGORA_HOME/log/$(date +%F)/proj2.md"
OUT=$(POST tester@proj --event claimed --task gt-zzzz)
echo "$OUT" | grep -q "claim_conflict" && fail "词边界：gt-zzzz 被 gt-zzzz9 误伤" || ok "词边界：gt-zzzz 不被 gt-zzzz9 误伤"
POST tester@proj --event claimed --task gt-wwww --idem dup9 >/dev/null
printf -- '- seq:902 | ts:%s | actor:tester@proj | event:claimed | idem:other9 | seen:t@1 | task:gt-wwww9\n' \
  "$(date --iso-8601=seconds)" >> "$AGORA_HOME/log/$(date +%F)/proj.md"
OUT=$(POST tester@proj --event claimed --task gt-wwww --idem dup9)   # 中间隔着 gt-wwww9 行，LAST_EV 不得取错
echo "$OUT" | grep -q '"dedup":true' && ok "词边界：幂等 LAST_EV 不被 gt-wwww9 干扰" || fail "词边界：幂等 LAST_EV 不被 gt-wwww9 干扰"

# --- check_mail since 水位：位置匹配 + (日期,行号) 数值回退 ---
mkdir -p "$AGORA_HOME/inbox/rival"
printf -- '- from:a | ts:t | ref:log/2099-01-01/x.md:9 | summary:m9\n'  > "$AGORA_HOME/inbox/rival/1000000000000000001.md"
printf -- '- from:a | ts:t | ref:log/2099-01-01/x.md:10 | summary:m10\n' > "$AGORA_HOME/inbox/rival/1000000000000000002.md"
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" "$PROJ2" "$AGORA_HOME" <<'PYEOF' && ok "check_mail since 水位语义" || fail "check_mail since 水位语义"
import json, subprocess, sys, os
srv, proj2, home = sys.argv[1], sys.argv[2], sys.argv[3]
env = {**os.environ, "AGORA_HOME": home}
def spawn(cwd):
    p = subprocess.Popen(["python3", srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=cwd, env=env)
    def rpc(m, ps=None, i=[0]):
        i[0] += 1
        p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i[0],"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
        return json.loads(p.stdout.readline())
    rpc("initialize", {})
    return p, rpc
def mail(rpc):
    return json.loads(rpc("tools/call", {"name":"agora_check_mail","arguments":{}})["result"]["content"][0]["text"])
def since(rpc, w):
    return json.loads(rpc("tools/call", {"name":"agora_check_mail","arguments":{"since":w}})["result"]["content"][0]["text"])
# tester 邮箱：位置匹配
p1, r1 = spawn(".")
subprocess.run(["bash", f"{home}/scripts/post.sh", "--actor","tester@proj","--project","proj",
                "--event","progress","--task","gt-wwww","--mention","tester","--body","水位1"],
               env=env, capture_output=True)
m1 = mail(r1); w1 = m1["watermark"]
assert m1["count"] >= 1 and w1
assert since(r1, w1)["count"] == 0, "水位即末尾应无新邮件"
subprocess.run(["bash", f"{home}/scripts/post.sh", "--actor","tester@proj","--project","proj",
                "--event","progress","--task","gt-wwww","--mention","tester","--body","水位2"],
               env=env, capture_output=True)
m3 = since(r1, w1)
assert m3["count"] == 1 and m3["unread"][0]["summary"].startswith("progress"), m3
p1.stdin.close()
# rival 邮箱：水位不在列表（已归档）→ 数值回退；字典序会错杀 ":10"（"1"<"8"）
p2, r2 = spawn(proj2)
m4 = since(r2, "log/2099-01-01/x.md:8")
refs = [i["ref"] for i in m4["unread"] if "2099-01-01" in i["ref"]]
assert "log/2099-01-01/x.md:9" in refs and "log/2099-01-01/x.md:10" in refs, refs
p2.stdin.close()
PYEOF

# --- waiting 视图（MCP 枚举 + all 聚合） ---
OUT=$(TITLE="等依赖" TC); WD1=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
OUT=$(TITLE="等依赖者" DEPS="$WD1" TC); WD2=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
bash "$AGORA_HOME/scripts/derive-board.sh" >/dev/null
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" "$WD2" <<'PYEOF' && ok "waiting 视图（枚举+all）" || fail "waiting 视图（枚举+all）"
import json, subprocess, sys
srv, wd2 = sys.argv[1], sys.argv[2]
p = subprocess.Popen(["python3", srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=[0]):
    i[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i[0],"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
def board(view):
    return json.loads(rpc("tools/call", {"name":"agora_board","arguments":{"view":view}})["result"]["content"][0]["text"])["board"]
w = board("waiting")
assert wd2 in next(iter(w.values())), w
a = board("all")
assert "waiting" in a and wd2 in a["waiting"], list(a)
p.stdin.close()
PYEOF

# --- 防御纵深：init 自举装 hook / .gitattributes / 裸提交拦截（独立仓库，不碰主测试仓） ---
H2="$T/agora2"
AGORA_HOME="$H2" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
test -x "$H2/.git/hooks/pre-commit" && ok "init 自举即装 pre-commit hook" || fail "init 自举即装 pre-commit hook"
grep -qxF 'scripts/sessions.map merge=union' "$H2/.gitattributes" \
  && grep -qxF 'wiki/allowed_signers merge=union' "$H2/.gitattributes" \
  && ok ".gitattributes 覆盖共享可变文本" || fail ".gitattributes 覆盖共享可变文本"
echo x >> "$H2/wiki/decisions/doctor-runbook.md"
cd "$H2" && git add -A >/dev/null
git -c user.name=t -c user.email=t@l commit -qm x >/dev/null 2>&1 \
  && fail "hook 拦截 wiki/ 裸提交" || ok "hook 拦截 wiki/ 裸提交"
AGORA_MECHANICAL=1 git -c user.name=t -c user.email=t@l commit -qm x >/dev/null 2>&1 \
  && ok "机械凭证放行" || fail "机械凭证放行"

# --- doctor 合并中断检查（MERGE_HEAD 残留） ---
git -C "$H2" rev-parse HEAD > "$H2/.git/MERGE_HEAD"
OUT=$(AGORA_HOME="$H2" bash "$H2/scripts/doctor.sh" 2>&1); RC=$?
[[ $RC -eq 1 ]] && echo "$OUT" | grep -q "合并中断" && ok "doctor 检出 MERGE_HEAD 残留" || fail "doctor 检出 MERGE_HEAD 残留"
OUT=$(AGORA_HOME="$H2" bash "$H2/scripts/doctor.sh" --fix 2>&1)
[[ ! -f "$H2/.git/MERGE_HEAD" ]] && echo "$OUT" | grep -q "ALL GREEN" \
  && ok "doctor --fix 恢复合并中断" || { fail "doctor --fix 恢复合并中断"; echo "$OUT"; }

# --- wiki-write 权限模型 ---
bash "$AGORA_HOME/scripts/wiki-write.sh" --actor rival@proj2 --path entities/tester.md --mode replace <<< "篡改" \
  2>/dev/null; [[ $? -eq 5 ]] && ok "wiki replace owner 不符被拒(rc=5)" || fail "wiki replace owner 不符被拒(rc=5)"
bash "$AGORA_HOME/scripts/wiki-write.sh" --actor tester@proj --path topics/roadmap.md --mode replace <<< "议题" >/dev/null \
  && ok "wiki 新建 topics 页" || fail "wiki 新建 topics 页"
bash "$AGORA_HOME/scripts/wiki-write.sh" --actor rival@proj2 --path topics/roadmap.md --mode append <<< "补充" >/dev/null \
  && grep -q '\*\*rival@proj2\*\*' "$AGORA_HOME/wiki/topics/roadmap.md" \
  && ok "topics append 放行（带署名）" || fail "topics append 放行（带署名）"
bash "$AGORA_HOME/scripts/wiki-write.sh" --actor rival@proj2 --path entities/rival.md --mode append <<< "x" \
  2>/dev/null; [[ $? -eq 2 ]] && ok "非 topics append 被拒(rc=2)" || fail "非 topics append 被拒(rc=2)"

# --- wiki_read 扩展名归一（无 .md 自动补，T6 人机学缝隙） ---
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "wiki_read 无 .md 路径归一可读（topics/delegation）" || fail "wiki_read 无 .md 路径归一可读（topics/delegation）"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = rpc("tools/call", {"name":"agora_wiki_read","arguments":{"path":"topics/delegation"}}, 2)
assert "与宿主准则的关系" in r["result"]["content"][0]["text"], r
r = rpc("tools/call", {"name":"agora_wiki_read","arguments":{"path":"topics/delegation.md"}}, 3)
assert "与宿主准则的关系" in r["result"]["content"][0]["text"], r
r = rpc("tools/call", {"name":"agora_wiki_read","arguments":{"path":"topics"}}, 4)
assert json.loads(r["result"]["content"][0]["text"]).get("code") == "VALIDATION_FAILED", r
r = rpc("tools/call", {"name":"agora_wiki_read","arguments":{"path":"../entities/tester"}}, 5)
assert json.loads(r["result"]["content"][0]["text"]).get("code") == "VALIDATION_FAILED", r
p.stdin.close()
PYEOF

# --- backup.sh ---
AGORA_BACKUP_DIR="$T/bak" bash "$AGORA_HOME/scripts/backup.sh" >/dev/null 2>&1
ls "$T/bak"/agora-*.bundle >/dev/null 2>&1 && ok "backup bundle 生成" || fail "backup bundle 生成"

# --- instructions 长路径预算（spec §5 <600 字） ---
LONG="$T/$(python3 -c 'print("deep/"*12)')agora"
mkdir -p "$(dirname "$LONG")"; ln -s "$AGORA_HOME" "$LONG"
cd "$PROJ" && AGORA_HOME="$LONG" python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "instructions 长路径仍 <600 字" || fail "instructions 长路径仍 <600 字"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
p.stdin.write(json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})+"\n"); p.stdin.flush()
r = json.loads(p.stdout.readline())
n = len(r["result"]["instructions"])
assert n < 600, n
p.stdin.close()
PYEOF

# --- instructions v1.24 断言：⑤跨仓条 + ⑥碰撞修复 + 预算（复用上方长路径夹具 LONG） ---
cd "$PROJ" && AGORA_HOME="$LONG" python3 - "$PKG/server/agora_mcp.py" "$T/ins.txt" <<'PYEOF'
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
p.stdin.write(json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})+"\n"); p.stdin.flush()
ins = json.loads(p.stdout.readline())["result"]["instructions"]
open(sys.argv[2], "w", encoding="utf-8").write(ins)
print(f"instructions 长路径渲染长度 = {len(ins)}（预算 <600）")
p.stdin.close()
PYEOF
LEN=$(python3 -c "import sys; print(len(open(sys.argv[1], encoding='utf-8').read()))" "$T/ins.txt" 2>/dev/null)
[ -n "$LEN" ] && [ "$LEN" -lt 600 ] && ok "instructions 长路径渲染 <600（实测 ${LEN} 字）" || fail "instructions 长路径渲染 <600（实测 ${LEN:-无} 字）"
grep -q "跨仓" "$T/ins.txt" && grep -q "实体页" "$T/ins.txt" && grep -q "topics/delegation" "$T/ins.txt" && grep -q "广场仓 docs/AGENTS.md" "$T/ins.txt" \
  && ok "instructions 含跨仓关键词（跨仓/实体页/topics/delegation/广场仓 docs/AGENTS.md）" || fail "instructions 含跨仓关键词（跨仓/实体页/topics/delegation/广场仓 docs/AGENTS.md）"
! grep -q "细节读 AGENTS.md" "$T/ins.txt" && ok "instructions 无旧碰撞文本「细节读 AGENTS.md」" || fail "instructions 无旧碰撞文本「细节读 AGENTS.md」"
cd "$PROJ" && AGORA_HOME="$LONG" python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "agora_dispatch 描述含「跨仓委托的标准路径」定位句" || fail "agora_dispatch 描述含「跨仓委托的标准路径」定位句"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
p.stdin.write(json.dumps({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})+"\n"); p.stdin.flush()
json.loads(p.stdout.readline())
p.stdin.write(json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})+"\n"); p.stdin.flush()
tools = json.loads(p.stdout.readline())["result"]["tools"]
d = next(t for t in tools if t["name"] == "agora_dispatch")["description"]
assert d.startswith("跨仓委托的标准路径："), d
p.stdin.close()
PYEOF

echo "===== owner 过滤（个人任务队列，v1.18） ====="
OUT=$(TITLE="我的活" TC);  MINE=$(echo "$OUT"  | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
OUT=$(TITLE="别人的活" TC); THEIRS=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
OUT=$(TITLE="我的受阻活" TC); MINEB=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST tester@proj --event claimed --task "$MINE" >/dev/null
POST rival@proj2 --event claimed --task "$THEIRS" >/dev/null
POST tester@proj --event claimed --task "$MINEB" >/dev/null
POST tester@proj --event blocked --task "$MINEB" --reason "等依赖" >/dev/null
grep -q "$MINEB — tester@proj" "$AGORA_HOME/board/blocked.md" \
  && ok "blocked 行渲染认领者" || fail "blocked 行渲染认领者"
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" "$MINE" "$THEIRS" "$MINEB" <<'PYEOF' && ok "owner 过滤（me/他人/组合）" || fail "owner 过滤（me/他人/组合）"
import json, subprocess, sys
srv, mine, theirs, mineb = sys.argv[1:5]
p = subprocess.Popen(["python3", srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=[0]):
    i[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i[0],"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
def board(**kw):
    return json.loads(rpc("tools/call", {"name":"agora_board","arguments":kw})["result"]["content"][0]["text"])["board"]
# owner=me（服务端裁决为 tester@proj）：见我不见他
me = board(view="in-progress", owner="me")["in-progress"]
assert mine in me and theirs not in me, me
# 指定他人：见他不见我
other = board(view="in-progress", owner="rival@proj2")["in-progress"]
assert theirs in other and mine not in other, other
# owner × view=all 组合：blocked 视图同样过滤
allv = board(view="all", owner="me")
assert mineb in allv["blocked"] and mine in allv["in-progress"] and theirs not in allv["in-progress"], allv
p.stdin.close()
PYEOF

echo "===== 审核回归（v1.26） ====="
# --- post.sh seq 前缀撞名：actor:pre@a 不得把 actor:pre@ab 计入自己的 seq ---
bash "$AGORA_HOME/scripts/post.sh" --actor "pre@a" --project pfxshard --event proposal --body "s1" >/dev/null
bash "$AGORA_HOME/scripts/post.sh" --actor "pre@ab" --project pfxshard --event proposal --body "s2" >/dev/null
OUT=$(bash "$AGORA_HOME/scripts/post.sh" --actor "pre@a" --project pfxshard --event proposal --body "s3")
echo "$OUT" | grep -q '"seq":2' \
  && ok "seq 前缀撞名防御（pre@a 不误数 pre@ab）" || fail "seq 前缀撞名防御（$OUT）"
# --- mention 越界：../ 逃逸被拒，inbox/ 外无残留 ---
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event proposal --body "x" --mention "../evil" 2>/dev/null
[[ $? -eq 2 ]] && ok "mention 路径逃逸被拒(rc=2)" || fail "mention 路径逃逸被拒"
[[ ! -e "$AGORA_HOME/evil" ]] && ok "mention 未逃逸出 inbox/" || fail "mention 逃逸出 inbox/"
# --- 邮件 ref 与 post stdout ref 一致且分片存在（午夜翻牌防线） ---
OUT=$(POST tester@proj --event proposal --body "ref一致性" --mention tester)
REF=$(echo "$OUT" | sed -n 's/.*"ref":"\([^"]*\)".*/\1/p')
MAIL=$(ls "$AGORA_HOME"/inbox/tester/*.md | sort | tail -1)
grep -qF "ref:$REF" "$MAIL" && test -f "$AGORA_HOME/${REF%:*}" \
  && ok "邮件 ref 与账本 ref 一致且分片存在" || fail "邮件 ref 一致性（ref=$REF mail=$MAIL）"
# --- cancelled 独立任务可见性：落 board/cancelled.md ---
OUT=$(TITLE="取消可见性" TC); CT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST tester@proj --event claimed --task "$CT" >/dev/null
POST tester@proj --event cancelled --task "$CT" --reason "撤销" >/dev/null
grep -q "^- $CT" "$AGORA_HOME/board/cancelled.md" 2>/dev/null \
  && ok "cancelled 独立任务落 board/cancelled.md" || fail "cancelled 独立任务落 board/cancelled.md"
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" "$CT" <<'PYEOF' && ok "MCP board：枚举+聚合 conflicts/cancelled" || fail "MCP board：枚举+聚合 conflicts/cancelled"
import json, subprocess, sys
srv, ct = sys.argv[1], sys.argv[2]
p = subprocess.Popen(["python3", srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=[0]):
    i[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i[0],"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
tools = rpc("tools/list")["result"]["tools"]
enum = next(t for t in tools if t["name"] == "agora_board")["inputSchema"]["properties"]["view"]["enum"]
assert "conflicts" in enum and "cancelled" in enum, enum
def board(**kw):
    return json.loads(rpc("tools/call", {"name":"agora_board","arguments":kw})["result"]["content"][0]["text"])["board"]
a = board(view="all")
assert "conflicts" in a and "cancelled" in a, list(a)
assert ct in a["cancelled"], a["cancelled"]
c = board(view="cancelled")
assert ct in next(iter(c.values())), c
p.stdin.close()
PYEOF
HPORT2=18472
AGORA_HOME="$AGORA_HOME" AGORA_HTTP_PORT=$HPORT2 python3 "$PKG/server/agora_http.py" >/dev/null 2>&1 &
HPID4=$!
sleep 1
python3 - "$HPORT2" <<'PYEOF' && ok "HTTP /api/board 含 conflicts/cancelled 视图" || fail "HTTP /api/board 含 conflicts/cancelled 视图"
import json, sys, urllib.request
d = json.load(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/api/board", timeout=8))
assert "conflicts" in d["views"] and "cancelled" in d["views"], list(d["views"])
assert "vs owner" in d["views"]["conflicts"], d["views"]["conflicts"][:120]
PYEOF
kill $HPID4 2>/dev/null || true
# --- reopen 后 cancelled.md 陈旧文件清除（派生确定性防线） ---
POST tester@proj --event reopened --task "$CT" --reason "恢复" >/dev/null
[[ ! -f "$AGORA_HOME/board/cancelled.md" ]] \
  && ok "reopen 后 cancelled.md 陈旧文件清除" || fail "reopen 后 cancelled.md 未清除"

echo "===== 审核回归二期（v1.27） ====="
# --- mention 字段完整性：| 与换行入环被拒（防幻影字段/账本行撕裂） ---
bash "$AGORA_HOME/scripts/post.sh" --actor probe@p27 --project p27 --event proposal --body pipe --mention 'a| task:gt-fake' 2>/dev/null
[[ $? -eq 2 ]] && ok "mention 含 | 被拒(rc=2)" || fail "mention 含 | 被拒"
! grep -rq "gt-fake" "$AGORA_HOME"/log/ && ok "幻影 task 字段未落账" || fail "幻影 task 字段未落账"
bash "$AGORA_HOME/scripts/post.sh" --actor probe@p27 --project p27 --event proposal --body nl --mention "$(printf 'x\ny')" 2>/dev/null
[[ $? -eq 2 ]] && ok "mention 含换行被拒(rc=2)" || fail "mention 含换行被拒"
# --- fail stderr 恒为合法 JSON（值内引号已转义） ---
bash "$AGORA_HOME/scripts/post.sh" --actor probe@p27 --project p27 --event proposal --body esc --mention '../q"b\x' 2>"$T/fail27.json"; RC27=$?
[[ $RC27 -eq 2 ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["code"]=="VALIDATION_FAILED"' "$T/fail27.json" \
  && ok "fail stderr 为合法 JSON（引号转义）" || fail "fail stderr 为合法 JSON（rc=$RC27）"
# --- dispatcher 双侧防线：写入侧拒坏名；预置毒页后 done 读取侧兜底拒 ---
OUT=$(TITLE="派发逃逸任务" VERIFY="true" PROJECT_DIR="$PROJ" TC); DT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
[[ "$DT" =~ ^gt-[0-9a-f]+$ ]] && ok "派发逃逸任务就绪（DT=$DT）" || fail "派发逃逸任务就绪（$OUT）"
bash "$AGORA_HOME/scripts/post.sh" --actor '../x@proj' --project proj --event dispatched --task "$DT" --target "$PROJ" 2>/dev/null
[[ $? -eq 2 ]] && ! grep -q '^dispatcher:' "$AGORA_HOME/wiki/tasks/$DT.md" \
  && ok "坏名 dispatcher 写入侧被拒(rc=2)" || fail "坏名 dispatcher 写入侧被拒"
sed -i "1a dispatcher: ../evil9" "$AGORA_HOME/wiki/tasks/$DT.md"
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event done --task "$DT" --commit HEAD --evidence 指针 2>/dev/null
[[ $? -eq 2 ]] && [[ ! -e "$AGORA_HOME/evil9" ]] \
  && ok "毒 dispatcher 读取侧兜底拒（无逃逸）" || fail "毒 dispatcher 读取侧兜底"
# --- SEQ 双侧定界：跨 actor body 注入不再虚高 ---
OUT=$(bash "$AGORA_HOME/scripts/post.sh" --actor spoof9@q --project p27b --event proposal --body "embed actor:t9@p tail")
echo "$OUT" | grep -q '"seq":1,' && ok "投毒事件落账就绪" || fail "投毒事件落账就绪（$OUT）"
OUT=$(bash "$AGORA_HOME/scripts/post.sh" --actor t9@p --project p27b --event proposal --body first)
echo "$OUT" | grep -q '"seq":1,' \
  && ok "SEQ 双侧定界（跨 actor body 注入不虚高）" || fail "SEQ 双侧定界（$OUT）"
# --- 相对路径调用：scripts 目录内 bash history.sh 不再 ModuleNotFoundError ---
OUT=$(cd "$AGORA_HOME/scripts" && TASK=gt-none9 bash history.sh 2>&1)
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]==0, d' \
  && ok "scripts 目录内相对调用 history.sh 出合法 JSON" || fail "相对调用 history.sh（$OUT）"
# --- MCP view 服务端白名单：越枚举 view 被拒（防任意 .md 读） ---
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "MCP view 白名单（越枚举拒）" || fail "MCP view 白名单"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=[0]):
    i[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i[0],"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = rpc("tools/call", {"name":"agora_board","arguments":{"view":"../CONVENTIONS"}})
d = json.loads(r["result"]["content"][0]["text"])
assert r["result"].get("isError") and d.get("code")=="VALIDATION_FAILED", r
p.stdin.close()
PYEOF
# --- HTTP /api/inbox 拒 name=..（400） ---
HPORT3=18473
AGORA_HOME="$AGORA_HOME" AGORA_HTTP_PORT=$HPORT3 python3 "$PKG/server/agora_http.py" >/dev/null 2>&1 &
HPID5=$!
for i in 1 2 3 4 5 6 7 8 9 10; do bash -c "exec 3<>/dev/tcp/127.0.0.1/$HPORT3" 2>/dev/null && break; sleep 0.3; done
python3 - "$HPORT3" <<'PYEOF' && ok "HTTP /api/inbox 拒 name=..（400）" || fail "HTTP /api/inbox 拒 name=.."
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/api/inbox?name=..", timeout=8)
    raise SystemExit(1)
except urllib.error.HTTPError as e:
    assert e.code == 400, e.code
PYEOF
kill $HPID5 2>/dev/null || true
# --- ACTOR/PROJECT 账本行完整性 ---
bash "$AGORA_HOME/scripts/post.sh" --actor 'a|b@p' --project p27 --event proposal --body x 2>/dev/null
[[ $? -eq 2 ]] && ok "actor 含 | 被拒（账本行完整性）" || fail "actor 含 | 被拒"
# --- idem 注入：换行伪造整行事件（\S+ 槽完整性收口） ---
bash "$AGORA_HOME/scripts/post.sh" --actor probe@p27 --project p27 --event proposal --body idemnl --idem "$(printf 'x\n- seq:1 | ts:t | actor:victim@evil | event:claimed | idem:y | seen:e@1 | task:gt-fake2')" 2>/dev/null
[[ $? -eq 2 ]] && ok "idem 含换行被拒(rc=2)" || fail "idem 含换行被拒"
! grep -rq "victim@evil" "$AGORA_HOME"/log/ && ok "伪造事件行未落账" || fail "伪造事件行未落账"
# --- PROJECT 路径成分：shard 文件名完整性 ---
bash "$AGORA_HOME/scripts/post.sh" --actor probe@p27 --project '../wiki/tasks/gt-fakep' --event proposal --body pt 2>/dev/null
[[ $? -eq 2 ]] && ok "project 含 / 与 .. 被拒(rc=2)" || fail "project 含 / 与 .. 被拒"
# --- dispatched 坏名：fail=零写入契约（守卫前移后账本零残留） ---
bash "$AGORA_HOME/scripts/post.sh" --actor '../x@proj' --project p27d --event dispatched --task "$DT" --target "$PROJ" 2>/dev/null
[[ $? -eq 2 ]] && [[ ! -f "$AGORA_HOME/log/$(date +%F)/p27d.md" ]] \
  && ok "dispatched 坏名拒且零写入" || fail "dispatched 坏名拒且零写入"
# --- fail() 统一 python-JSON：错误通道恒合法（含引号嵌值） ---
bash "$AGORA_HOME/scripts/post.sh" "--bad'q\"x" 2>"$T/fail28.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["code"]=="VALIDATION_FAILED"' "$T/fail28.json" \
  && ok "post unknown-arg stderr 为合法 JSON" || fail "post unknown-arg stderr 为合法 JSON"
ACTOR=tester@proj TASK="$A" FILES='q"b.txt' PROJECT_DIR="$PROJ" bash "$AGORA_HOME/scripts/attach.sh" 2>"$T/att28.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["error"]=="FILE_NOT_FOUND"' "$T/att28.json" \
  && ok "attach 缺文件 stderr 为合法 JSON" || fail "attach 缺文件 stderr 为合法 JSON"



echo "===== 跨仓委托协议播种 ====="
# ① 隔离 AGORA_HOME 跑 init → wiki/topics/delegation.md 存在且含「与宿主准则的关系」
H3=$(mktemp -d)
AGORA_HOME="$H3/agora" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
test -f "$H3/agora/wiki/topics/delegation.md" && grep -q "与宿主准则的关系" "$H3/agora/wiki/topics/delegation.md" \
  && ok "init 播种 delegation.md（含与宿主准则的关系）" || fail "init 播种 delegation.md（含与宿主准则的关系）"
# ② 再跑一次 init → 文件字节不变（only-if-missing 幂等）
cp "$H3/agora/wiki/topics/delegation.md" "$H3/delegation.before"
AGORA_HOME="$H3/agora" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
diff -q "$H3/delegation.before" "$H3/agora/wiki/topics/delegation.md" >/dev/null \
  && ok "init 重复执行不覆盖 delegation.md（幂等）" || fail "init 重复执行不覆盖 delegation.md（幂等）"
rm -rf "$H3"
# ③ 论坛 docs/AGENTS.md 含跨仓委托指路行
grep -q "跨仓委托" "$PKG/docs/AGENTS.md" && ok "论坛 AGENTS.md 含跨仓委托指路行" || fail "论坛 AGENTS.md 含跨仓委托指路行"

echo "===== 跨仓委托链（stub runtime 全链路账本断言） ====="
# 隔离临时论坛 + 双项目双实体：派单方 orch@orch（can_spawn:true）→ 目标项目 target（名册解析子身份 worker@target）
H4=$(mktemp -d); AH4="$H4/agora"
AGORA_HOME="$AH4" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
ORCH="$H4/orch"; mkdir -p "$ORCH"
TARGET="$H4/target"; mkdir -p "$TARGET"; cd "$TARGET" && git init -q . && echo FIXED > app.txt \
  && git add -A && git -c user.name=t -c user.email=t@local commit -qm init
mkdir -p "$AH4/wiki/entities"
printf -- '---\nname: orch\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$ORCH" > "$AH4/wiki/entities/orch.md"
printf -- '---\nname: worker\ndirs:\n  - %s\ncan_spawn: false\n---\n' "$TARGET" > "$AH4/wiki/entities/worker.md"
(cd "$AH4" && git add -A && AGORA_MECHANICAL=1 git commit -qm entities >/dev/null)
# task-create 指向目标项目：verify 门将由机械层在该目录真实执行（目标项目已预置 FIXED）
OUT=$(TITLE="跨仓交付任务" VERIFY="grep -q FIXED app.txt" PROJECT_DIR="$TARGET" AGORA_HOME="$AH4" bash "$AH4/scripts/task-create.sh")
XT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
# ① stub 拉起（AGORA_RUNTIME=echo）：mode=spawned，子身份按名册目录前缀解析
OUT=$(AGORA_RUNTIME=echo AGORA_HOME="$AH4" bash "$AH4/scripts/dispatch.sh" --actor orch@orch --project "$TARGET" --task "$XT" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' && ok "dispatch stub 返回 mode:spawned" || fail "dispatch stub 返回 mode:spawned（$OUT）"
echo "$OUT" | grep -q '"child_actor":"worker@target"' && ok "dispatch 名册解析子身份 worker@target" || fail "dispatch 名册解析子身份 worker@target（$OUT）"
# ② 子会话照协议回报：claimed → done（verify 门真实执行 grep -q FIXED app.txt）
AGORA_HOME="$AH4" bash "$AH4/scripts/post.sh" --actor worker@target --project target --event claimed --task "$XT" >/dev/null
AGORA_HOME="$AH4" bash "$AH4/scripts/post.sh" --actor worker@target --project target --event done --task "$XT" --commit HEAD --evidence "通过" >/dev/null \
  && ok "子会话 done 通过 verify 门" || fail "子会话 done 通过 verify 门"
# ③ 账本断言：事件序列 / done 自动 @派单方 / 全链无 verify_failed / 任务页 dispatcher 标注（规格 §4.7 第 7 条）
H=$(TASK="$XT" AGORA_HOME="$AH4" bash "$AH4/scripts/history.sh")
echo "$H" | python3 -c "
import json,sys
evs=[e['event'] for e in json.load(sys.stdin)['events']]
assert evs==['dispatched','claimed','done'], evs
" && ok "委托链事件序列 dispatched→claimed→done" || fail "委托链事件序列异常（非 dispatched→claimed→done）"
echo "$H" | python3 -c "
import json,sys
done=[e for e in json.load(sys.stdin)['events'] if e['event']=='done'][0]
assert 'orch' in done.get('mention',''), done.get('mention')
" && ok "done 事件自动 @派单方（mention 含 orch）" || fail "done 事件 mention 未含派单方 orch"
! grep -q "event:verify_failed" "$AH4"/log/*/*.md && ok "全链无 verify_failed" || fail "全链无 verify_failed"
grep -q '^dispatcher: orch' "$AH4/wiki/tasks/$XT.md" && ok "任务页 frontmatter 标注 dispatcher:orch" || fail "任务页 frontmatter 缺 dispatcher:orch"
# ④ 尾引号标量类 verify 回归：verify 值语义含尾部双引号（旧 s/"$// 剥离致 bash -c 不闭合引号，此验证类永不可过门）
echo ANS > "$TARGET/f.txt"
OUT=$(TITLE="尾引号verify任务" VERIFY='test "$(cat f.txt)" = "ANS"' PROJECT_DIR="$TARGET" AGORA_HOME="$AH4" bash "$AH4/scripts/task-create.sh")
XT2=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
AGORA_HOME="$AH4" bash "$AH4/scripts/post.sh" --actor worker@target --project target --event claimed --task "$XT2" >/dev/null
AGORA_HOME="$AH4" bash "$AH4/scripts/post.sh" --actor worker@target --project target --event done --task "$XT2" --commit HEAD --evidence "通过" >/dev/null
TASK="$XT2" AGORA_HOME="$AH4" bash "$AH4/scripts/history.sh" | python3 -c "
import json,sys
evs=[e['event'] for e in json.load(sys.stdin)['events']]
assert evs==['claimed','done'], evs
" && ok "尾引号标量 verify 类 done 过门（成对剥离后原样透传）" || fail "尾引号标量 verify 类 done 未过门（verify_failed）"
# ⑤ history.sh 免导出 AGORA_HOME：shell 直调方（无 server env）不再 KeyError
env -u AGORA_HOME HOME="$H4" TASK="$XT" bash "$AH4/scripts/history.sh" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['count']>0, d" \
  && ok "history.sh 未导出 AGORA_HOME 仍出合法 JSON（默认导出）" || fail "history.sh 未导出 AGORA_HOME 时 KeyError"
# ⑥ 同任务双派生双审计行：dispatch_id 纳秒哈希天然唯一 → run 不同 → dispatched idem 不同（重派/reopened 链路审计行不被连续窗口吞）
AGORA_RUNTIME=echo AGORA_HOME="$AH4" bash "$AH4/scripts/dispatch.sh" --actor orch@orch --project "$TARGET" --task "$XT" >/dev/null 2>&1
N=$(cat "$AH4"/log/*/*.md 2>/dev/null | grep -F "task:$XT" | grep -c "event:dispatched")
[ "$N" -eq 2 ] && ok "同任务二次派生 dispatched 审计行落账（基线 1 + 新增 1）" || fail "同任务二次派生 dispatched 行被吞（共 $N 条，期望 2）"
# ⑦ dedup 旗标透传：dispatch 响应 JSON 含裸布尔 dedup 键（正常落账路径 = false）
OUT=$(AGORA_RUNTIME=echo AGORA_HOME="$AH4" bash "$AH4/scripts/dispatch.sh" --actor orch@orch --project "$TARGET" --task "$XT")
echo "$OUT" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
assert d.get('dedup') is False, d
" && ok "dispatch 响应 JSON 含 dedup:false（裸布尔）" || fail "dispatch 响应 JSON 缺 dedup:false（$OUT）"

rm -rf "$H4"

echo
echo "===== 结果: $PASS 通过, $FAIL 失败 ====="
rm -rf "$T"
[ "$FAIL" -eq 0 ]
