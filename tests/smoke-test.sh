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
# 可自动注册目录：写工具直接可用且机械建页（2026-10-20 注册去人工闸）；不可注册目录（$HOME）仍拒
cd "$T" && python3 - "$PKG/server/agora_mcp.py" "$AGORA_HOME" <<'PYEOF' && ok "未注册目录自动注册后可写" || fail "未注册目录自动注册后可写"
import json, subprocess, sys, os
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = rpc("tools/call", {"name":"agora_task_create","arguments":{"title":"x"}}, 2)
txt = json.loads(r["result"]["content"][0]["text"])
assert txt.get("code") != "NOT_REGISTERED" and txt.get("task","").startswith("gt-"), txt
home = sys.argv[2]
page = os.path.join(home, "wiki", "entities", os.path.basename(os.getcwd()) + ".md")
assert os.path.isfile(page) and "can_spawn: true" in open(page).read(), page
p.stdin.close()
PYEOF
cd "$HOME" && python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "不可注册目录（\$HOME）写仍被拒" || fail "不可注册目录（\$HOME）写仍被拒"
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
# 随机端口（0→.git/httpd.json 发现）：固定端口在并发套件/残留 httpd 时 bind 撞车假红（gt-d154 merge verify 实证）
AGORA_HOME="$AGORA_HOME" AGORA_HTTP_PORT=0 python3 "$PKG/server/agora_http.py" >/dev/null 2>&1 &
HPID=$!
sleep 1
HPORT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["port"])' "$AGORA_HOME/.git/httpd.json" 2>/dev/null)
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
# 拉起形态：runtime 参数含 --auto（无人值守权限），且不含已随 opencode 2.0.32 移除的 --dir（echo stub 把参数回显进 dispatch 日志）
AGORA_RUNTIME=echo bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" \
  --task "$POLLT" >/dev/null 2>&1
