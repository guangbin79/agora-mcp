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
cd "$AGORA_HOME" && git add -A && git commit -qm "entities"

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
cd "$AGORA_HOME" && git add -A >/dev/null && git commit -qm "ghost entity"
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
# stalled 看门狗：CRIT_MIN=0 → in-progress 任务立即超时
AGORA_POLL_CRIT_MIN=0 AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md 2>/dev/null | grep "event:diagnosed" | grep -q "stalled" \
  && ok "stalled 看门狗派生 diagnosed" || fail "stalled 看门狗派生 diagnosed"
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

echo "===== doctor ====="
OUT=$(bash "$AGORA_HOME/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "ALL GREEN" && ok "doctor 全绿" || { fail "doctor 全绿"; echo "$OUT"; }

echo
echo "===== 结果: $PASS 通过, $FAIL 失败 ====="
rm -rf "$T"
[ "$FAIL" -eq 0 ]