sleep 1
RLOG=$(ls -t "$AGORA_HOME"/raw/dispatches/*.log | head -1)
grep -q -- '--auto' "$RLOG" && ! grep -q -- '--dir' "$RLOG" \
  && ok "dispatch 拉起参数含 --auto 且无 --dir" || fail "dispatch 拉起参数异常（$RLOG）"

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

echo "===== poll 每日督报（跨日闸门，gt-abcd） ====="
YDAY=$(date -d yesterday +%F)
mkdir -p "$AGORA_HOME/log/$YDAY" "$AGORA_HOME/raw/dispatches"
printf 'started\nEXIT:1=9\n' > "$AGORA_HOME/raw/dispatches/d-ok1.log"   # 非空＝活着
: > "$AGORA_HOME/raw/dispatches/d-empty.log"                            # 空＝秒死
SL="$AGORA_HOME/log/$YDAY/proj.md"; : > "$SL"
EV() { echo "- seq:$1 | ts:$2 | actor:$3 | event:$4 | idem:i$1 | seen:t@1 | task:$5 | $6" >> "$SL"; }
W="watchdog@$(hostname)"
EV 1 "$YDAY""T12:00:01+08:00" "$W" diagnosed gt-aaaa "conclusion:stalled: 任务 gt-aaaa 已 99min 无新事件落账（阈值 40min）"
EV 2 "$YDAY""T12:00:02+08:00" "$W" diagnosed gt-bbbb "conclusion:stalled: 任务 gt-bbbb 已 99min 无新事件落账（阈值 40min）"
EV 3 "$YDAY""T12:00:03+08:00" "$W" escalated gt-cccc "conclusion:stalled 升级：任务 gt-cccc 连续 3 次诊断无响应"
EV 4 "$YDAY""T12:00:04+08:00" "$W" diagnosed gt-dddd "conclusion:done 未合并：gt-dddd 已 done 且超 15min 无 merged（第 1/3 次提醒）"
EV 1 "$YDAY""T12:00:05+08:00" "tester@proj" done gt-dead "commit:abc1234 | evidence:ok"
EV 2 "$YDAY""T12:00:06+08:00" "tester@proj" done gt-dddd "commit:abc1235 | evidence:ok"
EV 1 "$YDAY""T12:00:07+08:00" "agora-mcp@proj" merged gt-dead "commit:abc1234"
EV 2 "$YDAY""T12:00:08+08:00" "agora-mcp@proj" dispatched gt-aaaa "target:/tmp/proj | child:tester | run:raw/dispatches/d-ok1.log"
EV 3 "$YDAY""T12:00:09+08:00" "agora-mcp@proj" dispatched gt-bbbb "target:/tmp/proj | child:tester | run:raw/dispatches/d-ok1.log | dispatcher_task:gt-aaaa"
EV 4 "$YDAY""T12:00:10+08:00" "agora-mcp@proj" dispatched gt-eeee "target:/tmp/proj | child:tester | run:raw/dispatches/d-gone.log"
EV 5 "$YDAY""T12:00:11+08:00" "agora-mcp@proj" dispatched gt-ffff "target:/tmp/proj | child:tester | run:raw/dispatches/d-empty.log"
# 终态收口：不占 dispatch 配额（活跃＝dispatched∩无终态），不挂看板 in-progress
EV 6 "$YDAY""T12:00:12+08:00" "agora-mcp@proj" cancelled gt-aaaa "reason:督报夹具收口"
EV 7 "$YDAY""T12:00:13+08:00" "agora-mcp@proj" cancelled gt-bbbb "reason:督报夹具收口"
EV 8 "$YDAY""T12:00:14+08:00" "agora-mcp@proj" cancelled gt-eeee "reason:督报夹具收口"
EV 9 "$YDAY""T12:00:15+08:00" "agora-mcp@proj" cancelled gt-ffff "reason:督报夹具收口"
GATE_RESET() { python3 - "$AGORA_HOME" <<'PYEOF'
import json, sys
f = sys.argv[1] + "/.git/poll-state.json"
s = json.load(open(f)); s["last_supervise_date"] = "2000-01-01"
json.dump(s, open(f, "w"))
PYEOF
}
# 首次生成：清页＋清闸 → poll → owner=watchdog ＋ 昨日 section 全量统计
rm -f "$AGORA_HOME/wiki/topics/supervision.md"; GATE_RESET
SUP_OUT=$(AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh")
SUP="$AGORA_HOME/wiki/topics/supervision.md"
grep -q "\"supervised\": \"$YDAY\"" <<<"$SUP_OUT" && ok "督报跨日闸门首触发" || fail "督报跨日闸门首触发（$SUP_OUT）"
grep -q "^owner: watchdog" "$SUP" && ok "督报页首建 owner=watchdog" || fail "督报页首建 owner=watchdog"
grep -q "^## $YDAY" "$SUP" \
  && grep -q "孤儿 1｜秒死 1｜心跳超时 2｜恢复性重派 1｜escalated 1" "$SUP" \
  && grep -q "1/2（50%" "$SUP" \
  && grep -q "proj 心跳超时 ×2" "$SUP" \
  && grep -q "L1×3 L2×1" "$SUP" \
  && ok "督报统计（分类/闭环率/复发点名/深度分布）" || fail "督报统计断言（$(head -12 "$SUP")）"
# 同日不重复：再跑不触发、页字节不变、闸门=今日
C1=$(md5sum "$SUP" | cut -d' ' -f1)
SUP2=$(AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh")
C2=$(md5sum "$SUP" | cut -d' ' -f1)
python3 - "$AGORA_HOME" <<'PYEOF' && GATE_OK=1 || GATE_OK=0
import json, sys, datetime
s = json.load(open(sys.argv[1] + "/.git/poll-state.json"))
sys.exit(0 if s.get("last_supervise_date") == datetime.date.today().isoformat() else 1)
PYEOF
[[ "$C1" == "$C2" ]] && ! grep -q "supervised" <<<"$SUP2" && [[ "${GATE_OK:-0}" -eq 1 ]] \
  && ok "同日不重复触发（页字节不变＋闸门翻今日）" || fail "同日幂等（C1=$C1 C2=$C2 GATE_OK=${GATE_OK:-0}）"
# 他人写被 owner 拒
bash "$AGORA_HOME/scripts/wiki-write.sh" --actor rival@proj2 --path topics/supervision.md --mode replace </dev/null 2>/dev/null
[[ $? -eq 5 ]] && ok "督报页他人写被 owner 拒(rc=5)" || fail "督报页他人写被 owner 拒"
# 跨日翻新＋7 天有界：预置 7 个旧段 → 回拨闸门 → 触发后恰 7 段、昨日段置顶、最老出局
OLD=""
for i in 2 3 4 5 6 7 8; do
  D=$(date -d "-$i day" +%F)
  OLD="$OLD
## $D

- 旧段 D-$i 标记
"
done
printf -- '---\nowner: watchdog\ncreated: %s\n---\n%s' "$(date +%F)" "$OLD" | bash "$AGORA_HOME/scripts/wiki-write.sh" --actor watchdog@$(hostname) --path topics/supervision.md --mode replace >/dev/null
GATE_RESET
AGORA_RUNTIME=true bash "$AGORA_HOME/scripts/poll.sh" >/dev/null
grep -q "旧段 D-8 标记" "$SUP" && fail "7 天有界：最老段 D-8 未出局" || ok "7 天有界截断：最老段出局"
grep -q "旧段 D-2 标记" "$SUP" && ok "跨日翻新：次新旧段保留" || fail "跨日翻新：旧段 D-2 丢失"
[[ $(grep -c '^## ' "$SUP") -eq 7 ]] && ok "督报页恰 7 段" || fail "督报页段数 $(grep -c '^## ' "$SUP")≠7"
[[ "$(grep -m1 '^## ' "$SUP")" == "## $YDAY" ]] && ok "跨日翻新：昨日段置顶" || fail "跨日翻新：置顶段=$(grep -m1 '^## ' "$SUP")"

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
bash "$AGORA_HOME/scripts/wiki-write.sh" --actor tester@proj --path projects/regress --mode replace <<< "desc" >/dev/null \
  && test -f "$AGORA_HOME/wiki/projects/regress.md" \
  && ok "wiki_write 无后缀路径归一落盘 .md（与读侧同口径）" || fail "wiki_write 无后缀路径归一落盘 .md（与读侧同口径）"

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
HPORT2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));p=s.getsockname()[1];s.close();print(p)')
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
HPORT3=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));p=s.getsockname()[1];s.close();print(p)')
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

# ⑧ gt-eefd 子会话身份兜底：server cwd=派单方目录（模拟共享 MCP 进程 env 继承），
#   仅 env 携带 dispatch 上下文 → post 不带 actor 落账 child_actor（账本 dispatched 记录的 child,
#   权威于派发时点）；显式 actor 恒优先；无 env 对照组照旧进程级 ACTOR（兜底不越权）
OUT=$(TITLE="身份兜底任务" VERIFY="true" PROJECT_DIR="$TARGET" AGORA_HOME="$AH4" bash "$AH4/scripts/task-create.sh")
XG=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
AGORA_HOME="$AH4" bash "$AH4/scripts/post.sh" --actor orch@orch --project target --event dispatched --task "$XG" \
  --target "$TARGET" --child legacy --run "raw/dispatches/d-eefdregress.log" >/dev/null
touch "$AH4/raw/dispatches/d-eefdregress.log.live"   # dispatch.sh 真实形状：$LOG.live（B1 回归）
# child=legacy ≠ 名册现裁决(worker@target)：断言只认账本反查路径——现裁决兜底(旧代码 B1 退化形态)在此必红
cd "$ORCH" && AGORA_HOME="$AH4" python3 - "$PKG/server/agora_mcp.py" "$AH4" "$TARGET" "$XG" <<'PYEOF' && ok "child_actor 兜底：子会话 post 不带 actor 归 child（gt-eefd）" || fail "child_actor 兜底（gt-eefd）"
import json, subprocess, sys, os
srv, home, target, xg = sys.argv[1:5]
def spawn(dispatch_env):
    env = {**os.environ, "AGORA_HOME": home, **dispatch_env}
    p = subprocess.Popen(["python3", srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    def rpc(m, ps=None, i=[0]):
        i[0] += 1
        p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i[0],"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
        return json.loads(p.stdout.readline())
    rpc("initialize", {})
    return p, rpc
def call(rpc, args):
    return json.loads(rpc("tools/call", {"name":"agora_post","arguments":args})["result"]["content"][0]["text"])
def actor_of(shard, xg, event):
    for line in open(f"{home}/{shard}", encoding="utf-8"):
        if f"task:{xg}" in line and f"event:{event}" in line:
            for f in line.split("|"):
                f = f.strip()
                if f.startswith("actor:"): return f[6:]
    return None
# 兜底组：cwd 裁决为 orch@orch（dispatcher），env 携带子会话上下文 → 不带 actor 应归 child_actor
p1, r1 = spawn({"AGORA_LIVEF": f"{home}/raw/dispatches/d-eefdregress.log.live", "AGORA_PDIR": target})
res = call(r1, {"event":"claimed","task":xg})
assert res.get("shard","").endswith("/target.md"), res
assert actor_of(res["shard"], xg, "claimed") == "legacy@target", open(f"{home}/{res['shard']}", encoding="utf-8").read()
# 显式 actor 恒优先（env 在场也不覆盖）
res = call(r1, {"event":"progress","task":xg,"body":"显式","actor":"worker@target"})
assert actor_of(res["shard"], xg, "progress") == "worker@target", res
p1.stdin.close()
# 对照组：无 dispatch env → 照旧进程级 ACTOR（cwd 裁决 orch@orch），行为不变
p2, r2 = spawn({})
res = call(r2, {"event":"blocked","task":xg,"reason":"对照"})
assert res.get("shard","").endswith("/orch.md"), res
assert actor_of(res["shard"], xg, "blocked") == "orch@orch", res
p2.stdin.close()
PYEOF
rm -f "$AH4/raw/dispatches/d-eefdregress.log.live"

rm -rf "$H4"

echo "===== dispatch worktree 感知（独立论坛：名册仅主 repo 实体） ====="
# worktree 路径派发归一到主 repo 实体 + project 取主 repo 名；陌生目录（非 worktree）仍拒（gt-ac14）
H5=$(mktemp -d); AH5="$H5/agora"
AGORA_HOME="$AH5" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
R5="$H5/repo"; mkdir -p "$R5"; cd "$R5" && git init -q . && echo FIXED > app.txt \
  && git add -A && git -c user.name=t -c user.email=t@local commit -qm init
W5="$H5/repo__wt-test__10212359"; git -C "$R5" worktree add -q "$W5" 2>/dev/null
mkdir -p "$AH5/wiki/entities"
printf -- '---\nname: tester\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$R5" > "$AH5/wiki/entities/tester.md"
(cd "$AH5" && git add -A && AGORA_MECHANICAL=1 git commit -qm entities >/dev/null)
OUT=$(TITLE="worktree 任务" VERIFY="true" PROJECT_DIR="$W5" AGORA_HOME="$AH5" bash "$AH5/scripts/task-create.sh")
XW=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
rm -f "$AH5"/raw/dispatches/*.live
OUT=$(AGORA_RUNTIME=true AGORA_HOME="$AH5" bash "$AH5/scripts/dispatch.sh" --actor tester@repo --project "$W5" --task "$XW" 2>&1)
echo "$OUT" | grep -q '"child_actor":"tester@repo"' && ok "worktree 路径派发归属主 repo 实体（project=repo）" || fail "worktree 路径派发（$OUT）"
rm -f "$AH5"/raw/dispatches/*.live
OUT=$(AGORA_RUNTIME=true AGORA_HOME="$AH5" bash "$AH5/scripts/dispatch.sh" --actor tester@repo --project "$H5/no-such-repo" --task "$XW" 2>&1)
echo "$OUT" | grep -q NOT_REGISTERED && ok "陌生目录（非 worktree）仍拒派发" || fail "陌生目录应拒（$OUT）"
# server 侧：worktree cwd 身份裁决归属主实体、写路径可用、不误注册 worktree 实体页（gt-ac14）
cd "$W5" && python3 - "$PKG/server/agora_mcp.py" "$AH5" <<'PYEOF' && ok "worktree cwd 身份裁决归属主实体（who.you=tester@repo）" || fail "worktree cwd 身份裁决异常"
import json, subprocess, sys, os
p = subprocess.Popen(["python3", sys.argv[1]], env={**os.environ, "AGORA_HOME": sys.argv[2]},
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = json.loads(rpc("tools/call", {"name":"agora_who","arguments":{}}, 2)["result"]["content"][0]["text"])
assert r.get("you") == "tester@repo", r.get("you")
assert [x for x in r.get("roster",[]) if x["name"]=="tester"][0]["here"] is True, r.get("roster")
r = json.loads(rpc("tools/call", {"name":"agora_task_create","arguments":{"title":"wt 自干"}}, 3)["result"]["content"][0]["text"])
assert r.get("task","").startswith("gt-"), r
p.stdin.close()
PYEOF
! ls "$AH5"/wiki/entities/repo__wt-*.md >/dev/null 2>&1 && ok "worktree cwd 不自动注册实体页" || fail "worktree cwd 被误注册实体页"
# worktree 子目录：归一向上爬到主 repo（终闸 HIGH 回归，gt-ac14）
mkdir -p "$W5/src"
rm -f "$AH5"/raw/dispatches/*.live
OUT=$(AGORA_RUNTIME=true AGORA_HOME="$AH5" bash "$AH5/scripts/dispatch.sh" --actor tester@repo --project "$W5/src" --task "$XW" 2>&1)
echo "$OUT" | grep -q '"child_actor":"tester@repo"' && ok "worktree 子目录派发归属主 repo 实体" || fail "worktree 子目录派发（$OUT）"
cd "$W5/src" && python3 - "$PKG/server/agora_mcp.py" "$AH5" "$XW" <<'PYEOF' && ok "worktree 子目录身份裁决归属主实体" || fail "worktree 子目录身份裁决异常"
import json, subprocess, sys, os
p = subprocess.Popen(["python3", sys.argv[1]], env={**os.environ, "AGORA_HOME": sys.argv[2]},
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = json.loads(rpc("tools/call", {"name":"agora_who","arguments":{}}, 2)["result"]["content"][0]["text"])
assert r.get("you") == "tester@repo", r.get("you")
r = json.loads(rpc("tools/call", {"name":"agora_post","arguments":{"event":"plan","task":sys.argv[3],"body":"子目录实施计划"}}, 3)["result"]["content"][0]["text"])
assert r.get("shard","").endswith("/repo.md"), r   # plan 落账 + project 归一主 repo 名（v1.30）
p.stdin.close()
PYEOF
ls "$AH5"/wiki/entities/ | grep -q "^src\.md$" && fail "子目录 cwd 误注册 src 实体页" || ok "子目录 cwd 不误注册实体页"
# 匿名 fallback：未注册主 repo 的 worktree cwd，proposal 落账归一主 repo 名（v1.30 ① fallback 分支）
R6="$H5/repo2"; mkdir -p "$R6"; cd "$R6" && git init -q . && git -c user.name=t -c user.email=t@local commit -q --allow-empty -m i
W6="$H5/repo2__wt-anon__10213000"; git -C "$R6" worktree add -q "$W6" 2>/dev/null
cd "$W6" && python3 - "$PKG/server/agora_mcp.py" "$AH5" <<'PYEOF' && ok "匿名 worktree cwd 的 proposal 落账归一主 repo 名" || fail "匿名 proposal shard 未归一"
import json, subprocess, sys, os
p = subprocess.Popen(["python3", sys.argv[1]], env={**os.environ, "AGORA_HOME": sys.argv[2]},
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = json.loads(rpc("tools/call", {"name":"agora_post","arguments":{"event":"proposal","body":"匿名自报"}}, 2)["result"]["content"][0]["text"])
assert r.get("shard","").endswith("/repo2.md"), r   # fallback：非 worktree basename
p.stdin.close()
PYEOF
rm -rf "$H5"

# --- post.sh 读取侧三件 + board 心跳 age（gt-4ea1 F/E）---
# 坏名（含反斜杠）dispatcher 拒 done + fail 零写入（全新 project 无 shard 残留）
TF=$(TITLE="毒dispatcher任务" VERIFY="true" PROJECT_DIR="$PROJ" TC | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
printf 'dispatcher: bo\\ss\n' >> "$AGORA_HOME/wiki/tasks/$TF.md"
OUT=$(bash "$AGORA_HOME/scripts/post.sh" --actor tester@projx --project projx --event done --task "$TF" --commit HEAD --evidence x 2>&1)
echo "$OUT" | grep -q VALIDATION_FAILED && ok "读取侧 dispatcher 坏名（含反斜杠）拒 done" || fail "读取侧坏名未拒（$OUT）"
[[ ! -f "$AGORA_HOME/log/$(date +%F)/projx.md" ]] && ok "读取侧 fail 零写入（无 shard 头残留）" || fail "fail 后 shard 头残留"
# MENTION 精确匹配：mention=bossy 不误吞 dispatcher=boss 的自动提及
T3=$(TITLE="子串mention任务" VERIFY="true" PROJECT_DIR="$PROJ" TC | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
printf 'dispatcher: boss\n' >> "$AGORA_HOME/wiki/tasks/$T3.md"
POST tester@proj --event done --task "$T3" --commit HEAD --evidence x --mention bossy >/dev/null
grep -E 'task:'"$T3"'( \||$)' "$AGORA_HOME"/log/*/proj.md | tail -1 | grep -q "mention:bossy,boss" && ok "MENTION 精确匹配（bossy 不吞 boss）" || fail "MENTION 子串误吞"
# board in-progress 显示心跳 age（last_progress (ts,body)）
T5=$(TITLE="心跳任务" VERIFY="grep -q FIXED app.txt" PROJECT_DIR="$PROJ" TC | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST tester@proj --event claimed --task "$T5" >/dev/null
POST tester@proj --event progress --task "$T5" --body "心跳测试" >/dev/null
bash "$AGORA_HOME/scripts/derive-board.sh" >/dev/null 2>&1
grep -qE "进展（[0-9]+min前）: 心跳测试" "$AGORA_HOME/board/in-progress.md" && ok "board 显示心跳 age" || fail "board 无心跳 age"

echo "===== 身份裁决不冻结（2026-10-20 gt-9f24 事故回归） ====="
# server 启动早于实体页覆盖：启动期 auto-register 因同名页 O_EXCL 撞名让位 → 匿名；
# 旧代码冻结终身（共享 server 08:39 启动早于 10:14 实体页 → 派生会话写路径全拒）；
# 修后每次工具调用重裁决 → 实体页后到补 dirs，同进程内身份立即生效
LATE="$T/late"; mkdir -p "$LATE"
printf -- '---\nname: late\ndirs:\n  - /nonexistent-late-xyz\ncan_spawn: false\n---\n' > "$AGORA_HOME/wiki/entities/late.md"
cd "$AGORA_HOME" && git add -A >/dev/null && AGORA_MECHANICAL=1 git commit -qm "late entity" >/dev/null
python3 - "$PKG/server/agora_mcp.py" "$LATE" "$AGORA_HOME" <<'PYEOF' && ok "身份裁决不冻结（后到覆盖同进程生效）" || fail "身份裁决不冻结（后到覆盖同进程生效）"
import json, subprocess, sys, os
srv, late, home = sys.argv[1], sys.argv[2], sys.argv[3]
env = {**os.environ, "AGORA_HOME": home}
p = subprocess.Popen(["python3", srv], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=late, env=env)
def rpc(m, ps=None, i=[0]):
    i[0] += 1
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i[0],"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
def you():
    r = rpc("tools/call", {"name":"agora_who","arguments":{}})
    return json.loads(r["result"]["content"][0]["text"]).get("you")
# 启动期：late.md dirs 未含 cwd（夹具里 $T 可能已被前序段落 auto-register 覆盖，
# 故不断言匿名，只断言 late 尚未命中——冻结代码下此值此后不再变化）
you0 = you()
assert you0 != "late@late", f"夹具应保证 late 覆盖是后到的，实际启动即 {you0}"
# 实体页后到覆盖 cwd（模拟实体页晚于 server 启动）
f = f"{home}/wiki/entities/late.md"
txt = open(f).read().replace("/nonexistent-late-xyz", late)
open(f, "w").write(txt)
assert you() == "late@late", f"后到覆盖应立即生效，实际 {you()}"
p.stdin.close()
PYEOF

echo "===== task_create idem 幂等＋注入守卫（全量委托 L1 Task1） ====="
rm -f /tmp/agora-pwn-l1
OUT=$(TITLE="幂等任务k1" VERIFY="true" PROJECT_DIR="$PROJ" IDEM=k1 TC)
ID1=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
OUT=$(TITLE="幂等任务k1-retry" VERIFY="true" PROJECT_DIR="$PROJ" IDEM=k1 TC)
ID2=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
[[ -n "$ID1" && "$ID1" = "$ID2" ]] && ok "idem 同 key 重试返回同任务" || fail "idem 同 key 重试返回同任务"
OUT=$( TITLE='x$(touch /tmp/agora-pwn-l1)' VERIFY="true" PROJECT_DIR="$PROJ" TC ) >/dev/null 2>&1
test ! -f /tmp/agora-pwn-l1 && ok "title \$(..) 不被求值（守卫）" || fail "title \$(..) 不被求值（守卫）"
grep -q "^idem: k1$" "$AGORA_HOME/wiki/tasks/$ID1.md" && ok "idem 写入 frontmatter" || fail "idem 写入 frontmatter"
OUT=$(TITLE="无幂等键" TC); NID=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
grep -q "^idem:" "$AGORA_HOME/wiki/tasks/$NID.md" && fail "无 IDEM 不写 idem 行" || ok "无 IDEM 不写 idem 行"

echo "===== wt 建树＋wt_dir/wt_host＋回填归一（全量委托 L1 Task2） ====="
OUT=$(TITLE="wt任务" VERIFY="true" PROJECT_DIR="$PROJ" WT=1 IDEM=wt-a TC)
WTID=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
WTD=$(ls -d "$T"/proj__wt-${WTID}__* 2>/dev/null | head -1)
[ -n "$WTD" ] && [ -d "$WTD" ] && ok "WT=1 建树（命名 proj__wt-gt-x__ts）" || fail "WT=1 建树（命名 proj__wt-gt-x__ts）"
[ -n "$(git -C "$PROJ" branch --list "wt/$WTID")" ] && ok "分支 wt/gt-x 生成" || fail "分支 wt/gt-x 生成"
grep -q "^wt: true$" "$AGORA_HOME/wiki/tasks/$WTID.md" && grep -q "^wt_dir: $WTD$" "$AGORA_HOME/wiki/tasks/$WTID.md" && grep -q "^wt_host: $(hostname)$" "$AGORA_HOME/wiki/tasks/$WTID.md" && ok "frontmatter wt/wt_dir/wt_host" || fail "frontmatter wt/wt_dir/wt_host"
OUT=$(TITLE="无wt任务" VERIFY="true" PROJECT_DIR="$PROJ" TC); PLAIN=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
grep -q "^wt" "$AGORA_HOME/wiki/tasks/$PLAIN.md" && fail "无 WT 不写 wt 字段" || ok "无 WT 不写 wt 字段"
# 回填归一：PROJECT_DIR 传 worktree 路径 → 项目页按主仓注册命中回填
printf -- '---\nname: proj\npath: %s\nverify: "true"\n---\n' "$PROJ" > "$AGORA_HOME/wiki/projects/proj.md"
git -C "$PROJ" worktree add -q "$T/projwt2" 2>/dev/null
OUT=$(TITLE="归一回填" PROJECT_DIR="$T/projwt2" WT=1 IDEM=wt-b TC)
grep -q '^verify: "true"$' "$AGORA_HOME/wiki/tasks/$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p').md" && ok "worktree 路径 verify 回填归一命中" || fail "worktree 路径 verify 回填归一命中"
# 建树幂等：同 IDEM+WT 重试 → 树仅一棵
OUT=$(TITLE="wt任务重试" VERIFY="true" PROJECT_DIR="$PROJ" WT=1 IDEM=wt-a TC)
[ "$(ls -d "$T"/proj__wt-${WTID}__* 2>/dev/null | wc -l)" -eq 1 ] && ok "同 IDEM+WT 重试不建第二棵树" || fail "同 IDEM+WT 重试不建第二棵树"
# WT 无 project_dir 拒
TITLE="坏wt" WT=1 TC 2>/dev/null; [[ $? -eq 2 ]] && ok "WT 缺 project_dir 被拒(rc=2)" || fail "WT 缺 project_dir 被拒(rc=2)"

echo "===== dispatch 深度默认3＋账本推导＋配额账本化（全量委托 L1 Task3） ====="
rm -f "$AGORA_HOME/scripts/sessions.map"   # 前序桥段残留会触发在场优先降级 notified
# 清场：前序段落的活 dispatched（账本口径）全部 cancelled 出集——本段配额计数需净场
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md")):
    try: lines = open(f, encoding="utf-8").read().splitlines()
    except OSError: continue
    for line in lines:
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line: disp[t] = 1
        elif any(f"event:{e}" in line for e in ("done","merged","cancelled")): terminal.add(t)
print(" ".join(t for t in disp if t not in terminal))
PYEOF
); do POST tester@proj --event cancelled --task "$_t" >/dev/null 2>&1; done
DSP()  { AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" "$@"; }
DSPQ() { AGORA_RUNTIME=echo bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" "$@"; }
TID() { echo "$1" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p'; }
D1=$(TID "$(TITLE="深度a" VERIFY=true PROJECT_DIR="$PROJ" TC)"); D2=$(TID "$(TITLE="深度b" VERIFY=true PROJECT_DIR="$PROJ" TC)")
D3=$(TID "$(TITLE="深度c" VERIFY=true PROJECT_DIR="$PROJ" TC)")
E1=$(TID "$(TITLE="链a" VERIFY=true PROJECT_DIR="$PROJ" TC)"); E2=$(TID "$(TITLE="链b" VERIFY=true PROJECT_DIR="$PROJ" TC)")
E3=$(TID "$(TITLE="链c" VERIFY=true PROJECT_DIR="$PROJ" TC)"); F1=$(TID "$(TITLE="配额" VERIFY=true PROJECT_DIR="$PROJ" TC)")
# ① env 深度：默认 3 下 DEPTH=0/1 放行、DEPTH=2 拒
AGORA_DEPTH=0 DSP --task "$D1" 2>/dev/null | grep -q '"mode":"spawned"' && ok "深度默认3：DEPTH=0 放行" || fail "深度默认3：DEPTH=0 放行"
AGORA_DEPTH=1 DSP --task "$D2" 2>/dev/null | grep -q '"mode":"spawned"' && ok "深度默认3：DEPTH=1 放行" || fail "深度默认3：DEPTH=1 放行"
AGORA_DEPTH=2 DSP --task "$D3" 2>&1 | grep -q DEPTH_EXCEEDED && ok "深度默认3：DEPTH=2 拒" || fail "深度默认3：DEPTH=2 拒"
# ② 账本推导：dispatcher_task 链深度与 env 取 max（配额窗已开至 9 不干扰）
DSP --task "$E1" >/dev/null 2>&1   # E1 基线派发（depth 1）
AGORA_DEPTH=0 DSP --task "$E2" --dispatcher-task "$E1" 2>/dev/null | grep -q '"mode":"spawned"' && ok "链派发 E2(dtask=E1) 放行" || fail "链派发 E2(dtask=E1) 放行"
AGORA_DEPTH=0 DSP --task "$E3" --dispatcher-task "$E2" 2>&1 | grep -q DEPTH_EXCEEDED && ok "账本推导：env=0 但链深 NEXT=3 拒" || fail "账本推导拒（env 0 链深 3）"
cat "$AGORA_HOME"/log/*/*.md | grep -F "task:$E2" | grep "event:dispatched" | grep -q "dispatcher_task:$E1" && ok "dispatched 落账含 dispatcher_task" || fail "dispatched 落账含 dispatcher_task"
# ③ 配额账本化（默认 MAX_SPAWN=3）：零 .live 但账本活派发 4 → 拒第 5；终态出集后放行
DSPQ --task "$F1" 2>&1 | grep -q QUOTA_EXCEEDED && ok "配额账本化：4 活派发（零 .live）拒第 5" || fail "配额账本化拒（零 .live）"
POST tester@proj --event cancelled --task "$D1" >/dev/null; POST tester@proj --event cancelled --task "$E1" >/dev/null
DSPQ --task "$F1" 2>/dev/null | grep -q '"mode":"spawned"' && ok "终态出集后配额放行" || fail "终态出集后配额放行"

echo "===== dispatch 发射加固＋凭据预写＋wt 免在场优先（全量委托 L1 Task4） ====="
rm -f "$AGORA_HOME/scripts/sessions.map"
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md")):
    try: lines = open(f, encoding="utf-8").read().splitlines()
    except OSError: continue
    for line in lines:
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line: disp[t] = 1
        elif any(f"event:{e}" in line for e in ("done","merged","cancelled")): terminal.add(t)
print(" ".join(t for t in disp if t not in terminal))
PYEOF
); do POST tester@proj --event cancelled --task "$_t" >/dev/null 2>&1; done
FAKE="$T/fakert"; printf '#!/bin/bash\n[ "$1" = "--version" ] && exit 0\nexit 1\n' > "$FAKE"; chmod +x "$FAKE"
DSPRAW() { AGORA_RUNTIME="${RT:-echo}" AGORA_VERIFY_WIN="${VW:-2}" bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "${P:-$PROJ}" "$@"; }
# ① 假 runtime 秒死：SPAWN_DIED＋diagnosed（日志尾）＋恰一次重试＋凭据重写
G1=$(TID "$(TITLE="加固" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=t4a TC)")
WTD1=$(ls -d "$T"/proj__wt-${G1}__* | head -1)
mkdir -p "$WTD1/.omo/agora-delegation"; echo wrong-content > "$WTD1/.omo/agora-delegation/${G1}.md"
OUT=$(RT="$FAKE" DSPRAW --task "$G1" 2>&1); RC=$?
[[ $RC -ne 0 ]] && echo "$OUT" | grep -q SPAWN_DIED && ok "假 runtime 秒死→SPAWN_DIED 失败 JSON" || fail "假 runtime 秒死→SPAWN_DIED 失败 JSON"
RL=$(ls -t "$AGORA_HOME"/raw/dispatches/*.log | head -1)
[ "$(grep -c '^EXIT:' "$RL")" -eq 2 ] && ok "恰一次重试（两 EXIT 行）" || fail "恰一次重试（EXIT 行数 $(grep -c '^EXIT:' "$RL" 2>/dev/null)）"
cat "$AGORA_HOME"/log/*/*.md | grep -F "task:$G1" | grep "event:diagnosed" | grep -q "EXIT" && ok "diagnosed 落账含日志尾" || fail "diagnosed 落账含日志尾"
grep -q "wrong-content" "$WTD1/.omo/agora-delegation/${G1}.md" && fail "凭据预写重写（错内容被覆盖）" || ok "凭据预写重写（错内容被覆盖）"
grep -q "^gt: $G1$" "$WTD1/.omo/agora-delegation/${G1}.md" && grep -q "^worktree: $WTD1$" "$WTD1/.omo/agora-delegation/${G1}.md" && ok "凭据内容含 gt-id＋树路径" || fail "凭据内容含 gt-id＋树路径"
POST tester@proj --event cancelled --task "$G1" >/dev/null 2>&1
# ② wt 免在场优先：sessions.map 在场 → wt 任务仍 spawned；非 wt 对照 notified
printf '%s tester sess-fake %s\n' "$(hostname)" "$(date +%s)" >> "$AGORA_HOME/scripts/sessions.map"
G2=$(TID "$(TITLE="在场豁免" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=t4b TC)")
DSPRAW --task "$G2" 2>/dev/null | grep -q '"mode":"spawned"' && ok "wt 任务免在场优先（spawned）" || fail "wt 任务免在场优先"
N1=$(TID "$(TITLE="在场对照" VERIFY=true PROJECT_DIR="$PROJ" TC)")
DSPRAW --task "$N1" 2>/dev/null | grep -q '"mode":"notified"' && ok "非 wt 在场优先照旧（notified 对照）" || fail "非 wt 在场对照"
# ③ 预检零残留：project_dir 不存在 → SPAWN_PRECHECK 且账本无 dispatched
N2=$(TID "$(TITLE="预检" VERIFY=true PROJECT_DIR="$PROJ" TC)")
OUT=$(P="$PROJ/dead" DSPRAW --task "$N2" 2>&1)
echo "$OUT" | grep -q SPAWN_PRECHECK && ok "预检失败 SPAWN_PRECHECK" || fail "预检失败 SPAWN_PRECHECK"
cat "$AGORA_HOME"/log/*/*.md | grep -F "task:$N2" | grep -q "event:dispatched" && fail "预检失败零落账" || ok "预检失败零落账"
# ④ 树误删→锚点重建→spawn 成功
G3=$(TID "$(TITLE="重建" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=t4c TC)")
WTD3=$(ls -d "$T"/proj__wt-${G3}__* | head -1); rm -rf "$WTD3"
DSPRAW --task "$G3" 2>/dev/null | grep -q '"mode":"spawned"' && ok "树误删自动重建（spawned）" || fail "树误删自动重建"
[ -d "$WTD3" ] && ok "重建树目录存在" || fail "重建树目录存在"

echo "===== verify 两段制＋merged 事件（全量委托 L1 Task5） ====="
tick()   { mkdir -p "$AGORA_HOME/.git/merge-tickets"; : > "$AGORA_HOME/.git/merge-tickets/$1"; }
untick() { rm -f "$AGORA_HOME/.git/merge-tickets/$1"; }
V1=$(TID "$(TITLE="树上验收" VERIFY="test -f ok-marker" PROJECT_DIR="$PROJ" WT=1 IDEM=t5a TC)")
WTV1=$(ls -d "$T"/proj__wt-${V1}__* | head -1)
touch "$WTV1/ok-marker"   # 只在树内——主仓没有
POST tester@proj --event claimed --task "$V1" >/dev/null
POST tester@proj --event done --task "$V1" --commit HEAD --evidence "树上过门" >/dev/null \
  && ok "done verify 在 wt_dir 执行（树内标记命中）" || fail "done verify 在 wt_dir 执行"
V2=$(TID "$(TITLE="merged载体" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$V2" >/dev/null
BR=$(git -C "$PROJ" symbolic-ref --short HEAD); H=$(git -C "$PROJ" rev-parse HEAD)
tick "$V2"
POST tester@proj --event merged --task "$V2" --commit "$H" --branch "$BR" >/dev/null \
  && ok "merged 落账（commit==branch HEAD）" || fail "merged 落账"
untick "$V2"
POST tester@proj --event merged --task "$V2" --commit "0000000000000000000000000000000000000000" --branch "$BR" >/dev/null 2>&1 \
  && fail "merged commit≠HEAD 被拒" || ok "merged commit≠HEAD 被拒"
POST tester@proj --event merged --task "$V2" >/dev/null 2>&1 \
  && fail "merged 缺 commit 被拒" || ok "merged 缺 commit 被拒"
tick "$V1"
POST tester@proj --event merged --task "$V1" --commit "$H" >/dev/null \
  && ok "merged 缺省 branch=project_dir 当前分支" || fail "merged 缺省 branch"
untick "$V1"

echo "===== merge.sh 合并闭环（全量委托 L1 Task6） ====="
rm -f "$AGORA_HOME/scripts/sessions.map"
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md")):
    try: lines = open(f, encoding="utf-8").read().splitlines()
    except OSError: continue
    for line in lines:
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line: disp[t] = 1
        elif any(f"event:{e}" in line for e in ("done","merged","cancelled")): terminal.add(t)
print(" ".join(t for t in disp if t not in terminal))
PYEOF
); do POST tester@proj --event cancelled --task "$_t" >/dev/null 2>&1; done
MERGE() { bash "$AGORA_HOME/scripts/merge.sh" --actor tester@proj --task "$1"; }
LEDEV() { cat "$AGORA_HOME"/log/*/*.md 2>/dev/null | grep -F "task:$1" | grep "event:$2"; }
MKWT() { TID "$(TITLE="$1" VERIFY="$2" PROJECT_DIR="$PROJ" WT=1 IDEM="$3" TC)"; }
WTCOMMIT() { echo "$2" > "$1/marker-$3"; git -C "$1" add -A >/dev/null; git -C "$1" -c user.name=t -c user.email=t@l commit -qm "$3"; }
# ① 跨仓正常 ff 合并＋merged＋清树
M1=$(MKWT "合并" "grep -q MERGED \$PWD/main-file" t6a); W1=$(ls -d "$T"/proj__wt-${M1}__*)
echo MERGED > "$W1/main-file"; git -C "$W1" add -A; git -C "$W1" -c user.name=t -c user.email=t@l commit -qm m1
MERGE "$M1" 2>/dev/null | grep -q merged && ok "① ff 合并闭环 JSON" || fail "① ff 合并闭环"
grep -q MERGED "$PROJ/main-file" && ok "① 主仓含合并内容" || fail "① 主仓含合并内容"
LEDEV "$M1" merged | grep -q "event:merged" && ok "① merged 落账" || fail "① merged 落账"
[ ! -d "$W1" ] && [ -z "$(git -C "$PROJ" branch --list "wt/$M1")" ] && ok "① 树已清＋分支已删" || fail "① 树已清＋分支已删"
# ② 集成 verify FAIL→原子回滚＋blocked＋reopened
M2=$(MKWT "回滚" "false" t6b); W2=$(ls -d "$T"/proj__wt-${M2}__*)
WTCOMMIT "$W2" x m2; PRE2=$(git -C "$PROJ" rev-parse HEAD)
MERGE "$M2" >/dev/null 2>&1 && fail "② verify FAIL 拒（fail JSON）" || ok "② verify FAIL 拒（fail JSON）"
[ "$(git -C "$PROJ" rev-parse HEAD)" = "$PRE2" ] && ok "② 主支零痕迹（原子回滚）" || fail "② 主支零痕迹"
LEDEV "$M2" blocked | grep -q "event:blocked" && LEDEV "$M2" reopened | grep -q "event:reopened" && ok "② blocked→reopened 落账" || fail "② blocked→reopened 落账"
# ③ non-ff→NOT_FF＋blocked＋reopened
M3=$(MKWT "非快进" "true" t6c); W3=$(ls -d "$T"/proj__wt-${M3}__*)
WTCOMMIT "$W3" x m3; echo ahead > "$PROJ/ahead-file"; git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@l commit -qm ahead
OUT=$(MERGE "$M3" 2>&1); echo "$OUT" | grep -q NOT_FF && ok "③ non-ff NOT_FF" || fail "③ non-ff NOT_FF"
LEDEV "$M3" blocked | grep -q "event:blocked" && LEDEV "$M3" reopened | grep -q "event:reopened" && ok "③ blocked→reopened" || fail "③ blocked→reopened"
# ④ 删树→锚点重建→合并
M4=$(MKWT "重建合并" "true" t6d); W4=$(ls -d "$T"/proj__wt-${M4}__*)
WTCOMMIT "$W4" x m4; rm -rf "$W4"
MERGE "$M4" 2>/dev/null | grep -q merged && ok "④ 树误删重建后合并" || fail "④ 树误删重建后合并"
# ⑤ 幂等补账：目标已含→仅补 merged、HEAD 不动
M5=$(MKWT "补账" "true" t6e); W5=$(ls -d "$T"/proj__wt-${M5}__*)
WTCOMMIT "$W5" x m5; H5B=$(git -C "$PROJ" rev-parse HEAD)
git -C "$PROJ" merge -q --ff-only "wt/$M5" 2>/dev/null; H5M=$(git -C "$PROJ" rev-parse HEAD)
MERGE "$M5" 2>/dev/null | grep -q merged && ok "⑤ 幂等补账 JSON" || fail "⑤ 幂等补账"
[ "$(git -C "$PROJ" rev-parse HEAD)" = "$H5M" ] && [ "$(LEDEV "$M5" merged | grep -c merged)" -eq 1 ] && ok "⑤ 无第二次合并痕迹（HEAD 不动＋merged 恰一条）" || fail "⑤ 幂等痕迹"
[ ! -d "$W5" ] && ok "⑤ 幂等路径也清树" || fail "⑤ 幂等路径也清树"
# ⑥ 同仓链：MC(dispatcher_task=MB) 合并目标=上游 wt 分支（下游先 rebase 到上游分支——链式协议形态）
MB=$(MKWT "上游" "true" t6f); WB=$(ls -d "$T"/proj__wt-${MB}__*)
MC=$(MKWT "下游" "true" t6g); WC=$(ls -d "$T"/proj__wt-${MC}__*)
AGORA_RUNTIME=echo bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$MC" --dispatcher-task "$MB" >/dev/null 2>&1
WTCOMMIT "$WB" up upstream; WTCOMMIT "$WC" down downstream
git -C "$WC" rebase -q "wt/$MB"   # 下游基到上游分支（否则两独立分支分叉必非快进）
DC=$(git -C "$WC" rev-parse HEAD); PREMAIN=$(git -C "$PROJ" rev-parse HEAD)
MERGE "$MC" 2>/dev/null | grep -q merged && ok "⑥ 同仓链合并 JSON" || fail "⑥ 同仓链合并"
git -C "$WB" merge-base --is-ancestor "$DC" HEAD 2>/dev/null && ok "⑥ 上游树已含下游提交" || fail "⑥ 上游树已含下游提交"
[ "$(git -C "$PROJ" rev-parse HEAD)" = "$PREMAIN" ] && ok "⑥ 主仓不动" || fail "⑥ 主仓不动"
# ⑦ 脏目标守卫
M7=$(MKWT "脏目标" "true" t6h); W7=$(ls -d "$T"/proj__wt-${M7}__*)
WTCOMMIT "$W7" x m7; printf 'dirty\n' >> "$PROJ/app.txt"   # 已跟踪文件的未提交修改（untracked 已放行）
MERGE "$M7" 2>&1 | grep -q TARGET_DIRTY && ok "⑦ 脏目标（tracked 修改）拒绝合并" || fail "⑦ 脏目标拒绝合并"
git -C "$PROJ" checkout -q -- app.txt

echo "===== poll 补档：重派/孤儿/豁免/GC/host（全量委托 L1 Task7） ====="
rm -f "$AGORA_HOME/scripts/sessions.map"
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md")):
    try: lines = open(f, encoding="utf-8").read().splitlines()
    except OSError: continue
    for line in lines:
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line: disp[t] = 1
        elif any(f"event:{e}" in line for e in ("done","merged","cancelled")): terminal.add(t)
print(" ".join(t for t in disp if t not in terminal))
PYEOF
); do POST tester@proj --event cancelled --task "$_t" >/dev/null 2>&1; done
POLLT() { AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=0 AGORA_WT_GRACE_MIN=0 AGORA_DISPATCH_TIMEOUT=0 \
           AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo bash "$AGORA_HOME/scripts/poll.sh" 2>/dev/null; }
LEV() { cat "$AGORA_HOME"/log/*/*.md 2>/dev/null | grep -E "(^|[|] )task:$1( |$)" | grep "event:$2"; }
MKWT2() { TID "$(TITLE="$1" VERIFY="true" PROJECT_DIR="$PROJ" WT=1 IDEM="$2" TC)"; }
# ① done-unmerged：poll → diagnosed（未合并）＋恢复性重派上游
PU=$(MKWT2 "上游u" t7a); PD_=$(MKWT2 "下游d" t7b)
AGORA_RUNTIME=echo bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$PD_" --dispatcher-task "$PU" >/dev/null 2>&1
WU=$(ls -d "$T"/proj__wt-${PD_}__*); echo w > "$WU/wfile"; git -C "$WU" add -A; git -C "$WU" -c user.name=t -c user.email=t@l commit -qm d
POST tester@proj --event claimed --task "$PD_" >/dev/null
POST tester@proj --event done --task "$PD_" --commit HEAD --evidence ok >/dev/null
POLLT >/dev/null
LEV "$PD_" diagnosed | grep -q "未合并" && ok "① done-unmerged→diagnosed" || fail "① done-unmerged→diagnosed"
[ "$(LEV "$PU" dispatched | grep -c event:dispatched)" -ge 1 ] && ok "① 上游被恢复性重派" || fail "① 上游被恢复性重派"
git -C "$PROJ" merge -q --ff-only "wt/$PD_" 2>/dev/null
tick "$PD_"
POST tester@proj --event merged --task "$PD_" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null
untick "$PD_"
POLLT >/dev/null
[ "$(LEV "$PD_" diagnosed | grep -c "未合并")" -eq 1 ] && ok "① merged 后不再诊断" || fail "① merged 后不再诊断"
# ①b git 层已合并短路：wt/<t> 引用存在且为 project_dir HEAD 祖先＋账本无 merged → 簿记滞后，梯子安静（gt-99af 修复二）；
# 无引用/未并 → 照常诊断/重派不静默（由段①与 S4a-d 真未合并夹具守）
GU=$(MKWT2 "短路u" i8a); GD=$(MKWT2 "短路d" i8b)
AGORA_RUNTIME=echo bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$GD" --dispatcher-task "$GU" >/dev/null 2>&1
WG=$(ls -d "$T"/proj__wt-${GD}__*); echo s > "$WG/sfile"; git -C "$WG" add -A; git -C "$WG" -c user.name=t -c user.email=t@l commit -qm s
POST tester@proj --event claimed --task "$GD" >/dev/null
POST tester@proj --event done --task "$GD" --commit HEAD --evidence ok >/dev/null
git -C "$PROJ" merge -q --ff-only "wt/$GD" 2>/dev/null   # 已实际并入主仓，账本不落 merged（簿记滞后形态）
POLLT >/dev/null
[ -z "$(LEV "$GD" diagnosed)" ] && [ -z "$(LEV "$GU" dispatched)" ] \
  && ok "①b git 已并＋账本无 merged → 梯子安静（不诊断不重派）" || fail "①b 簿记滞后误诊/误重派（diag=$(LEV "$GD" diagnosed | head -1)）"
# ② 重派上限：3 次后第 4 次 escalated、不再派
QU=$(MKWT2 "上限u" t7c); QD=$(MKWT2 "上限d" t7d)
AGORA_RUNTIME=echo bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$QD" --dispatcher-task "$QU" >/dev/null 2>&1
WQ=$(ls -d "$T"/proj__wt-${QD}__*); echo q > "$WQ/qfile"; git -C "$WQ" add -A; git -C "$WQ" -c user.name=t -c user.email=t@l commit -qm q
POST tester@proj --event claimed --task "$QD" >/dev/null
POST tester@proj --event done --task "$QD" --commit HEAD --evidence ok >/dev/null
for i in 1 2 3 4; do POLLT >/dev/null; done
ND=$(LEV "$QU" dispatched | grep -c event:dispatched)
LEV "$QD" escalated | grep -q "event:escalated" && [ "$ND" -eq 3 ] && ok "② 3 次重派后第 4 次 escalated（重派 $ND 次）" || fail "② 上限（dispatched=$ND）"
# ③ 孤儿 dispatched（无 run log）→ diagnosed＋重派；有 log 不命中
OO=$(MKWT2 "孤儿" t7e)
POST tester@proj --event dispatched --task "$OO" --target "$PROJ" --child tester --run "raw/dispatches/d-orphan1.log" >/dev/null
OL=$(MKWT2 "有log" t7f)
POST tester@proj --event dispatched --task "$OL" --target "$PROJ" --child tester --run "raw/dispatches/d-orphan2.log" >/dev/null
mkdir -p "$AGORA_HOME/raw/dispatches"; echo x > "$AGORA_HOME/raw/dispatches/d-orphan2.log"
POLLT >/dev/null
LEV "$OO" diagnosed | grep -q "孤儿" && ok "③ 孤儿 dispatched→diagnosed＋重派" || fail "③ 孤儿档"
[ "$(LEV "$OL" diagnosed | grep -c "孤儿")" -eq 0 ] && ok "③ 有 run log 不命中孤儿档" || fail "③ 有 log 误命中"
# ④ GC：终态＋宽限尽＋clean→删；dirty→留；宽限内→留；缺页树 doctor 报告
GT=$(MKWT2 "gc净树" t7g); WG=$(ls -d "$T"/proj__wt-${GT}__*)
echo g > "$WG/gfile"; git -C "$WG" add -A; git -C "$WG" -c user.name=t -c user.email=t@l commit -qm g
POST tester@proj --event claimed --task "$GT" >/dev/null
POST tester@proj --event done --task "$GT" --commit HEAD --evidence ok >/dev/null
git -C "$PROJ" merge -q --ff-only "wt/$GT" 2>/dev/null
tick "$GT"; POST tester@proj --event merged --task "$GT" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null
untick "$GT"
DT=$(MKWT2 "gc脏树" t7h); WD=$(ls -d "$T"/proj__wt-${DT}__*)
echo d > "$WD/dfile"; git -C "$WD" add -A; git -C "$WD" -c user.name=t -c user.email=t@l commit -qm d
POST tester@proj --event claimed --task "$DT" >/dev/null
POST tester@proj --event done --task "$DT" --commit HEAD --evidence ok >/dev/null
git -C "$PROJ" merge -q --ff-only "wt/$DT" 2>/dev/null
tick "$DT"; POST tester@proj --event merged --task "$DT" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null
untick "$DT"
echo uncommitted > "$WD/dirty-file"
GR=$(MKWT2 "gc宽限" t7i); WR=$(ls -d "$T"/proj__wt-${GR}__*)
echo r > "$WR/rfile"; git -C "$WR" add -A; git -C "$WR" -c user.name=t -c user.email=t@l commit -qm r
POST tester@proj --event claimed --task "$GR" >/dev/null
POST tester@proj --event done --task "$GR" --commit HEAD --evidence ok >/dev/null
git -C "$PROJ" merge -q --ff-only "wt/$GR" 2>/dev/null
tick "$GR"; POST tester@proj --event merged --task "$GR" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null
untick "$GR"
AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=0 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=0 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo \
  bash "$AGORA_HOME/scripts/poll.sh" >/dev/null 2>&1   # 宽限大：全留
[ -d "$WR" ] && ok "④ 宽限内不删" || fail "④ 宽限内不删"
POLLT >/dev/null   # 宽限 0：净树删、脏树留
[ ! -d "$WG" ] && ok "④ 终态＋宽限尽＋clean→删" || fail "④ 净树未删"
[ -d "$WD" ] && ok "④ dirty 树只报告不删" || fail "④ dirty 树被误删"
rm -f "$WD/dirty-file"
OR=$(MKWT2 "缺页树" t7j); WO=$(ls -d "$T"/proj__wt-${OR}__*)
rm -f "$AGORA_HOME/wiki/tasks/$OR.md"
bash "$AGORA_HOME/scripts/doctor.sh" 2>/dev/null | grep -q "__wt-" && ok "④ 缺任务页树 doctor 报告" || fail "④ doctor 未报告缺页树"
[ -d "$WO" ] && ok "④ 缺页树不删" || fail "④ 缺页树被误删"
# ⑤ parent 链 watchdog ×4 豁免：改写观察时钟模拟 45min 无事件
PT_=$(TID "$(TITLE="豁免母" TC)"); CN=$(TID "$(TITLE="豁免子" PARENT="$PT_" TC)")
POST tester@proj --event claimed --task "$PT_" >/dev/null; POST tester@proj --event claimed --task "$CN" >/dev/null
AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 \
  bash "$AGORA_HOME/scripts/poll.sh" >/dev/null 2>&1   # 只为武装观察时钟
python3 - "$AGORA_HOME" <<'PYEOF'
import json, os, sys, time
f = f"{sys.argv[1]}/.git/poll-state.json"
s = json.load(open(f))
for t, e in s.get("_activity", {}).items():
    if isinstance(e, dict): e["since"] = time.time() - 45*60
json.dump(s, open(f, "w"))
PYEOF
AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 \
  bash "$AGORA_HOME/scripts/poll.sh" >/dev/null 2>&1
[ -z "$(LEV "$PT_" diagnosed)" ] && [ -n "$(LEV "$CN" diagnosed)" ] \
  && ok "⑤ parent 链挂活子任务→母任务 ×4 豁免（子正常诊断）" || fail "⑤ 豁免口径"
# ⑥ wt_host 异机→mention 拾取跳过
HO=$(MKWT2 "异机" t7k)
sed -i "s/^wt_host: .*/wt_host: other-host-99/" "$AGORA_HOME/wiki/tasks/$HO.md"
AGORA_HOME="$AGORA_HOME" python3 - "$AGORA_HOME" "$HO" <<'PYEOF'
import os, sys, time
home, task = sys.argv[1], sys.argv[2]
name = "tester"
os.makedirs(f"{home}/inbox/{name}", exist_ok=True)
open(f"{home}/inbox/{name}/{int(time.time()*1e9):019d}.md", "w").write(
    f"- from:x@y | ts:0 | ref:x | summary:todo {task}\n")
PYEOF
R=$(AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 \
  bash "$AGORA_HOME/scripts/poll.sh" 2>/dev/null)
echo "$R" | grep -q "$HO" && echo "$R" | grep -q "wt_host" && [ -z "$(LEV "$HO" dispatched)" ] \
  && ok "⑥ wt_host 异机任务拾取跳过（held）" || fail "⑥ host 限定"
# ⑥b 账本真值终态核查棒：任务已 merged（簿记收尾）而看板 todo 滞后残留 → mention 不派发（gt-99af 修复一；
# derive-board 不处理 merged 事件 → todo 残留，现状拾取段只信看板会派发雪球）
TZ=$(TID "$(TITLE="终态不派" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
tick "$TZ"; POST tester@proj --event merged --task "$TZ" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null; untick "$TZ"
POST rival@proj2 --event progress --task "$TZ" --mention tester --body "终态后不应派发" >/dev/null
RB=$(POLLT)
[ -z "$(LEV "$TZ" dispatched)" ] && echo "$RB" | grep -q "$TZ" && echo "$RB" | grep -q "终态" \
  && ok "⑥b 终态（merged）任务 mention 不派发（held）" || fail "⑥b 终态任务被派发（雪球）或 held 缺失（got: $(LEV "$TZ" dispatched | head -1))"
# ⑦ stale-live 回归（既有档）
SL=$(MKWT2 "滞留" t7l)
POST tester@proj --event claimed --task "$SL" >/dev/null
POST tester@proj --event dispatched --task "$SL" --target "$PROJ" --child tester --run "raw/dispatches/d-stale.log" >/dev/null
touch "$AGORA_HOME/raw/dispatches/d-stale.log.live"; touch -d '2 hours ago' "$AGORA_HOME/raw/dispatches/d-stale.log.live"
AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=0 \
  bash "$AGORA_HOME/scripts/poll.sh" >/dev/null 2>&1
LEV "$SL" diagnosed | grep -q "滞留" && ok "⑦ .live 滞留→diagnosed（既有档回归）" || fail "⑦ stale-live"

echo "===== BOOT 链式协议＋setup 钩子（全量委托 L1 Task8） ====="
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md")):
    try: lines = open(f, encoding="utf-8").read().splitlines()
    except OSError: continue
    for line in lines:
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line: disp[t] = 1
        elif any(f"event:{e}" in line for e in ("done","merged","cancelled")): terminal.add(t)
print(" ".join(t for t in disp if t not in terminal))
PYEOF
); do POST tester@proj --event cancelled --task "$_t" >/dev/null 2>&1; done
# 项目页 setup: 钩子——spawn 前在树内执行
printf 'setup: touch %s/setup-marker\n' "$T" >> "$AGORA_HOME/wiki/projects/proj.md"
B1=$(TID "$(TITLE="setup钩子" VERIFY="true" PROJECT_DIR="$PROJ" WT=1 IDEM=t8a TC)")
AGORA_RUNTIME=echo AGORA_VERIFY_WIN=2 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$B1" 2>/dev/null | grep -q '"mode":"spawned"' \
  && ok "setup 任务派发 spawned" || fail "setup 任务派发"
[ -f "$T/setup-marker" ] && ok "setup: 在树内（spawn 前）执行（侧效文件）" || fail "setup 执行"
BOOTJSON=$(AGORA_RUNTIME=echo AGORA_VERIFY_WIN=2 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$B1" 2>/dev/null)
# setup 失败→零落账零 spawn
sed -i 's|^setup: .*|setup: exit 1|' "$AGORA_HOME/wiki/projects/proj.md"
B2=$(TID "$(TITLE="setup失败" VERIFY="true" PROJECT_DIR="$PROJ" WT=1 IDEM=t8b TC)")
OUT=$(AGORA_RUNTIME=echo AGORA_VERIFY_WIN=2 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$B2" 2>&1)
echo "$OUT" | grep -q SETUP_FAILED && ok "setup 失败→SETUP_FAILED" || fail "setup 失败 JSON"
cat "$AGORA_HOME"/log/*/*.md | grep -E "(^|[|] )task:$B2( |$)" | grep -q "event:dispatched" && fail "setup 失败零落账" || ok "setup 失败零落账"
sed -i 's|^setup: .*|setup: true|' "$AGORA_HOME/wiki/projects/proj.md"
# BOOT 关键词（从账本 dispatched 的 BOOT 不可见——直接源码断言＋行为断言走 grep 源文件）
for kw in "装环境" "不自己合并" "恢复性重派" "rebase"; do
  grep -q "$kw" "$AGORA_HOME/scripts/dispatch.sh" && ok "BOOT 含「$kw」" || fail "BOOT 含「$kw」"
done

echo "===== 终审修复批（三分册 B-C1/W1-5 + A-W1/W2 + C-W1/W2 + S1/S3/M2/M5） ====="
# F1 (B-C1): GC 判据＝merged/cancelled，done 单独不足——done 未合并的净树不删
F1=$(TID "$(TITLE="gc-done未删" VERIFY="true" PROJECT_DIR="$PROJ" WT=1 IDEM=f1 TC)")
WF1=$(ls -d "$T"/proj__wt-${F1}__*)
echo f > "$WF1/ff"; git -C "$WF1" add -A; git -C "$WF1" -c user.name=t -c user.email=t@l commit -qm f1
POST tester@proj --event claimed --task "$F1" >/dev/null
POST tester@proj --event done --task "$F1" --commit HEAD --evidence ok >/dev/null
AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=0 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo \
  bash "$AGORA_HOME/scripts/poll.sh" >/dev/null 2>&1
[ -d "$WF1" ] && ok "F1 done(未 merged)净树 GC 不删" || fail "F1 done 未合并树被删（数据丢失）"
# F2 (B-W1): task-create 锁超时不得假成功
( exec 9>"$AGORA_HOME/.git/post.lock"; flock -n 9 && sleep 6 ) &
OUT=$(AGORA_LOCK_WAIT=1 TITLE="锁超时" VERIFY=true PROJECT_DIR="$PROJ" TC 2>&1); RC=$?
sleep 6
[[ $RC -ne 0 ]] && ! echo "$OUT" | grep -q '"task"' && ok "F2 锁超时非零退出无假成功 JSON" || fail "F2 锁超时假成功（rc=$RC）"
# F3 (B-W2): merge 目标分支漂移守卫（上游树检出非目标分支→拒）
F3U=$(TID "$(TITLE="漂移u" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f3u TC)"); W3U=$(ls -d "$T"/proj__wt-${F3U}__*)
F3D=$(TID "$(TITLE="漂移d" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f3d TC)"); W3D=$(ls -d "$T"/proj__wt-${F3D}__*)
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$F3D" --dispatcher-task "$F3U" >/dev/null 2>&1
echo x > "$W3D/xf"; git -C "$W3D" add -A; git -C "$W3D" -c user.name=t -c user.email=t@l commit -qm x
git -C "$W3D" rebase -q "wt/$F3U" 2>/dev/null; DC3=$(git -C "$W3D" rev-parse HEAD)
git -C "$W3U" checkout -qb side-branch 2>/dev/null   # 上游树检出他支
OUT=$(bash "$AGORA_HOME/scripts/merge.sh" --actor tester@proj --task "$F3D" 2>&1)
echo "$OUT" | grep -q TARGET_DETACHED && ok "F3 目标分支漂移被拒" || fail "F3 漂移未拒（$OUT）"
git -C "$W3U" checkout -q "wt/$F3U" 2>/dev/null; git -C "$W3U" branch -qD side-branch 2>/dev/null
# F4 (B-W5): 配额僵尸出集——last=diagnosed 的 dispatched 不占额
Z1=$(TID "$(TITLE="僵1" VERIFY=true PROJECT_DIR="$PROJ" TC)"); Z2=$(TID "$(TITLE="僵2" VERIFY=true PROJECT_DIR="$PROJ" TC)")
Z3=$(TID "$(TITLE="僵3" VERIFY=true PROJECT_DIR="$PROJ" TC)"); Z4=$(TID "$(TITLE="僵4" VERIFY=true PROJECT_DIR="$PROJ" TC)")
for z in Z1 Z2 Z3; do
  POST tester@proj --event dispatched --task "${!z}" --target "$PROJ" --child tester --run "raw/dispatches/d-z$z.log" >/dev/null
  POST tester@proj --event diagnosed --task "${!z}" --conclusion "秒死占位测试" >/dev/null
done
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=3 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$Z4" 2>/dev/null | grep -q '"mode":"spawned"' \
  && ok "F4 last=diagnosed 出集（3 僵尸后第 4 派放行）" || fail "F4 配额僵尸 wedge"
# F5 (A-W1): dispatcher_task 机械推导（未传时取 actor 最近 claimed 无终态任务）
C5=$(TID "$(TITLE="推导源" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$C5" >/dev/null
D5=$(TID "$(TITLE="推导目标" VERIFY=true PROJECT_DIR="$PROJ" TC)")
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$D5" >/dev/null 2>&1
cat "$AGORA_HOME"/log/*/*.md | grep -E "(^|[|] )task:$D5( |$)" | grep event:dispatched | grep -q "dispatcher_task:$C5" \
  && ok "F5 dispatcher_task 机械推导落账" || fail "F5 推导缺失"
# F6 (A-W2): done-unmerged diagnosed 必 mention 派单方（跑一轮 MERGE_WAIT=0 产生诊断）
AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo \
  bash "$AGORA_HOME/scripts/poll.sh" >/dev/null 2>&1
LEV "$F1" diagnosed | grep "未合并" | tail -1 | grep -q "mention:tester" \
  && ok "F6 done-unmerged diagnosed 带派单方 mention" || fail "F6 diagnosed 无 mention"
# F7 (C-W2): merged 机械票——非 merge.sh 直 post 拒
P7=$(TID "$(TITLE="票" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event merged --task "$P7" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null 2>&1 \
  && fail "F7 无票直 post merged 被拒" || ok "F7 无票直 post merged 被拒"
# F8 (B-M2): merged 落账含 branch 字段（走 merge.sh 正常路径自建现场）
F8T=$(TID "$(TITLE="branch落账" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f8 TC)")
W8=$(ls -d "$T"/proj__wt-${F8T}__*)
echo b > "$W8/bf"; git -C "$W8" add -A; git -C "$W8" -c user.name=t -c user.email=t@l commit -qm b
bash "$AGORA_HOME/scripts/merge.sh" --actor tester@proj --task "$F8T" >/dev/null 2>&1
cat "$AGORA_HOME"/log/*/*.md | grep -E "(^|[|] )task:$F8T( |$)" | grep event:merged | grep -q "branch:" \
  && ok "F8 merged 落账含 branch" || fail "F8 merged 无 branch 字段"
# F9 (S3): merge.sh wt_host 异机守卫
F9T=$(TID "$(TITLE="异机合并" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f9 TC)"); W9=$(ls -d "$T"/proj__wt-${F9T}__*)
echo y > "$W9/yf"; git -C "$W9" add -A; git -C "$W9" -c user.name=t -c user.email=t@l commit -qm y
sed -i "s/^wt_host: .*/wt_host: other-99/" "$AGORA_HOME/wiki/tasks/$F9T.md"
bash "$AGORA_HOME/scripts/merge.sh" --actor tester@proj --task "$F9T" 2>&1 | grep -q WT_HOST_MISMATCH && ok "F9 wt_host 异机合并被拒" || fail "F9 异机合并未拒"
# F10 (B-W3): reset 并发守卫——verify 期间目标推进则不回滚
F10=$(TID "$(TITLE="并发守卫" VERIFY='git commit --allow-empty -qm adv; false' PROJECT_DIR="$PROJ" WT=1 IDEM=f10 TC)")
WA=$(ls -d "$T"/proj__wt-${F10}__*)
echo c > "$WA/cf"; git -C "$WA" add -A; git -C "$WA" -c user.name=t -c user.email=t@l commit -qm c
PRE10=$(git -C "$PROJ" rev-parse HEAD)
OUT=$(bash "$AGORA_HOME/scripts/merge.sh" --actor tester@proj --task "$F10" 2>&1)
[ "$(git -C "$PROJ" rev-parse HEAD)" != "$PRE10" ] && ok "F10 verify 窗口并发推进不被 reset 吞" || fail "F10 并发提交被 reset 吞"
git -C "$PROJ" reset -q --hard "$PRE10"   # 测试现场复位
# F11 (M5): poll 重派上游时透传其原链 dispatcher_task
F11U=$(TID "$(TITLE="透传u" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f11u TC)")
F11P=$(TID "$(TITLE="透传p" VERIFY=true PROJECT_DIR="$PROJ" TC)")   # u 的上游（pp）
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$F11U" --dispatcher-task "$F11P" >/dev/null 2>&1
POST tester@proj --event claimed --task "$F11U" >/dev/null
F11D=$(TID "$(TITLE="透传d" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f11d TC)")
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$F11D" --dispatcher-task "$F11U" >/dev/null 2>&1
WD11=$(ls -d "$T"/proj__wt-${F11D}__*); echo t > "$WD11/tf"; git -C "$WD11" add -A; git -C "$WD11" -c user.name=t -c user.email=t@l commit -qm t
POST tester@proj --event claimed --task "$F11D" >/dev/null
POST tester@proj --event done --task "$F11D" --commit HEAD --evidence ok >/dev/null
AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo \
  bash "$AGORA_HOME/scripts/poll.sh" >/dev/null 2>&1
cat "$AGORA_HOME"/log/*/*.md | grep -E "(^|[|] )task:$F11U( |$)" | grep event:dispatched | tail -1 | grep -q "dispatcher_task:$F11P" \
  && ok "F11 poll 重派透传原链 dispatcher_task" || fail "F11 重派链断裂"


echo "===== 已知风险批次（B-M3 孤儿判据 / B-M4 重派回报 / B-M7 GC 可见性 / doctor UTF-8） ====="
# 清场前奏：前序段落遗留活 dispatched 全部 cancelled 出集（配额/孤儿口径净场，沿 BOOT 段模式）
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md")):
    try: lines = open(f, encoding="utf-8").read().splitlines()
    except OSError: continue
    for line in lines:
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:dispatched" in line: disp[t] = 1
        elif any(f"event:{e}" in line for e in ("done", "merged", "cancelled")): terminal.add(t)
print(" ".join(t for t in disp if t not in terminal))
PYEOF
); do POST tester@proj --event cancelled --task "$_t" >/dev/null 2>&1; done
# R1 (B-M3): 孤儿判据＝最后事件==dispatched 且 run log 缺失——诊断过的任务重派后再孤儿必再报
R1=$(MKWT2 "诊断后孤儿" r1m3)
POST tester@proj --event dispatched --task "$R1" --target "$PROJ" --child tester --run "raw/dispatches/d-r1a.log" >/dev/null
POLLT >/dev/null   # 第一轮：孤儿 diagnosed（既有行为）
POST tester@proj --event diagnosed --task "$R1" --conclusion "stalled 模拟：诊断后派生仍死" >/dev/null
sleep 1.1   # 撞秒防线：diagnosed 与 re-dispatched 同秒时 last 取首行（ts 秒级分辨率）会漏报第二次孤儿——夹具隔离到不同秒，断言语义不变
POST tester@proj --event dispatched --task "$R1" --target "$PROJ" --child tester --run "raw/dispatches/d-r1b.log" >/dev/null
POLLT >/dev/null   # B-M3：最后事件==dispatched 无 run log → 必须再报（现状累计判据红）
[ "$(LEV "$R1" diagnosed | grep -c "孤儿")" -ge 2 ] && ok "R1 诊断后重派仍报孤儿（B-M3）" || fail "R1 累计判据致孤儿失明（B-M3）"
# R2 (B-M4): 孤儿重派核查 dispatch 返回码——失败记 redispatched:false 不谎报，成功记 true
R4=$(MKWT2 "重派失败" r2m4)
POST tester@proj --event dispatched --task "$R4" --target "$PROJ" --child tester --run "raw/dispatches/d-r2.log" >/dev/null
OUT=$(AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=0 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=bogus-runtime-xyz \
  bash "$AGORA_HOME/scripts/poll.sh" 2>/dev/null)
echo "$OUT" | python3 -c 'import json,sys
d = json.load(sys.stdin); tid = sys.argv[1]
sys.exit(0 if any(e.get("task") == tid and e.get("redispatched") is False for e in d.get("orphan_diag", [])) else 1)' "$R4" \
  && ok "R2 重派失败记 redispatched:false（B-M4）" || fail "R2 重派失败未回报（B-M4）"
R5=$(MKWT2 "重派成功" r3m5)
POST tester@proj --event dispatched --task "$R5" --target "$PROJ" --child tester --run "raw/dispatches/d-r3.log" >/dev/null
OUT=$(AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=0 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=99 AGORA_RUNTIME=echo \
  bash "$AGORA_HOME/scripts/poll.sh" 2>/dev/null)
echo "$OUT" | python3 -c 'import json,sys
d = json.load(sys.stdin); tid = sys.argv[1]
sys.exit(0 if any(e.get("task") == tid and e.get("redispatched") is True for e in d.get("orphan_diag", [])) else 1)' "$R5" \
  && ok "R2 重派成功记 redispatched:true（B-M4）" || fail "R2 重派成功未记 true（B-M4）"
# R3 (B-M7): GC worktree remove 失败可见＋gcst 保留（chmod 500 父目录迫删失败→复原→重试删净）
R7=$(MKWT2 "gc删失败" r4m7); WR7=$(ls -d "$T"/proj__wt-${R7}__*)
echo m > "$WR7/mf"; git -C "$WR7" add -A; git -C "$WR7" -c user.name=t -c user.email=t@l commit -qm r3
POST tester@proj --event claimed --task "$R7" >/dev/null
POST tester@proj --event done --task "$R7" --commit HEAD --evidence ok >/dev/null
git -C "$PROJ" merge -q --ff-only "wt/$R7" 2>/dev/null
tick "$R7"; POST tester@proj --event merged --task "$R7" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null
untick "$R7"
chmod 500 "$T"
OUT=$(AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=0 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo \
  bash "$AGORA_HOME/scripts/poll.sh" 2>/dev/null)
chmod 755 "$T"   # 复原（rm -rf 清场依赖）
[ -d "$WR7" ] && ok "R3 删失败树保留" || fail "R3 删失败树被删"
echo "$OUT" | python3 -c 'import json,sys
d = json.load(sys.stdin); tid = sys.argv[1]
sys.exit(0 if any(e.get("task") == tid for e in d.get("wt_remove_failed", [])) else 1)' "$R7" \
  && ok "R3 wt_remove_failed 可见（B-M7）" || fail "R3 GC 删失败不可见（B-M7）"
POLLT >/dev/null   # 权限复原：gcst 保留→下轮重试删净
[ ! -d "$WR7" ] && ok "R3 gcst 保留下轮重试删净（B-M7）" || fail "R3 gcst 丢失未重试"
# R4 (E): doctor.sh 全部 open(encoding=utf-8) 带 errors=replace（与 poll/dispatch 同口径）
BAD_OPEN=$(grep 'encoding="utf-8"' "$PKG/scripts/doctor.sh" | grep -cv 'errors="replace"' || true)
[ "$BAD_OPEN" -eq 0 ] && ok "R4 doctor open 全带 errors=replace（UTF-8 容错）" || fail "R4 doctor open 缺 errors=replace（$BAD_OPEN 处）"

echo "===== 隐藏分片可见性——点开头项目名（生产行政 hotfix，gt-3ea2 波次根因） ====="
PX="$T/.projx"; mkdir -p "$PX"; (cd "$PX" && git init -q . && echo x>p && git add -A && git -c user.name=t -c user.email=t@l commit -qm i)
H1=$(TID "$(TITLE="点仓任务" VERIFY=true PROJECT_DIR="$PX" WT=1 IDEM=dot1 TC)")
bash "$AGORA_HOME/scripts/post.sh" --actor tester@projx --project .projx --event claimed --task "$H1" >/dev/null
grep -q "^- $H1" "$AGORA_HOME/board/in-progress.md" 2>/dev/null && ok "点仓 claimed 上板（derive 可见）" || fail "点仓 claimed 上板（derive 盲）"
bash "$AGORA_HOME/scripts/post.sh" --actor tester@projx --project .projx --event done --task "$H1" --commit HEAD --evidence ok >/dev/null
grep -q "^- $H1" "$AGORA_HOME/board/in-progress.md" 2>/dev/null && fail "点仓 done 后离板" || ok "点仓 done 后离板"
git -C "$PX" merge -q --ff-only "wt/$H1" 2>/dev/null
tick "$H1"
bash "$AGORA_HOME/scripts/post.sh" --actor tester@projx --project .projx --event merged --task "$H1" --commit "$(git -C "$PX" rev-parse HEAD)" --branch "$(git -C "$PX" symbolic-ref --short HEAD)" >/dev/null
untick "$H1"
OUT=$(AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 bash "$AGORA_HOME/scripts/poll.sh" 2>/dev/null)
echo "$OUT" | python3 -c 'import json,sys
d = json.load(sys.stdin); tid = sys.argv[1]
sys.exit(1 if any(e.get("task") == tid for e in d.get("merge_wait_diag", [])) else 0)' "$H1" \
  && ok "点仓 merged 后梯子安静（poll 可见 merged）" || fail "点仓 merged 仍被诊断（poll 盲）"

echo "===== L2 API 通道批（T1 适配器契约 stub 测 / T2 API 派生 / T3 ack 注入 / T4 注入式续跑 / T5 在场 API 化） ====="
# stub：假 opencode CLI 进 PATH（只钉 L2 契约字段，形状照 v2.1.2 openapi 实证——{"data":…} 包裹/outcome/time.idle/location.directory/delivery:"queue"）
FAKEDIR="$T/fakebin"; FAKE_HOME="$T/fakeapi"; mkdir -p "$FAKEDIR" "$FAKE_HOME"
cat > "$FAKEDIR/opencode" <<'STUB'
#!/usr/bin/env bash
# 假 opencode（smoke 专用）。FAKE_HOME/ctrl: none|health_fail|create_fail|inject_fail|status_dead
set -u
FH="${FAKE_HOME:?FAKE_HOME required}"
log() { printf '%s\n' "$*" >> "$FH/calls.log"; }
case "${1:-}" in
  --version) echo "opencode v2.1.2-fake"; exit 0 ;;
  run) log "run"; exit 0 ;;
  api) ;;
  *) echo "bad subcommand" >&2; exit 2 ;;
esac
shift
M=""; P=""; D=""
while [ $# -gt 0 ]; do case "$1" in
  -d) D="$2"; shift 2 ;;
  *) if [ -z "$M" ]; then M="$1"; elif [ -z "$P" ]; then P="$1"; fi; shift ;;
esac; done
log "api $M $P"
CTRL=$(cat "$FH/ctrl" 2>/dev/null || echo none)
case "$P" in
  */prompt)
    [ "$CTRL" = inject_fail ] && exit 1
    echo "$D" > "$FH/last_prompt.json"; log "PROMPT-OK $P"
    echo '{"data":{"id":"msg_1"}}'; exit 0 ;;
esac
case "$M $P" in
  "GET /api/info")
    [ "$CTRL" = health_fail ] && exit 1
    echo '{"data":{"version":"fake"}}'; exit 0 ;;
  "POST /api/session")
    [ "$CTRL" = create_fail ] && exit 1
    N=$(cat "$FH/seq" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FH/seq"
    echo "$D" > "$FH/create_body.json"
    echo "{\"data\":{\"id\":\"ses_fake$N\",\"time\":{\"created\":1},\"location\":{\"directory\":\"/x\"}}}"; exit 0 ;;
  "GET /api/session/active")
    echo '{"data":{"ses_act1":{"type":"running"}}}'; exit 0 ;;
  "GET /api/session/ses_act1")
    echo "{\"data\":{\"id\":\"ses_act1\",\"location\":{\"directory\":\"$(cat "$FH/active_dir" 2>/dev/null || echo /nonexist)\"}}}"; exit 0 ;;
esac
case "$P" in
  /api/session/ses_*)
    if [ "$CTRL" = status_dead ]; then
      echo '{"data":{"id":"x","outcome":"failed","time":{"created":1}}}';
    else
      echo '{"data":{"id":"x","outcome":"succeeded","time":{"created":1,"idle":2}}}';
    fi
    exit 0 ;;
esac
echo "not found" >&2; exit 1
STUB
chmod +x "$FAKEDIR/opencode"
FAKE() { PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" bash "$PKG/scripts/runtime/opencode.sh" "$@"; }
fake_reset() { printf '%s\n' "${1:-none}" > "$FAKE_HOME/ctrl"; : > "$FAKE_HOME/calls.log"; }
# S1a health 通/断
fake_reset none
if FAKE health >/dev/null 2>&1; then ok "S1a health 通 rc0"; else fail "S1a health 通"; fi
fake_reset health_fail
if FAKE health >/dev/null 2>&1; then fail "S1a health 断应 rc1"; else ok "S1a health 断 rc1"; fi
# S1b create：出 ses_ sid＋location.directory 钉真实目录
fake_reset none
S1SID=$(FAKE create "$PROJ" 2>/dev/null)
case "$S1SID" in ses_*) ok "S1b create 出 sid" ;; *) fail "S1b create 出 sid（got: $S1SID）" ;; esac
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["location"]["directory"]==sys.argv[2] else 1)' "$FAKE_HOME/create_body.json" "$PROJ" \
  && ok "S1b create 目录绑定" || fail "S1b create 目录绑定"
# S1c inject：rc0＋delivery:"queue"＋文本透传；断电 rc1
fake_reset none
if FAKE inject ses_fake9 "hello 队列" >/dev/null 2>&1; then ok "S1c inject rc0"; else fail "S1c inject rc0"; fi
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("delivery")=="queue" and d.get("text")=="hello 队列" else 1)' "$FAKE_HOME/last_prompt.json" \
  && ok "S1c inject queue 透传" || fail "S1c inject queue 透传"
fake_reset inject_fail
if FAKE inject ses_fake9 x >/dev/null 2>&1; then fail "S1c inject 断电应 rc1"; else ok "S1c inject 断电 rc1"; fi
# S1d alive：目录命中/不命中
echo "$PROJ" > "$FAKE_HOME/active_dir"; fake_reset none
if FAKE alive "$PROJ" >/dev/null 2>&1; then ok "S1d alive 命中 rc0"; else fail "S1d alive 命中"; fi
echo /nonexist > "$FAKE_HOME/active_dir"
if FAKE alive "$PROJ" >/dev/null 2>&1; then fail "S1d alive 不命中应 rc1"; else ok "S1d alive 不命中 rc1"; fi
# S1e status：idle/dead 归一
fake_reset none
[ "$(FAKE status ses_x 2>/dev/null)" = "idle" ] && ok "S1e status idle" || fail "S1e status idle"
fake_reset status_dead
[ "$(FAKE status ses_x 2>/dev/null)" = "dead" ] && ok "S1e status dead" || fail "S1e status dead"

# ---- T2: dispatch API 通道（sid 落账 / 回落零残留 / 凭据预写不变 / inject 败兜底） ----
POSTD() { PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" AGORA_MAX_SPAWN=99 AGORA_RUNTIME_API=1 bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" "$@"; }
T2A=$(TID "$(TITLE="API派生" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
fake_reset none
OUT=$(POSTD --task "$T2A")
echo "$OUT" | grep -q '"channel":"api"' && echo "$OUT" | grep -q '"session":"ses_' \
  && ok "S2a API 派生输出 channel+session" || fail "S2a API 派生输出（got: $OUT）"
LEV "$T2A" dispatched | grep -q 'session:ses_' && ok "S2a sid 落账 session:ses_*" || fail "S2a sid 落账"
T2B=$(TID "$(TITLE="API回落" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
fake_reset health_fail
OUT=$(POSTD --task "$T2B")
echo "$OUT" | grep -q '"channel":"api"' && fail "S2b health_fail 未回落 run" || ok "S2b health_fail 回落 run"
[ "$(LEV "$T2B" dispatched | wc -l)" = 1 ] && ! LEV "$T2B" dispatched | grep -q 'session:' \
  && ok "S2b 回落零残留（恰一条 dispatched 无 session:）" || fail "S2b 回落残留"
RUN2B=$(echo "$OUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')
grep -q "^EXIT:1=0" "$AGORA_HOME/$RUN2B" 2>/dev/null && ok "S2b run 通道 EXIT:1=0" || fail "S2b run EXIT 缺失"
T2C=$(MKWT2 "API凭据" t2c); WR2C=$(ls -d "$T"/proj__wt-${T2C}__*)
fake_reset none
POSTD --task "$T2C" >/dev/null
[ -f "$WR2C/.omo/agora-delegation/$T2C.md" ] && ok "S2c wt 凭据预写不变（API 通道）" || fail "S2c wt 凭据预写"
T2D=$(TID "$(TITLE="API注入败" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
fake_reset inject_fail
OUT=$(POSTD --task "$T2D")
[ "$(LEV "$T2D" diagnosed | wc -l)" -ge 2 ] && ok "S2d inject 败 diagnosed 响" || fail "S2d inject 败无 diagnosed"
LEV "$T2D" dispatched | grep -q 'session:ses_' && ok "S2d session 保留（D3 已知极限）" || fail "S2d session 丢失"
echo "$OUT" | grep -q '"mode":"spawned"' && RUN2D=$(echo "$OUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p') \
  && grep -q "^EXIT:1=0" "$AGORA_HOME/$RUN2D" 2>/dev/null && ok "S2d run 兜底成功" || fail "S2d run 兜底（got: $OUT）"

# ---- T3: ack→注入（session: 任务 ack 即 inject，best-effort＋sid 幂等） ----
POSTI() { PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" bash "$AGORA_HOME/scripts/post.sh" --actor "$1" --project "${1#*@}" "${@:2}"; }
T3A=$(TID "$(TITLE="ack注入" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T3A" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t3a.log" --session ses_t3a >/dev/null
fake_reset none
POSTI tester@proj --event ack --task "$T3A" --body "plan ack 放行" >/dev/null
grep -q "PROMPT-OK" "$FAKE_HOME/calls.log" 2>/dev/null \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("text")=="ack 已落账，继续" and d.get("delivery")=="queue" else 1)' "$FAKE_HOME/last_prompt.json" \
  && ok "S3a ack 触发 inject（ack 已落账，继续 / queue）" || fail "S3a ack 未触发 inject"
# S3b: inject 失败 best-effort 不阻塞
T3B=$(TID "$(TITLE="ack注入败" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T3B" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t3b.log" --session ses_t3b >/dev/null
fake_reset inject_fail
OUT=$(POSTI tester@proj --event ack --task "$T3B" --body "ack b")
[ $? -eq 0 ] && echo "$OUT" | grep -q "inject_failed" && ok "S3b inject 败仅 derived 注记不阻塞" || fail "S3b inject 败阻断了 ack（got: $OUT）"
# S3c: 同 sid 二次 ack 幂等不重注
fake_reset none
OUT=$(POSTI tester@proj --event ack --task "$T3A" --body "二次 ack")
echo "$OUT" | grep -q "inject_dedup" && [ "$(grep -c "PROMPT-OK" "$FAKE_HOME/calls.log" 2>/dev/null)" = 0 ] \
  && ok "S3c 同 sid 幂等去重（inject_dedup＋零重注）" || fail "S3c 幂等失效（got: $OUT）"
# S3d: 开关关→零 inject
T3D=$(TID "$(TITLE="ack注入关" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T3D" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t3d.log" --session ses_t3d >/dev/null
fake_reset none
AGORA_RUNTIME_API=0 POSTI tester@proj --event ack --task "$T3D" --body "开关关" >/dev/null
CNT=$(grep -c "PROMPT-OK" "$FAKE_HOME/calls.log" 2>/dev/null || true); CNT=${CNT:-0}
[ "$CNT" = 0 ] && ok "S3d 开关关零 inject" || fail "S3d 开关关仍注入（count=$CNT）"

# ---- T4: poll done-unmerged 注入式续跑（session: 优先 inject，wt_host 判则，失败/缺回落重派） ----
# 清场前奏：前序段遗留 done-open wt 任务（①段重派梯子等）在每轮 poll 永续重燃 ②c——全部 cancelled 终态出集
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; done_open = {}
for f in sorted(glob.glob(f"{home}/log/*/*.md")):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError: continue
    for line in lines:
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        t = m.group(1)
        if "event:done" in line: done_open[t] = True
        elif any(f"event:{e}" in line for e in ("merged", "cancelled", "reopened")): done_open[t] = False
print(" ".join(t for t, v in done_open.items() if v))
PYEOF
); do POST tester@proj --event cancelled --task "$_t" >/dev/null 2>&1; done
T4U=$(MKWT2 "续跑上游" t4u); T4D=$(MKWT2 "续跑下游" t4d)
W4D=$(ls -d "$T"/proj__wt-${T4D}__*); echo t > "$W4D/tfile"; git -C "$W4D" add -A; git -C "$W4D" -c user.name=t -c user.email=t@l commit -qm t4d   # gt-99af：真未合并态（夹具此前借分支==HEAD 已并形态，会被 git 层短路吞掉）
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4U" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4u.log" --session ses_up1 >/dev/null
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4D" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4d.log" --dispatcher-task "$T4U" >/dev/null
POST tester@proj --event done --task "$T4D" --commit HEAD --evidence ok >/dev/null
POLL4() { PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 \
  AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=99 AGORA_REDISPATCH_MAX=99 AGORA_RUNTIME=opencode AGORA_RUNTIME_API=1 bash "$AGORA_HOME/scripts/poll.sh" 2>/dev/null; }
fake_reset none
OUT=$(POLL4)
echo "$OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); tid=sys.argv[1]
sys.exit(0 if any(e.get("upstream")==tid and e.get("mode")=="injected" for e in d.get("redispatched",[])) else 1)' "$T4U" \
  && ok "S4a 注入式续跑 mode:injected" || fail "S4a 未注入续跑（got: $OUT）"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "恢复性重派" in d.get("text","") and d.get("delivery")=="queue" else 1)' "$FAKE_HOME/last_prompt.json" \
  && ok "S4a 续跑 prompt 透传" || fail "S4a 续跑 prompt 缺失"
[ "$(LEV "$T4U" dispatched | wc -l)" = 1 ] && ok "S4a 注入不产生新 dispatched" || fail "S4a 注入产生了新 dispatched"
fake_reset inject_fail
OUT=$(POLL4)
echo "$OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); tid=sys.argv[1]
sys.exit(0 if any(e.get("upstream")==tid and e.get("mode")=="spawned" for e in d.get("redispatched",[])) else 1)' "$T4U" \
  && ok "S4b inject 失败回落重派" || fail "S4b 失败未回落（got: $OUT）"
[ "$(LEV "$T4U" dispatched | wc -l)" = 2 ] && ok "S4b 回落产生新 dispatched" || fail "S4b 回落无新 dispatched"
# S4c: 上游无 session → 直接重派（既有行为）
T4U2=$(MKWT2 "无session上游" t4c); T4D2=$(MKWT2 "无session下游" t4c2)
W4D2=$(ls -d "$T"/proj__wt-${T4D2}__*); echo u > "$W4D2/ufile"; git -C "$W4D2" add -A; git -C "$W4D2" -c user.name=t -c user.email=t@l commit -qm t4d2   # 真未合并态（gt-99af）
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4U2" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4u2.log" >/dev/null
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4D2" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4d2.log" --dispatcher-task "$T4U2" >/dev/null
POST tester@proj --event done --task "$T4D2" --commit HEAD --evidence ok >/dev/null
fake_reset none
OUT=$(PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 \
  AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=99 AGORA_REDISPATCH_MAX=99 AGORA_RUNTIME=echo bash "$AGORA_HOME/scripts/poll.sh" 2>/dev/null)
echo "$OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); tid=sys.argv[1]
sys.exit(0 if any(e.get("upstream")==tid and e.get("mode")=="spawned" for e in d.get("redispatched",[])) else 1)' "$T4U2" \
  && ok "S4c 无 session 直接重派" || fail "S4c 无 session 行为回归（got: $OUT）"
# S4d: 上游 wt_host≠本机 → 不注入（跨机判则）回落重派（独立对子——mw 状态按任务共享，勿复用 S4a/b 的）
T4U3=$(MKWT2 "跨机上游" t4x); T4D3=$(MKWT2 "跨机下游" t4y)
W4D3=$(ls -d "$T"/proj__wt-${T4D3}__*); echo v > "$W4D3/vfile"; git -C "$W4D3" add -A; git -C "$W4D3" -c user.name=t -c user.email=t@l commit -qm t4d3   # 真未合并态（gt-99af）
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4U3" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4u3.log" --session ses_up3 >/dev/null
bash "$AGORA_HOME/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4D3" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4d3.log" --dispatcher-task "$T4U3" >/dev/null
POST tester@proj --event done --task "$T4D3" --commit HEAD --evidence ok >/dev/null
sed -i "s/^wt_host: .*/wt_host: other-host/" "$AGORA_HOME/wiki/tasks/$T4U3.md"
fake_reset none
OUT=$(POLL4)
echo "$OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); tid=sys.argv[1]
sys.exit(0 if any(e.get("upstream")==tid and e.get("mode")=="spawned" for e in d.get("redispatched",[])) else 1)' "$T4U3" \
  && ! grep -q "session/ses_up3/prompt" "$FAKE_HOME/calls.log" 2>/dev/null \
  && ok "S4d 跨机 wt_host 不注入回落重派" || fail "S4d 跨机判则失效（got: $OUT）"

# ---- T5: 在场 API 化（alive 优先，sessions.map 降回退；wt 无条件 spawn 豁免不动） ----
T5A=$(TID "$(TITLE="alive在场" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
echo "$PROJ" > "$FAKE_HOME/active_dir"; fake_reset none
OUT=$(POSTD --task "$T5A")
echo "$OUT" | grep -q '"mode":"notified"' && ok "S5a alive 命中→notified" || fail "S5a alive 未命中（got: $OUT）"
[ -z "$(LEV "$T5A" dispatched)" ] && ok "S5a notified 零 dispatched 落账" || fail "S5a notified 却落了 dispatched"
T5B=$(TID "$(TITLE="alive缺席" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
echo /nonexist > "$FAKE_HOME/active_dir"
OUT=$(POSTD --task "$T5B")
echo "$OUT" | grep -q '"mode":"spawned"' && ok "S5b alive 缺席→正常 spawn" || fail "S5b alive 缺席未 spawn（got: $OUT）"
T5C=$(MKWT2 "wt在场" t5c); WR5C=$(ls -d "$T"/proj__wt-${T5C}__*)
echo "$PROJ" > "$FAKE_HOME/active_dir"
OUT=$(POSTD --task "$T5C")
echo "$OUT" | grep -q '"mode":"spawned"' && [ -f "$WR5C/.omo/agora-delegation/$T5C.md" ] \
  && ok "S5c wt 任务 alive 命中仍无条件 spawn" || fail "S5c wt 在场豁免失效（got: $OUT）"
T5D=$(TID "$(TITLE="旧路在场" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
printf '%s tester ses_legacy %s\n' "$(hostname)" "$(date +%s)" >> "$AGORA_HOME/scripts/sessions.map"
OUT=$(AGORA_MAX_SPAWN=99 AGORA_RUNTIME_API=0 AGORA_RUNTIME=opencode bash "$AGORA_HOME/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$T5D")
echo "$OUT" | grep -q '"mode":"notified"' && ok "S5d 开关关走 sessions.map 旧路" || fail "S5d 旧路失效（got: $OUT）"
sed -i "\|$(hostname) tester ses_legacy|d" "$AGORA_HOME/scripts/sessions.map"   # 清场：勿污染后续

# ---- T6: done_open 状态机同日跨分片乱序——按 ts 序重放（gt-db15，gt-caf3 last 同源收口） ----
# 构造：字典序前分片放「晚」闭合事件(T2)、字典序后分片放「早」done(T1)——文件序重放把 done_open 误置 True
OOD1=gt-dead1   # merged 乱序：诊断处另有 has 集守卫遮蔽（poll.sh "merged" in has），本断言锁定不误诊
OOD2=gt-beef2   # cancelled 乱序：守卫只查 merged，现状必误诊（红）
OOD_TS1="2026-10-23T09:00:00+08:00"; OOD_TS2="2026-10-23T10:00:00+08:00"
OOD_A="$AGORA_HOME/log/$(date +%F)/aaa-ood.md"; OOD_B="$AGORA_HOME/log/$(date +%F)/zzz-ood.md"
mkdir -p "$(dirname "$OOD_A")" "$(dirname "$OOD_B")"   # 跨午夜翻牌双求值可能落不同日期目录，先建防 cat >> 静默失败
cat >> "$OOD_A" <<EOF
- seq:99001 | ts:$OOD_TS2 | actor:tester@proj | event:merged | idem:ood1m | seen:proj@0 | task:$OOD1 | commit:aaa | evidence:ok
- seq:99002 | ts:$OOD_TS2 | actor:tester@proj | event:cancelled | idem:ood2c | seen:proj@0 | task:$OOD2 | reason:x
EOF
cat >> "$OOD_B" <<EOF
- seq:99003 | ts:$OOD_TS1 | actor:tester@proj | event:done | idem:ood1d | seen:proj@0 | task:$OOD1 | commit:bbb | evidence:ok
- seq:99004 | ts:$OOD_TS1 | actor:tester@proj | event:done | idem:ood2d | seen:proj@0 | task:$OOD2 | commit:ccc | evidence:ok
EOF
for _ood in "$OOD1" "$OOD2"; do printf -- '---\ndispatcher: tester@proj\nwt_dir: /nonexistent/%s\n---\n\n占位任务页（wt_dir 不存在：GC isdir 守卫跳过）\n' "$_ood" > "$AGORA_HOME/wiki/tasks/$_ood.md"; done
POLLT >/dev/null
[ -z "$(LEV "$OOD1" diagnosed)" ] && ok "T6 merged 乱序不误诊 done-unmerged" || fail "T6 merged 乱序误诊（got: $(LEV "$OOD1" diagnosed | head -1)）"
[ -z "$(LEV "$OOD2" diagnosed)" ] && ok "T6 cancelled 乱序不误诊 done-unmerged" || fail "T6 cancelled 乱序误诊（got: $(LEV "$OOD2" diagnosed | head -1)）"

echo
echo "===== 结果: $PASS 通过, $FAIL 失败 ====="

rm -rf "$T"
[ "$FAIL" -eq 0 ]
