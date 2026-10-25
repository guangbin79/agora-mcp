#!/usr/bin/env bash
# smoke-test.sh —— agora-mcp 接口冒烟测试套件（自包含，不污染真实广场）
# 用法: bash tests/smoke-test.sh   （AGORA_PKG 缺省取包根目录）
# 覆盖：十四工具 + 事件全生命周期 + 幂等窗口 + 验证门 + 并发 + doctor + MCP 协议 + 双机同步 + HTTP 只读窗口
# 退出码：0 全绿；1 有 FAIL
set -u
PKG="${AGORA_PKG:-$(cd "$(dirname "$0")/.." && pwd)}"
T=$(mktemp -d)
export AGORA_HOME="$T/agora" AGORA_LOCK_WAIT=30 AGORA_VERIFY_TIMEOUT=30 AGORA_MAX_SPAWN_GLOBAL=9999   # gt-8c5b：总量闸默认 60 会被长跑累积活派发误触，套件级放大；分域/总量断言各自显式压
export AGORA_NOTIFY_BRIDGE=0   # gt-edc4：桥探活套件级默认关（防 fake 环境真拉死循环桥），探活段显式开
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
REG="$HOME/agora-smoke-reg-$$"; mkdir -p "$REG/auto" "$REG/late"   # gt-583b：/tmp 族拒自动注册，「可注册域」夹具迁出 mktemp（$HOME 子目录非 git 仓＝可注册）
trap 'rm -rf "$REG"' EXIT   # 评审 F2：中断亦不留残（真 $HOME 非系统清理域；末尾显式 rm 幂等保留）
REG_OK=$(python3 -c "import sys; sys.path.insert(0, '$PKG/scripts'); import agora_lib as l; print(1 if l.main_repo_of('$REG/auto') is None else 0)")   # 评审 F4：\$HOME=worktree 布局时 REG 归主不可注册，两用例降级 skip
mkdir -p "$AGORA_HOME/wiki/entities"
printf -- '---\nname: tester\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$PROJ" > "$AGORA_HOME/wiki/entities/tester.md"
printf -- '---\nname: rival\ndirs:\n  - %s\ncan_spawn: false\n---\n' "$PROJ2" > "$AGORA_HOME/wiki/entities/rival.md"
cd "$AGORA_HOME" && git add -A && AGORA_MECHANICAL=1 git commit -qm "entities"

POST() { local who="$1"; shift; bash "$PKG/scripts/post.sh" --actor "$who" --project "${who#*@}" "$@"; }
TC()   { bash "$PKG/scripts/task-create.sh"; }

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
H=$(TASK="$B" bash "$PKG/scripts/history.sh")
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
OUT=$(ACTOR=tester@proj TASK="$A" FILES="pytest-report.txt" NOTE="测试报告" PROJECT_DIR="$PROJ" bash "$PKG/scripts/attach.sh")
ATT_CMT=$(echo "$OUT" | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p')
[[ -n "$ATT_CMT" ]] && ok "attach 返回证据 commit" || fail "attach 返回证据 commit"
git -C "$PROJ" rev-parse -q --verify "refs/agora/evidence/$A" >/dev/null && ok "证据 ref 已建（orphan）" || fail "证据 ref 已建（orphan）"
[[ "$(git -C "$PROJ" rev-parse HEAD)" == "$HEAD_BEFORE" ]] && ok "工作区 HEAD 未动" || fail "工作区 HEAD 未动"
[[ "$(git -C "$PROJ" status --porcelain)" == "?? pytest-report.txt" ]] && ok "工作区/index 未污染" || fail "工作区/index 未污染"
git -C "$PROJ" show "$ATT_CMT:pytest-report.txt" | grep -q "12 passed" && ok "证据内容可取回" || fail "证据内容可取回"
cat "$AGORA_HOME"/log/*/*.md | grep "event:attached" | grep -q "@$ATT_CMT" && ok "attached 事件落账（URL@commit）" || fail "attached 事件落账（URL@commit）"
# 链式：第二次 attach 以第一次为父
echo "v2" > "$PROJ/pytest-report.txt"
OUT2=$(ACTOR=tester@proj TASK="$A" FILES="pytest-report.txt" PROJECT_DIR="$PROJ" bash "$PKG/scripts/attach.sh")
ATT_CMT2=$(echo "$OUT2" | sed -n 's/.*"commit":"\([0-9a-f]*\)".*/\1/p')
[[ "$(git -C "$PROJ" rev-parse "$ATT_CMT2^")" == "$ATT_CMT" ]] && ok "证据链式（二次 attach 以前次为父）" || fail "证据链式"
ACTOR=tester@proj TASK="$A" FILES="不存在.txt" PROJECT_DIR="$PROJ" bash "$PKG/scripts/attach.sh" 2>/dev/null
[[ $? -eq 2 ]] && ok "attach 缺文件被拒(rc=2)" || fail "attach 缺文件被拒(rc=2)"
ACTOR=tester@proj TASK="gt-zzzz" FILES="pytest-report.txt" PROJECT_DIR="$PROJ" bash "$PKG/scripts/attach.sh" 2>/dev/null
[[ $? -eq 5 ]] && ok "attach 未知任务被拒(rc=5)" || fail "attach 未知任务被拒(rc=5)"

echo "===== 并发写入 ====="
for i in $(seq 1 10); do POST tester@proj --event proposal --body "相同提案" >/dev/null 2>&1 & done; wait
for i in $(seq 1 10); do POST tester@proj --event proposal --body "提案$i" >/dev/null 2>&1 & done; wait
S=$(cat "$AGORA_HOME"/log/*/*.md | grep -c "相同提案"); D=$(cat "$AGORA_HOME"/log/*/*.md | grep -c "event:proposal")
[ "$S" -eq 1 ] && [ "$D" -eq 11 ] && ok "20 并发：相同×10→1，不同×10→10" || fail "20 并发（相同=$S 总=$D，want 1/11）"

echo "===== MCP 协议（十四工具 + 权限） ====="
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
assert len(tools) == 14, tools   # gt-b5e9 C一期：+agora_cancel/agora_redispatch
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
# 可自动注册目录：写工具直接可用且机械建页（2026-10-20 注册去人工闸；gt-583b 起可注册夹具须在 /tmp 族外）；不可注册目录（$HOME）仍拒
if [ "$REG_OK" = 1 ]; then
cd "$REG/auto" && python3 - "$PKG/server/agora_mcp.py" "$AGORA_HOME" <<'PYEOF' && ok "未注册目录自动注册后可写" || fail "未注册目录自动注册后可写"
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
# gt-583b：/tmp 族与 e2e/fixture 标记域拒自动注册——机械建页不得污染真实名册（dispatch 派生子会话在夹具 cwd 起 server 走同一 adjudicate 路径）
FIXT="$T/e2e/fixture-proj"; mkdir -p "$FIXT"
cd "$FIXT" && python3 - "$PKG/server/agora_mcp.py" "$AGORA_HOME" <<'PYEOF' && ok "fixture 域拒注册不污染名册" || fail "fixture 域拒注册不污染名册"
import json, subprocess, sys, os
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = rpc("tools/call", {"name":"agora_task_create","arguments":{"title":"x"}}, 2)
txt = json.loads(r["result"]["content"][0]["text"])
assert txt.get("code") == "NOT_REGISTERED", txt
ents_dir = os.path.join(sys.argv[2], "wiki", "entities")
assert not os.path.isfile(os.path.join(ents_dir, "fixture-proj.md")) \
    and not os.path.isfile(os.path.join(ents_dir, "e2e.md")), os.listdir(ents_dir)   # 页级断言（评审 F1：listdir 成员判断带 .md 恒真）
p.stdin.close()
PYEOF
else
ok "未注册目录自动注册后可写（skip：\$HOME=worktree 布局 REG 归主不可注册）"
fi
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
# 机器 B：clone 远端后 init（脚本单源在产品包——init 只补数据骨架，不再装脚本）
HOME2="$T/agora-b"; git clone -q "file://$REMOTE" "$HOME2" 2>/dev/null
AGORA_HOME="$HOME2" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
[[ ! -f "$HOME2/scripts/post.sh" ]] && ok "clone 后 init 不再装脚本（单源在产品包，gt-f6e4）" || fail "clone 后 init 仍装脚本（应已停装）"
# 非 SSH 远端被拒
AGORA_HOME="$T/agora-x" AGORA_PKG="$PKG" AGORA_REMOTE="https://github.com/x/y.git" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "https 远端被拒(rc=1)" || fail "https 远端被拒(rc=1)"
# 双机写入：B 发事件 → A 写前 pre-pull 应合并到 B 的事件
AGORA_HOME="$HOME2" bash "$PKG/scripts/post.sh" --actor rival@proj2 --project proj2 --event proposal --body "B机的提案" >/dev/null
POST tester@proj --event proposal --body "A机的提案" >/dev/null
cat "$AGORA_HOME"/log/*/*.md | grep -q "B机的提案" && ok "pre-pull 合并远端事件" || fail "pre-pull 合并远端事件"
git -C "$REMOTE" log --format=%s 2>/dev/null | grep -q "proposal" && ok "post 后 push 到远端" || fail "post 后 push 到远端"
# 读路径同步：B 再发一条，A 不写任何东西、只调 agora_sync 就应看到
AGORA_HOME="$HOME2" bash "$PKG/scripts/post.sh" --actor rival@proj2 --project proj2 --event proposal --body "B机第二提案" >/dev/null
SYNCO=$(bash "$PKG/scripts/sync.sh" pre)
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
printf '%s tester sess-1 2026-10-14\n' "foreign-host" > "$AGORA_HOME/sessions.map"
OUT=$(AGORA_RUNTIME=true bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$C" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' && ok "他机在场记录被忽略（仍派生）" || fail "他机在场记录被忽略（$OUT）"
rm -f "$AGORA_HOME"/raw/dispatches/*.live
printf '%s tester sess-1 2026-10-14\n' "$(hostname)" > "$AGORA_HOME/sessions.map"
OUT=$(AGORA_RUNTIME=true bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$C" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' && ok "本机交互注册（sessions.map）不算在场——直接派生（gt-0ed3）" || fail "本机交互注册应直接派生（$OUT）"
printf '# <机器名>  <agent名>  <opencode session id>  <登记时间>\n' > "$AGORA_HOME/sessions.map"
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
POLL_OUT=$(AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh")
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
POLL_OUT2=$(AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh")
echo "$POLL_OUT2" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert r['spawned']==[], r['spawned']
" && ok "邮件水位不重复派生" || fail "邮件水位不重复派生（$POLL_OUT2）"
# stalled 看门狗（活性 = 本机观察时钟）：先跑一次建立基线（不得误报），
# 再把 poll-state 的 since 拨回 1 小时前模拟停滞 → 应派生 diagnosed
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
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
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md 2>/dev/null | grep "event:diagnosed" | grep -q "stalled" \
  && ok "stalled 看门狗派生 diagnosed（本机观察时钟）" || fail "stalled 看门狗派生 diagnosed"
# cadence：刚诊断过的任务下轮不重复诊断（diagnosed 事件重建活性时钟）
W1=$(cat "$AGORA_HOME"/log/*/watchdog.md 2>/dev/null | grep -c "event:diagnosed")
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
W2=$(cat "$AGORA_HOME"/log/*/watchdog.md 2>/dev/null | grep -c "event:diagnosed")
[[ "$W1" == "$W2" ]] && ok "看门狗 cadence 不刷屏" || fail "看门狗 cadence 不刷屏（$W1→$W2）"

# 升级阶梯（ESCALATE_AFTER=1）：diagnosed → escalated →（AUTO_REOPEN=1）reopened 回池
OUT=$(TITLE="升级阶梯任务" TC); LADT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST tester@proj --event claimed --task "$LADT" >/dev/null
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null   # 建立活性基线
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
seed_old; AGORA_WATCHDOG_ESCALATE_AFTER=1 AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md | grep "event:diagnosed" | grep -q "$LADT" \
  || { fail "阶梯第 1 级 diagnosed"; }
# 每次 fire 后看门狗把跟踪条目标记为待采纳；先跑一轮采纳新事件复位时钟，再播种再 fire
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
seed_old; AGORA_WATCHDOG_ESCALATE_AFTER=1 AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md | grep "event:escalated" | grep -q "$LADT" \
  && ok "stalled 升级阶梯：escalated" || fail "stalled 升级阶梯：escalated"
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
seed_old; AGORA_WATCHDOG_ESCALATE_AFTER=1 AGORA_WATCHDOG_AUTO_REOPEN=1 AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
grep -q "^- $LADT" "$AGORA_HOME/board/todo.md" \
  && ok "watchdog 自动回池（reopened → todo）" || fail "watchdog 自动回池（reopened → todo）"

# blocked 泳道滞留档（gt-ef98）：blocked 入账后无自动出泳道路径 → 滞留超阈值 diagnosed＋mention 认领者与 dispatcher
OUT=$(TITLE="blocked滞留任务" TC); BLKT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST tester@proj --event claimed --task "$BLKT" >/dev/null
POST tester@proj --event blocked --task "$BLKT" --reason "等下级合并" >/dev/null
sed -i '0,/^id: /s//dispatcher: rival\nid: /' "$AGORA_HOME/wiki/tasks/$BLKT.md"   # 双目标 mention 需 dispatcher≠认领者
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null   # 基线：建立 blocked 观察时钟（未触发分支）
cat "$AGORA_HOME"/log/*/watchdog.md 2>/dev/null | grep "blocked 滞留" | grep -q "$BLKT" \
  && fail "blocked 基线误报（阈值内）" || ok "blocked 基线不误报（阈值内）"
seed_blk() { python3 - "$AGORA_HOME" "$BLKT" <<'PYEOF'
import json, sys, time
f = sys.argv[1] + "/.git/poll-state.json"
s = json.load(open(f))
e = s.get("_blocked_act", {}).get(sys.argv[2])
assert e, "无 blocked 跟踪条目"
e["since"] = time.time() - 5 * 3600
json.dump(s, open(f, "w"))
PYEOF
}
seed_blk; AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null   # 默认阈值 4h：拨 5h 触发
cat "$AGORA_HOME"/log/*/watchdog.md | grep "event:diagnosed" | grep "$BLKT" | grep -q "blocked 滞留" \
  && ok "blocked 滞留→diagnosed（默认 4h）" || fail "blocked 滞留→diagnosed"
cat "$AGORA_HOME"/log/*/watchdog.md | grep "event:diagnosed" | grep "$BLKT" | grep -q "mention:tester,rival" \
  && ok "blocked 诊断 mention 认领者＋dispatcher" || fail "blocked 诊断 mention 双目标缺失"
B1=$(cat "$AGORA_HOME"/log/*/watchdog.md | grep -c "blocked 滞留")
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null   # cadence：diagnosed 重建时钟不刷屏
B2=$(cat "$AGORA_HOME"/log/*/watchdog.md | grep -c "blocked 滞留")
[[ "$B1" == "$B2" ]] && ok "blocked cadence 不刷屏" || fail "blocked cadence 不刷屏（$B1→$B2）"
seed_blk; AGORA_WATCHDOG_ESCALATE_AFTER=1 AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md | grep "event:escalated" | grep "$BLKT" | grep -q "blocked 滞留升级" \
  && ok "blocked 升级阶梯：escalated" || fail "blocked 升级阶梯：escalated"
E1=$(cat "$AGORA_HOME"/log/*/watchdog.md | grep -c "$BLKT")
seed_blk; AGORA_WATCHDOG_ESCALATE_AFTER=1 AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null   # escalated 后保持安静
E2=$(cat "$AGORA_HOME"/log/*/watchdog.md | grep -c "$BLKT")
[[ "$E1" == "$E2" ]] && ok "blocked escalated 后保持安静" || fail "blocked escalated 后刷屏（$E1→$E2）"
POST tester@proj --event claimed --task "$BLKT" >/dev/null   # 同 owner re-claim：看板仍 blocked（derive-board no-op）→ 不出泳道
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
python3 - "$AGORA_HOME" "$BLKT" <<'PYEOF' && ok "claimed 不出泳道（与 derive-board 口径对齐）" || fail "claimed 误出泳道（看板仍 blocked 却失去看护）"
import json, sys
s = json.load(open(sys.argv[1] + "/.git/poll-state.json"))
assert sys.argv[2] in s.get("_blocked_act", {}), "claimed 误清跟踪表"
PYEOF
POST tester@proj --event reopened --task "$BLKT" >/dev/null   # 返工回池 → 看板出 blocked 泳道 → 跟踪复位
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
python3 - "$AGORA_HOME" "$BLKT" <<'PYEOF' && ok "blocked 后 reopened 复位出泳道" || fail "reopened 出泳道未清跟踪表"
import json, sys
s = json.load(open(sys.argv[1] + "/.git/poll-state.json"))
assert sys.argv[2] not in s.get("_blocked_act", {}), "出泳道未清跟踪表"
PYEOF

# .live 滞留：超期 → 回溯 dispatched 事件 mention 派单方（每个 did 只提醒一次）
OUT=$(TITLE="stale-live任务" TC); SLT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST tester@proj --event claimed --task "$SLT" >/dev/null
DID_TEST="d-staletest"
POST tester@proj --event dispatched --task "$SLT" --target "$PROJ" --child tester --run "raw/dispatches/$DID_TEST.log" >/dev/null
touch -d "1 hour ago" "$AGORA_HOME/raw/dispatches/$DID_TEST.live"
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
cat "$AGORA_HOME"/log/*/watchdog.md | grep "event:diagnosed" | grep -q ".live 滞留" \
  && ok "stale .live 提醒派单方" || fail "stale .live 提醒派单方"
N1=$(cat "$AGORA_HOME"/log/*/watchdog.md | grep -c ".live 滞留")
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
N2=$(cat "$AGORA_HOME"/log/*/watchdog.md | grep -c ".live 滞留")
[[ "$N1" == "$N2" ]] && ok "stale .live 不重复提醒" || fail "stale .live 不重复提醒（$N1→$N2）"
rm -f "$AGORA_HOME/raw/dispatches/$DID_TEST.live"   # gt-2153：清 stale 标记——teardown 轮询须零等待
# 只报告模式：SPAWN=0 → held 不派生
OUT=$(TITLE="poll只报告任务" TC); POLLT2=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
POST rival@proj2 --event progress --task "$POLLT2" --mention tester --body "再来一单" >/dev/null
POLL_OUT3=$(AGORA_POLL_SPAWN=0 AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh")
echo "$POLL_OUT3" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert any(h['task']=='$POLLT2' for h in r['held']), r
assert not any(s['task']=='$POLLT2' for s in r['spawned']), r
" && ok "POLL_SPAWN=0 只报告不派生" || fail "POLL_SPAWN=0 只报告不派生（$POLL_OUT3）"

echo "===== dispatch 注入防御 ====="
# 非法 task id（可能来自他机邮件摘要）→ 进 bash -c 前被拒
bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task 'gt-1;id' >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "dispatch 拒绝非法 task id" || fail "dispatch 拒绝非法 task id"
# prompt 中的命令替换绝不被执行（env 传数据 + 单引号脚本）
MARK="$T/pwned-$RANDOM"
AGORA_RUNTIME=true bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" \
  --task "$POLLT" --prompt '$(touch '"$MARK"')' >/dev/null 2>&1
[[ ! -e "$MARK" ]] && ok "dispatch prompt 注入不执行" || fail "dispatch prompt 注入不执行"
# 拉起形态：runtime 参数含 --auto（无人值守权限），且不含已随 opencode 2.0.32 移除的 --dir（echo stub 把参数回显进 dispatch 日志）
AGORA_RUNTIME=echo bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" \
  --task "$POLLT" >/dev/null 2>&1
sleep 1
RLOG=$(ls -t "$AGORA_HOME"/raw/dispatches/*.log | head -1)
grep -q -- '--auto' "$RLOG" && ! grep -q -- '--dir' "$RLOG" \
  && ok "dispatch 拉起参数含 --auto 且无 --dir" || fail "dispatch 拉起参数异常（$RLOG）"

# gt-8a3c：spawn 成功后 sessions.map 注册写入（通知桥唯一路由源，此前全链无写入方→通知静默根因）
SMT1=$(TITLE="smemap注册甲" TC); SMT1=$(echo "$SMT1" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
SMOUT=$(AGORA_RUNTIME=echo bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$SMT1")
SMCHILD=$(echo "$SMOUT" | sed -n 's/.*"child_actor":"\([^"@]*\)@.*/\1/p')
SMLOG=$(echo "$SMOUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')
SMSID1=$(sed -n 's/^SESSION:1=//p' "$AGORA_HOME/$SMLOG" 2>/dev/null | head -1)
grep -qE "^$(hostname) $SMCHILD $SMSID1 [0-9]{4}-[0-9]{2}-[0-9]{2}T" "$AGORA_HOME/sessions.map" \
  && ok "spawn 后 sessions.map 出现注册行（gt-8a3c）" || fail "spawn 后无 sessions.map 注册行（child=$SMCHILD sid=$SMSID1）"
SMT2=$(TITLE="smemap注册乙" TC); SMT2=$(echo "$SMT2" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
SMOUT2=$(AGORA_RUNTIME=echo bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$SMT2")
SMLOG2=$(echo "$SMOUT2" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')
SMSID2=$(sed -n 's/^SESSION:1=//p' "$AGORA_HOME/$SMLOG2" 2>/dev/null | head -1)
SMR1=$(grep -cE "^$(hostname) $SMCHILD $SMSID1 " "$AGORA_HOME/sessions.map" || true)
SMR2=$(grep -cE "^$(hostname) $SMCHILD $SMSID2 " "$AGORA_HOME/sessions.map" || true)
[ "$SMR1" -eq 1 ] && [ "$SMR2" -eq 1 ] && [ -z "$(sort "$AGORA_HOME/sessions.map" | uniq -d)" ] \
  && ok "重派换绑＋同 (host,entity,sid) 零重复行（gt-8a3c 幂等）" || fail "sid 行数 $SMR1/$SMR2 或有重复行（幂等失效）"

# gt-6bef：派发准入门——AGORA_SID 显式通道严检（不在册拒＋指引文案＋落账零残留）；空跳过（既有全部 dispatch 用例即该分支）
GTT=$(TITLE="准入门拒" TC); GTT=$(echo "$GTT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
GATE_OUT=$(AGORA_RUNTIME=true AGORA_SID=sess-unregistered bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$GTT" 2>&1)
echo "$GATE_OUT" | grep -q "REGISTER_REQUIRED" && echo "$GATE_OUT" | grep -q "register-session.sh" \
  && ok "不在册 dispatch 拒绝＋指引文案（gt-6bef）" || fail "不在册 dispatch 应拒＋指引（$GATE_OUT）"
cat "$AGORA_HOME"/log/*/*.md 2>/dev/null | grep "task:$GTT" | grep -q "event:dispatched" \
  && fail "准入拒绝应落账零残留（$GTT 有 dispatched）" || ok "准入拒绝落账零残留（gt-6bef）"
bash "$PKG/scripts/register-session.sh" --sid sess-gate-ok --entity tester >/dev/null
GATE_OUT2=$(AGORA_RUNTIME=true AGORA_SID=sess-gate-ok bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$GTT" 2>&1)
echo "$GATE_OUT2" | grep -q '"mode":"spawned"' && ok "在册 sid 准入放行（gt-6bef）" || fail "在册 sid 应放行（$GATE_OUT2）"
rm -f "$AGORA_HOME"/raw/dispatches/*.live
# gt-6bef：掉册自愈——删行后 upsert 补登，幂等单行
grep -v "^$(hostname) tester sess-gate-ok " "$AGORA_HOME/sessions.map" > "$AGORA_HOME/sessions.map.tmp" && mv "$AGORA_HOME/sessions.map.tmp" "$AGORA_HOME/sessions.map"
bash "$PKG/scripts/register-session.sh" --sid sess-gate-ok --entity tester >/dev/null
bash "$PKG/scripts/register-session.sh" --sid sess-gate-ok --entity tester >/dev/null
RG1=$(grep -cE "^$(hostname) tester sess-gate-ok " "$AGORA_HOME/sessions.map" || true)
[ "$RG1" = "1" ] && ok "掉册自愈补登记＋幂等单行（gt-6bef）" || fail "掉册自愈行数 $RG1（应 1）"
# gt-6bef：BOOT 文案——轮询语义（双通道查 ack＋心跳＋自放行）取代死锁文案；终态 mention dispatcher
grep -q "即开工不等 ack" "$PKG/scripts/dispatch.sh" \
  && fail "BOOT 死锁文案残留（即开工不等 ack）" || ok "BOOT 死锁文案已移除（gt-6bef）"
grep -q "轮询等 ack" "$PKG/scripts/dispatch.sh" && grep -q "agora_check_mail" "$PKG/scripts/dispatch.sh" && grep -q "自放行" "$PKG/scripts/dispatch.sh" \
  && ok "BOOT 轮询语义文案（双通道＋心跳＋自放行）" || fail "BOOT 轮询文案缺失"
grep -q "mention 任务页 dispatcher" "$PKG/scripts/dispatch.sh" \
  && ok "BOOT 终态 mention dispatcher 文案（done 推送闭环）" || fail "BOOT 终态 mention 文案缺失"

# gt-e96d：gt-2508 R1 origin 面 6 warning 加固尾巴——逐 warning 一断言
# ①：--sid/--entity 行伪造字符拒——换行 sid 拒 rc2＋sessions.map 零注入
SM_LINES0=$(wc -l < "$AGORA_HOME/sessions.map")
VOUT=$(bash "$PKG/scripts/register-session.sh" --sid "$(printf 'evil\nforeign tester injected')" --entity tester 2>&1); VRC=$?
VOUT2=$(bash "$PKG/scripts/register-session.sh" --sid sess-e96d-ent --entity "$(printf 'bad\nentity')" 2>&1); VRC2=$?
[ "$VRC" = 2 ] && [ "$VRC2" = 2 ] && grep -q "VALIDATION_FAILED" <<<"$VOUT" \
  && [ "$(wc -l < "$AGORA_HOME/sessions.map")" = "$SM_LINES0" ] && ! grep -q "injected" "$AGORA_HOME/sessions.map" \
  && ok "①sid/entity 行伪造字符拒＋map 零注入（gt-e96d）" || fail "①行伪造校验失效（rc=$VRC/$VRC2 $VOUT $VOUT2）"
# ②：TTL_H=0 分叉统一——在册即新（与 poll 0=不清同义）；缺省 TTL 同夹具仍拒
bash "$PKG/scripts/register-session.sh" --sid sess-ttl0 --entity tester >/dev/null
OLD_TS2=$(date -d "-25 hours" -Iseconds)
sed -i "s|^\($(hostname) tester sess-ttl0 \).*|\1$OLD_TS2|" "$AGORA_HOME/sessions.map"
! bash "$PKG/scripts/register-session.sh" --sid sess-ttl0 --entity tester --check-only >/dev/null 2>&1 \
  && ok "②缺省 TTL 超龄仍拒（分叉基线不弱化）" || fail "②缺省 TTL 应拒超龄（25h 前 ts）"
T0OUT=$(AGORA_SESSION_TTL_H=0 bash "$PKG/scripts/register-session.sh" --sid sess-ttl0 --entity tester --check-only 2>&1); T0RC=$?
[ "$T0RC" = 0 ] && grep -q '"fresh": true' <<<"$T0OUT" \
  && ok "②TTL_H=0 在册即新——与 poll 0=不清同义（gt-e96d）" || fail "②TTL=0 应放行在册（rc=$T0RC $T0OUT）"
# ③：门吞错修复——内层 rc2 透传 GATE_ERROR，不再误报 REGISTER_REQUIRED
GTT2=$(TITLE="准入门透传" TC); GTT2=$(echo "$GTT2" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
GATE_OUT3=$(AGORA_RUNTIME=true AGORA_SID="$(printf 'bad\nsid')" bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$GTT2" 2>&1)
grep -q "GATE_ERROR" <<<"$GATE_OUT3" && grep -q "rc=2" <<<"$GATE_OUT3" && ! grep -q "REGISTER_REQUIRED" <<<"$GATE_OUT3" \
  && ok "③门内层 rc2→GATE_ERROR 非 REGISTER_REQUIRED 误报（gt-e96d）" || fail "③退出透传失效（$GATE_OUT3）"
cat "$AGORA_HOME"/log/*/*.md 2>/dev/null | grep "task:$GTT2" | grep -q "event:dispatched" \
  && fail "③门拒应落账零残留（$GTT2 有 dispatched）" || ok "③门拒零残留（gt-e96d）"
# ④：门成功 JSON 不再漏 stdout——dispatch stdout 纯单 JSON 可解析
GATE_OUT4=$(AGORA_RUNTIME=true AGORA_SID=sess-gate-ok bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$GTT2" 2>/dev/null)
echo "$GATE_OUT4" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); assert r["mode"]=="spawned", r' \
  && ok "④门放行 stdout 纯单 JSON（泄漏消除，gt-e96d）" || fail "④stdout 混入门 JSON（$GATE_OUT4）"
rm -f "$AGORA_HOME"/raw/dispatches/*.live
# gt-e96d 评审R1：locale 无关二次闸——C locale 无效字节/NBSP 拒绝且 map 零损伤（W2/W3 回归防复发）
RL_LINES0=$(wc -l < "$AGORA_HOME/sessions.map")
LC_ALL=C bash "$PKG/scripts/register-session.sh" --sid "$(printf 'a\xffb')" --entity tester >/dev/null 2>&1; R1RC=$?
RLOUT=$(bash "$PKG/scripts/register-session.sh" --sid "$(printf 'nb\xc2\xa0sp')" --entity tester 2>&1); R1RC2=$?
[ "$R1RC" = 2 ] && [ "$R1RC2" = 2 ] && grep -q "VALIDATION_FAILED" <<<"$RLOUT" \
  && [ "$(wc -l < "$AGORA_HOME/sessions.map")" = "$RL_LINES0" ] \
  && ok "R1 二次闸：无效字节/NBSP 拒绝＋map 零损伤（gt-e96d 评审环）" || fail "R1 二次闸失效（rc=$R1RC/$R1RC2 $RLOUT）"
# ⑤⑥：docs 漏迁清零＋硬编码机器路径清零（bc2609f 批二尾巴）——目标文件存在性先行（防断言空转化，ocr-R1）＋模式排除 ~/agora-mcp
E56=1
for _f in "$PKG/docs/Agora宣言-v0.19.md" "$PKG/docs/跨仓委托协议-v1.md"; do [[ -f "$_f" ]] || E56=0; done
[ "$E56" = 1 ] && ! grep -qE '~/agora([^_-]|$)' "$PKG/docs/Agora宣言-v0.19.md" "$PKG/docs/跨仓委托协议-v1.md" \
  && ok "⑤协议文档 ~/agora 漏迁清零（gt-e96d）" || fail "⑤协议文档 ~/agora 残留或检查目标缺失"
! grep -q "/home/guangbin" "$PKG/README.md" "$PKG/README.zh-CN.md" "$PKG/scripts/poll.sh" "$PKG/scripts/backup.sh" \
  && ok "⑥硬编码机器路径清零（gt-e96d）" || fail "⑥/home/guangbin 残留"

echo "===== poll 本地保洁 ====="
# sessions.map TTL：过期本机条目剔除；他机条目与新本机条目保留
H=$(hostname)
printf '# <机器名>  <agent名>  <opencode session id>  <登记时间>\n%s tester ses-old 2026-10-12T10:00:00+00:00\nforeign tester ses-f 2026-10-12T10:00:00+00:00\n%s tester ses-new %s\n' \
  "$H" "$H" "$(date -Iseconds)" > "$AGORA_HOME/sessions.map"
cd "$AGORA_HOME" && git add -A >/dev/null && AGORA_MECHANICAL=1 git commit -qm "seed sessions" >/dev/null
# inbox 归档：100 天前的邮件（文件名=纳秒时间戳）移入 archive/
mkdir -p "$AGORA_HOME/inbox/tester"
echo "- from:x | ts:y | ref:r | summary:ack none" > "$AGORA_HOME/inbox/tester/$(( $(date +%s) - 100*86400 ))000000000.md"
git add -A >/dev/null && AGORA_MECHANICAL=1 git commit -qm "seed old mail" >/dev/null
POLL_OUT4=$(AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh")
echo "$POLL_OUT4" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert r['sessions_reaped']==1, r
assert r['mails_archived']>=1, r
" && ok "poll 保洁计数（sessions+归档）" || fail "poll 保洁计数（$POLL_OUT4）"
! grep -q "ses-old" "$AGORA_HOME/sessions.map" \
  && grep -q "ses-new" "$AGORA_HOME/sessions.map" \
  && grep -q "ses-f" "$AGORA_HOME/sessions.map" \
  && ok "TTL 只清本机过期条目" || fail "TTL 只清本机过期条目"
ls "$AGORA_HOME/inbox/archive/tester/" 2>/dev/null | grep -q '\.md' \
  && ok "超期邮件入 archive" || fail "超期邮件入 archive"
git -C "$AGORA_HOME" status --porcelain -- sessions.map | grep -q . \
  && fail "保洁 chore 未入库（sessions.map 脏，评审 R1-F1 回归）" || ok "保洁 chore 已入库（sessions.map 净）"

# gt-8a3c：TTL 时间戳兼容——存量裸 epoch 条目可回收（此前 fromisoformat 抛→except pass 永生）；ISO 解析不受影响
printf '%s tester ses-epoch-old %s\n%s tester ses-iso-old 2026-10-12T10:00:00+00:00\n%s tester ses-epoch-new %s\nforeign tester ses-f 2026-10-12T10:00:00+00:00\n' \
  "$H" "$(( $(date +%s) - 48*3600 ))" "$H" "$H" "$(date +%s)" > "$AGORA_HOME/sessions.map"
cd "$AGORA_HOME" && git add -A >/dev/null && AGORA_MECHANICAL=1 git commit -qm "seed epoch sessions" >/dev/null
POLL_OUT5=$(AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh")
echo "$POLL_OUT5" | python3 -c "import json,sys; r=json.loads(sys.stdin.read()); assert r['sessions_reaped']==2, r" \
  && ok "TTL epoch 兼容：epoch 旧＋ISO 旧同回收（gt-8a3c）" || fail "TTL epoch 兼容计数（$POLL_OUT5）"
! grep -q "ses-epoch-old" "$AGORA_HOME/sessions.map" \
  && ! grep -q "ses-iso-old" "$AGORA_HOME/sessions.map" \
  && grep -q "ses-epoch-new" "$AGORA_HOME/sessions.map" \
  && grep -q "ses-f" "$AGORA_HOME/sessions.map" \
  && ok "TTL epoch 兼容回收明细（旧 epoch/ISO 清、新 epoch/他机留）" || fail "TTL epoch 兼容回收明细不符"

# gt-6bef：idle 刷新→TTL 顺延——register-session.sh upsert 原位刷 ts＝「保洁按最后刷新算」；
# 双行同种 25h 前（已过 24h 线），刷新行复活、未刷新行剔（长活主会话不超龄的活性语义）
OLD_TS=$(date -d "-25 hours" -Iseconds)
printf '%s tester ses-refresh %s\n%s tester ses-stale %s\n' "$H" "$OLD_TS" "$H" "$OLD_TS" > "$AGORA_HOME/sessions.map"
cd "$AGORA_HOME" && git add -A >/dev/null && AGORA_MECHANICAL=1 git commit -qm "seed ttl refresh" >/dev/null
bash "$PKG/scripts/register-session.sh" --sid ses-refresh --entity tester >/dev/null
POLL_OUT6=$(AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh")
echo "$POLL_OUT6" | python3 -c "import json,sys; r=json.loads(sys.stdin.read()); assert r['sessions_reaped']==1, r" \
  && ok "idle 刷新 TTL 顺延：刷新行活、未刷新行剔（gt-6bef）" || fail "刷新 TTL 计数（$POLL_OUT6）"
grep -q "ses-refresh" "$AGORA_HOME/sessions.map" && ! grep -q "ses-stale" "$AGORA_HOME/sessions.map" \
  && ok "刷新行原位保留、超龄行回收明细（gt-6bef）" || fail "刷新/回收明细不符"

echo "===== poll.sh notify 桥探活（gt-edc4） ====="
MARK="$T/bridge-mock.log"; : > "$MARK"
BPAT="probe-bridge-$RANDOM-x"   # 探针模式与本机真桥（notify-opencode.sh）互斥，防生产机真桥在场误判
BPOLL() { AGORA_NOTIFY_BRIDGE=1 AGORA_NOTIFY_BRIDGE_PAT="$BPAT" \
          AGORA_NOTIFY_BRIDGE_SPAWN="${1:-echo spawn >> \"$MARK\"}" \
          AGORA_POLL_SPAWN=0 AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" 2>/dev/null; }
# ① 桥缺席→一轮 poll 后拉起被调用（mock 断言）
BOUT1=$(BPOLL)
[ "$(wc -l < "$MARK")" -eq 1 ] && grep -q '"state": "spawned"' <<<"$BOUT1" \
  && ok "桥缺席→拉起被调用（mock）" || fail "桥缺席未拉起（lines=$(wc -l < "$MARK") $BOUT1）"
# ② 桥在场→零拉起（探针进程 cmdline 带模式串＝模拟活桥；`; exit` 复合命令禁 bash -c 隐式 exec——单命令会被 exec 优化替换镜像丢 cmdline）
bash -c 'sleep 300; exit' "$BPAT" & BPROBE=$!
sleep 0.2
pgrep -f "$BPAT" >/dev/null && ok "探针夹具自检可见" || fail "探针夹具不可见（pgrep 形态错）"
BT0=$(date +%s)
BOUT2=$(BPOLL)
kill "$BPROBE" 2>/dev/null
[ "$(wc -l < "$MARK")" -eq 1 ] && grep -q '"state": "alive"' <<<"$BOUT2" \
  && ok "桥在场→零拉起（幂等）" || fail "桥在场误拉起（lines=$(wc -l < "$MARK") pollDur=$(( $(date +%s) - BT0 ))s $BOUT2）"
# ③ 探活异常→只记 report，主流程照常完成（假 pgrep exit3）
mkdir -p "$T/fakebin"; printf '#!/bin/sh\nexit 3\n' > "$T/fakebin/pgrep"; chmod +x "$T/fakebin/pgrep"
BOUT3=$(PATH="$T/fakebin:$PATH" BPOLL); BRC3=$?
[ "$BRC3" -eq 0 ] && echo "$BOUT3" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["poll"]=="ok" and r["bridge"]["state"]=="probe_failed", r' \
  && ok "探活异常→主流程照常完成" || fail "探活异常阻断/未记账（rc=$BRC3 $BOUT3）"
# ④ 拉起失败→spawn_failed 记账且 report 仍可解析（err 走 text 解码路径，bytes 会炸 json.dumps）
BOUT4=$(BPOLL 'echo boom >&2; exit 7')
echo "$BOUT4" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["poll"]=="ok" and r["bridge"]["state"]=="spawn_failed" and r["bridge"]["err"]=="boom", r' \
  && ok "拉起失败→spawn_failed 记账不阻断" || fail "拉起失败污染/阻断 report（$BOUT4）"

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
SUP_OUT=$(AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh")
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
SUP2=$(AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh")
C2=$(md5sum "$SUP" | cut -d' ' -f1)
python3 - "$AGORA_HOME" <<'PYEOF' && GATE_OK=1 || GATE_OK=0
import json, sys, datetime
s = json.load(open(sys.argv[1] + "/.git/poll-state.json"))
sys.exit(0 if s.get("last_supervise_date") == datetime.date.today().isoformat() else 1)
PYEOF
[[ "$C1" == "$C2" ]] && ! grep -q "supervised" <<<"$SUP2" && [[ "${GATE_OK:-0}" -eq 1 ]] \
  && ok "同日不重复触发（页字节不变＋闸门翻今日）" || fail "同日幂等（C1=$C1 C2=$C2 GATE_OK=${GATE_OK:-0}）"
# 他人写被 owner 拒
bash "$PKG/scripts/wiki-write.sh" --actor rival@proj2 --path topics/supervision.md --mode replace </dev/null 2>/dev/null
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
printf -- '---\nowner: watchdog\ncreated: %s\n---\n%s' "$(date +%F)" "$OLD" | bash "$PKG/scripts/wiki-write.sh" --actor watchdog@$(hostname) --path topics/supervision.md --mode replace >/dev/null
GATE_RESET
AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" >/dev/null
grep -q "旧段 D-8 标记" "$SUP" && fail "7 天有界：最老段 D-8 未出局" || ok "7 天有界截断：最老段出局"
grep -q "旧段 D-2 标记" "$SUP" && ok "跨日翻新：次新旧段保留" || fail "跨日翻新：旧段 D-2 丢失"
[[ $(grep -c '^## ' "$SUP") -eq 7 ]] && ok "督报页恰 7 段" || fail "督报页段数 $(grep -c '^## ' "$SUP")≠7"
[[ "$(grep -m1 '^## ' "$SUP")" == "## $YDAY" ]] && ok "跨日翻新：昨日段置顶" || fail "跨日翻新：置顶段=$(grep -m1 '^## ' "$SUP")"

echo "===== 通知桥（notify-opencode.sh，规格 §8.1；传输=runtime CLI，无 HTTP 依赖） ====="
# 假 opencode CLI（本段专用）：只钉 prompt 端点。NB_HOME/ctrl: none|inject_fail
NBDIR="$T/nb-fakebin"; NB_HOME="$T/nb-fake"; mkdir -p "$NBDIR" "$NB_HOME"
cat > "$NBDIR/opencode" <<'NBSTUB'
#!/usr/bin/env bash
set -u
FH="${NB_HOME:?NB_HOME required}"
case "${1:-}" in
  api) ;;
  *) echo "bad subcommand" >&2; exit 2 ;;
esac
shift
M=""; P=""; D=""
while [ $# -gt 0 ]; do case "$1" in
  -d) D="$2"; shift 2 ;;
  *) if [ -z "$M" ]; then M="$1"; elif [ -z "$P" ]; then P="$1"; fi; shift ;;
esac; done
log() { printf '%s\n' "$*" >> "$FH/calls.log"; }
log "api $M $P"
case "$P" in
  */prompt)
    [ "$(cat "$FH/ctrl" 2>/dev/null || echo none)" = inject_fail ] && exit 1
    echo "$D" > "$FH/last_prompt.json"; log "PROMPT-OK $P"; exit 0 ;;
esac
echo "not found" >&2; exit 1
NBSTUB
chmod +x "$NBDIR/opencode"
nb_reset() { printf '%s\n' "${1:-none}" > "$NB_HOME/ctrl"; : > "$NB_HOME/calls.log"; }
nb_calls() { grep -c "PROMPT-OK" "$NB_HOME/calls.log" 2>/dev/null; }
NB() { PATH="$NBDIR:$PATH" NB_HOME="$NB_HOME" bash "$PKG/scripts/notify-opencode.sh" --once; }
printf '%s tester ses-test %s\n' "$(hostname)" "$(date -Iseconds)" >> "$AGORA_HOME/sessions.map"
nb_reset none
echo "- from:x | ts:y | ref:log/z.md:1 | summary:ack gt-0000" > "$AGORA_HOME/inbox/tester/$(date +%s%N).md"
NB
grep -q "PROMPT-OK /api/session/ses-test/prompt" "$NB_HOME/calls.log" \
  && ok "通知桥注入运行中会话（runtime CLI inject）" || fail "通知桥注入运行中会话"
grep -q '"delivery": "queue"' "$NB_HOME/last_prompt.json" && grep -q "agora_check_mail" "$NB_HOME/last_prompt.json" \
  && ok "通知桥 queue 投递 + 只递提醒" || fail "通知桥 queue 投递 + 只递提醒"
echo "- from:x | ts:y | ref:log/z.md:2 | summary:ack gt-0000" > "$AGORA_HOME/inbox/tester/$(date +%s%N)n2.md"
NB
# gt-236a：广播语义下同实体他新鲜行可投（双收），但 (entity,sid) 去抖必须保证同 sid 60s 内不重投
[[ $(grep -c 'PROMPT-OK /api/session/ses-test/prompt' "$NB_HOME/calls.log") == 1 ]] \
  && ok "通知桥 60s 去抖（(entity,sid) 粒度：同 sid 不重投）" || fail "通知桥 60s 去抖（(entity,sid) 粒度）"
# 回归哨兵：桥零消费 AGORA_OPENCODE_URL（死变量）；若传输回退 HTTP 且读它，死端口必败、断言必红
printf '%s tester2 ses-t2 %s\n' "$(hostname)" "$(date -Iseconds)" >> "$AGORA_HOME/sessions.map"
mkdir -p "$AGORA_HOME/inbox/tester2"
echo "- from:x | ts:y | ref:r2 | summary:ack gt-0000" > "$AGORA_HOME/inbox/tester2/$(date +%s%N).md"
AGORA_OPENCODE_URL="http://127.0.0.1:1" NB
grep -q "PROMPT-OK /api/session/ses-t2/prompt" "$NB_HOME/calls.log" \
  && ok "无 HTTP 服务时桥仍可注入（传输=opencode api CLI）" || fail "无 HTTP 服务时桥仍可注入"
# runtime 注入失败：静默跳过，不报错不退出非零
printf '%s loner ses-x %s\n' "$(hostname)" "$(date -Iseconds)" >> "$AGORA_HOME/sessions.map"
mkdir -p "$AGORA_HOME/inbox/loner"
echo "- from:x | ts:y | ref:r | summary:ack gt-0000" > "$AGORA_HOME/inbox/loner/$(date +%s%N).md"
nb_reset inject_fail
NB
[[ $? -eq 0 && $(nb_calls) == 0 ]] \
  && ok "通知桥注入失败静默跳过" || fail "通知桥注入失败静默跳过"
# 无 sessions.map 映射的实体：静默跳过
nb_reset none
mkdir -p "$AGORA_HOME/inbox/ghost2"
echo "- from:x | ts:y | ref:r | summary:ack gt-0000" > "$AGORA_HOME/inbox/ghost2/$(date +%s%N).md"
NB
[[ $(nb_calls) == 0 ]] \
  && ok "无映射实体静默跳过" || fail "无映射实体静默跳过"

# gt-893a：目标鉴别＋失败可见化。假 CLI 扩展 /api/session/<sid> 端点（who 探测），
# 夹具经 $NB_HOME/who.json 控制响应形态（全 sid 同形——单候选实体隔离测试）
cat > "$NBDIR/opencode" <<'NBSTUB'
#!/usr/bin/env bash
set -u
FH="${NB_HOME:?NB_HOME required}"
case "${1:-}" in
  api) ;;
  *) echo "bad subcommand" >&2; exit 2 ;;
esac
shift
M=""; P=""; D=""
while [ $# -gt 0 ]; do case "$1" in
  -d) D="$2"; shift 2 ;;
  *) if [ -z "$M" ]; then M="$1"; elif [ -z "$P" ]; then P="$1"; fi; shift ;;
esac; done
log() { printf '%s\n' "$*" >> "$FH/calls.log"; }
log "api $M $P"
case "$P" in
  */prompt)
    [ "$(cat "$FH/ctrl" 2>/dev/null || echo none)" = inject_fail ] && exit 1
    echo "$D" > "$FH/last_prompt.json"; log "PROMPT-OK $P"; exit 0 ;;
  /api/session/*)
    WSID=$(basename "${P#/api/session/}")   # gt-236a：per-sid who 覆盖优先，回落全局 who.json
    [ -f "$FH/who/$WSID.json" ] && { cat "$FH/who/$WSID.json"; exit 0; }
    [ -f "$FH/who.json" ] && { cat "$FH/who.json"; exit 0; }
    echo "not found" >&2; exit 1 ;;
esac
echo "not found" >&2; exit 1
NBSTUB
chmod +x "$NBDIR/opencode"
DBGLOG="$AGORA_HOME/.git/notify-debug.log"
map_add() { printf '%s %s %s %s\n' "$(hostname)" "$1" "$2" "2027-01-01T00:00:00+08:00" >> "$AGORA_HOME/sessions.map"; }
msg_add() { mkdir -p "$AGORA_HOME/inbox/$1"; echo "- from:x | ts:y | ref:r893 | summary:ack gt-0000" > "$AGORA_HOME/inbox/$1/$(date +%s%N)-$1.md"; }
# ① 同实体 worker 会话（dispatch 派生 title 前缀形态）：跳过且失败可见化——零注入＋落痕＋计数＋水位不推进
map_add worker1 ses-w1 "2027-01-01T00:00:00+08:00"
msg_add worker1
printf '%s' '{"data":{"title":"agora: gt-9999 派生worker"}}' > "$NB_HOME/who.json"
nb_reset none
NB
[[ $(nb_calls) == 0 && $(grep -c "entity=worker1 sid=ses-w1 skip delegated" "$DBGLOG") == 1 \
    && $(grep -c "entity=worker1 sid=- fail no-live-interactive" "$DBGLOG") == 1 \
    && "$(cat "$AGORA_HOME/.git/notify-wm/worker1.fail" 2>/dev/null)" == 1 \
    && ! -f "$AGORA_HOME/.git/notify-wm/worker1" ]] \
  && ok "worker 会话鉴别跳过＋失败落痕计数＋水位不推进（gt-893a①）" || fail "gt-893a① 鉴别/落痕/计数/水位不符"
# ② dead 顶层会话（outcome=failed，如崩溃旧 TUI）：同上跳过路径
map_add worker2 ses-d1 "2027-01-01T00:00:00+08:00"
msg_add worker2
printf '%s' '{"data":{"outcome":"failed"}}' > "$NB_HOME/who.json"
NB
[[ $(nb_calls) == 0 && $(grep -c "entity=worker2 sid=ses-d1 skip dead" "$DBGLOG") == 1 \
    && "$(cat "$AGORA_HOME/.git/notify-wm/worker2.fail" 2>/dev/null)" == 1 ]] \
  && ok "dead 会话跳过且失败可见化（gt-893a②）" || fail "gt-893a② dead 跳过/落痕不符"
# ③ interactive 顶层会话：注入成功＋计数清零＋水位推进
map_add worker3 ses-t3 "2027-01-01T00:00:00+08:00"
msg_add worker3
printf '%s' '{"data":{"title":"用户主会话"}}' > "$NB_HOME/who.json"
nb_reset none
NB
grep -q "PROMPT-OK /api/session/ses-t3/prompt" "$NB_HOME/calls.log" \
  && grep -q "entity=worker3 sid=ses-t3 inject-ok" "$DBGLOG" \
  && [[ ! -f "$AGORA_HOME/.git/notify-wm/worker3.fail" && -f "$AGORA_HOME/.git/notify-wm/worker3" ]] \
  && ok "interactive 会话注入成功＋计数清零＋水位推进（gt-893a③）" || fail "gt-893a③ 成功路径回归不符"
rm -f "$NB_HOME/who.json"
# ④ 消费侧白名单＋计数 sanitize（gt-893a 评审 C1/B1/R2-F1）：污染 sid（含裸点段 ..）不达 API、损坏 .fail 不杀进程
map_add worker4 "../../evil/sid"
map_add worker4 "zz*"
map_add worker4 ".."
msg_add worker4
mkdir -p "$AGORA_HOME/.git/notify-wm"; printf 'garbage' > "$AGORA_HOME/.git/notify-wm/worker4.fail"
nb_reset none
NB
[[ $? -eq 0 && "$(grep -cE "api/session/(\.\.|zz)" "$NB_HOME/calls.log")" == 0 \
    && $(grep -c "sid=\.\.,\.\./\.\./evil/sid,zz\* skip bad-sid" "$DBGLOG") == 1 \
    && $(grep -c "entity=worker4 sid=- fail no-live-interactive" "$DBGLOG") == 1 \
    && $(grep -c "entity=worker4 sid=- skip no-map-entry" "$DBGLOG") == 0 \
    && "$(cat "$AGORA_HOME/.git/notify-wm/worker4.fail")" == 1 ]] \
  && ok "污染 sid 白名单拦截＋损坏计数 sanitize（gt-893a④）" || fail "gt-893a④ 白名单/sanitize 不符"

# ─── gt-236a：两层路由＋角色订阅＋退出注销 ───
# 夹具：who/<sid>.json per-sid 鉴别（stub 已扩）；task-routing 行经产品脚本写入
RT_ADD() { bash "$PKG/scripts/task-routing.sh" upsert "$@" >/dev/null; }
map_add_ts() { printf '%s %s %s %s\n' "$(hostname)" "$1" "$2" "$3" >> "$AGORA_HOME/sessions.map"; }
map_add_role() { printf '%s %s %s %s %s\n' "$(hostname)" "$1" "$2" "2027-01-01T00:00:00+08:00" "$3" >> "$AGORA_HOME/sessions.map"; }
msg_add_ev() { mkdir -p "$AGORA_HOME/inbox/$1"; echo "- from:x | ts:y | ref:r236 | summary:$2 $3" > "$AGORA_HOME/inbox/$1/$(date +%s%N)-$1-$2.md"; }
rt_reset() { rm -f "$AGORA_HOME/.git/notify-wm/$1" "$AGORA_HOME/.git/notify-wm/$1".*.sent "$AGORA_HOME/.git/notify-wm/$1".fail; nb_reset none; }
mkdir -p "$NB_HOME/who"
# ① 双活会话同实体→双收（无 routing 行＝兜底广播全活行；任务页验收①）
map_add duo ses-du1 "2027-01-01T00:00:00+08:00"
map_add duo ses-du2 "2027-01-01T00:00:00+08:00"
printf '%s' '{"data":{"title":"交互A"}}' > "$NB_HOME/who/ses-du1.json"
printf '%s' '{"data":{"title":"交互B"}}' > "$NB_HOME/who/ses-du2.json"
msg_add_ev duo done gt-236d
rt_reset duo; NB
[[ $(nb_calls) == 2 ]] \
  && ok "双活会话同实体双收（兜底广播全活行，gt-236a①）" || fail "gt-236a① 双收不符（$(nb_calls)）"
# ② 死行不投：TTL 外 ts 行桥侧过滤（验收②）——全候选死→失败可见；保洁删行后→no-map-entry 静默
map_add_ts st1 ses-st "2020-01-01T00:00:00+08:00"
msg_add_ev st1 done gt-236d
rt_reset st1; NB
[[ $(nb_calls) == 0 && $(grep -c "sid=ses-st skip stale ts=2020" "$DBGLOG") == 1 \
    && "$(cat "$AGORA_HOME/.git/notify-wm/st1.fail")" == 1 && ! -f "$AGORA_HOME/.git/notify-wm/st1" ]] \
  && ok "TTL 外死行不投＋失败可见（gt-236a②）" || fail "gt-236a② 死行过滤不符"
grep -v " ses-st " "$AGORA_HOME/sessions.map" > "$AGORA_HOME/sessions.map.tmp" && mv "$AGORA_HOME/sessions.map.tmp" "$AGORA_HOME/sessions.map"
NB   # 原 mail 水位未推进（②失败路径）→ 自动重扫，行已清＝no-map-entry 静默且 wm 推进
[[ $(nb_calls) == 0 && $(grep -c "entity=st1 sid=- skip no-map-entry" "$DBGLOG") == 1 && -f "$AGORA_HOME/.git/notify-wm/st1" ]] \
  && ok "保洁清行后不投（no-map-entry 静默，gt-236a④）" || fail "gt-236a④ 清行后不符"
# ③ 角色过滤：worker 行不收终态信／dispatcher 行不收派发信（验收③）
map_add_role rf1 ses-wf worker
map_add_role rf2 ses-df dispatcher
printf '%s' '{"data":{"title":"worker行"}}' > "$NB_HOME/who/ses-wf.json"
printf '%s' '{"data":{"title":"disp行"}}' > "$NB_HOME/who/ses-df.json"
msg_add_ev rf1 done gt-236d
rt_reset rf1; NB
[[ $(nb_calls) == 0 && $(grep -c "sid=ses-wf skip role-filter ev=done role=worker" "$DBGLOG") == 1 \
    && -f "$AGORA_HOME/.git/notify-wm/rf1" && ! -f "$AGORA_HOME/.git/notify-wm/rf1.fail" ]] \
  && ok "worker 行不收终态信（角色过滤＝设计内跳过推水位，gt-236a③a）" || fail "gt-236a③a worker 过滤不符"
msg_add_ev rf2 ack gt-236d
rt_reset rf2; NB
[[ $(nb_calls) == 0 && $(grep -c "sid=ses-df skip role-filter ev=ack role=dispatcher" "$DBGLOG") == 1 \
    && -f "$AGORA_HOME/.git/notify-wm/rf2" && ! -f "$AGORA_HOME/.git/notify-wm/rf2.fail" ]] \
  && ok "dispatcher 行不收派发/修正信（角色过滤，gt-236a③b）" || fail "gt-236a③b dispatcher 过滤不符"
# ⑤ 精准层定向：routing 指向非最新行 sid（2508 场景正解——同实体多活行只投亲和 sid）
map_add rt1 ses-r1 "2027-01-01T00:00:00+08:00"
map_add rt1 ses-r2 "2027-01-01T00:00:00+08:00"
printf '%s' '{"data":{"title":"r1"}}' > "$NB_HOME/who/ses-r1.json"
printf '%s' '{"data":{"title":"r2"}}' > "$NB_HOME/who/ses-r2.json"
RT_ADD gt-236b dispatcher rt1 ses-r1
msg_add_ev rt1 done gt-236b
rt_reset rt1; NB
P236=$(grep -o 'PROMPT-OK /api/session/ses-r[0-9]/prompt' "$NB_HOME/calls.log" | sort -u)
[[ $(nb_calls) == 1 && "$P236" == "PROMPT-OK /api/session/ses-r1/prompt" \
    && $(grep -c "sid=ses-r1 inject-ok.*kind=R" "$DBGLOG") == 1 ]] \
  && ok "精准层定向：只投 task-routing 亲和 sid（非最新行，gt-236a⑤）" || fail "gt-236a⑤ 定向不符（$P236）"
# ⑥ 定向失败 fallback：routing 指 dead sid→落兜底广播活行
map_add rt2 ses-r3 "2027-01-01T00:00:00+08:00"
printf '%s' '{"data":{"title":"r3"}}' > "$NB_HOME/who/ses-r3.json"
printf '%s' '{"data":{"outcome":"failed"}}' > "$NB_HOME/who/ses-dead9.json"
RT_ADD gt-236b dispatcher rt2 ses-dead9
msg_add_ev rt2 done gt-236b
rt_reset rt2; NB
[[ $(nb_calls) -ge 1 && $(grep -c "sid=ses-dead9 skip dead" "$DBGLOG") == 1 \
    && $(grep -c "sid=ses-r3 inject-ok.*kind=F" "$DBGLOG") == 1 ]] \
  && ok "定向失败落兜底广播（dead sid 跳过，gt-236a⑥）" || fail "gt-236a⑥ fallback 不符"
# ⑦ progress 心跳零注入＋水位推进（设计内不注入）
map_add rt3 ses-r4 "2027-01-01T00:00:00+08:00"
printf '%s' '{"data":{"title":"r4"}}' > "$NB_HOME/who/ses-r4.json"
msg_add_ev rt3 progress gt-236b
rt_reset rt3; NB
[[ $(nb_calls) == 0 && $(grep -c "entity=rt3 sid=- progress-silent" "$DBGLOG") == 1 && -f "$AGORA_HOME/.git/notify-wm/rt3" ]] \
  && ok "progress 心跳零注入＋水位推进（gt-236a⑦）" || fail "gt-236a⑦ progress 不符"
# ⑧ task-routing.sh：upsert 幂等原位刷＋role 分行＋校验拒
RT_ADD gt-236c dispatcher rtX sidX; RT_ADD gt-236c dispatcher rtX sidY; RT_ADD gt-236c worker rtX sidW
[[ $(grep -c '^gt-236c dispatcher ' "$AGORA_HOME/.git/task-routing") == 1 \
    && $(grep -c '^gt-236c worker ' "$AGORA_HOME/.git/task-routing") == 1 \
    && "$(bash "$PKG/scripts/task-routing.sh" get gt-236c dispatcher | awk '{print $2}')" == sidY \
    && "$(bash "$PKG/scripts/task-routing.sh" get gt-236c dispatcher | awk '{print $1}')" == rtX \
    && "$(bash "$PKG/scripts/task-routing.sh" get gt-236c worker | awk '{print $2}')" == sidW ]] \
  && ok "task-routing upsert 幂等原位刷＋role 分行＋get 输出 entity sid（gt-236a⑧）" || fail "gt-236a⑧ routing 不符"
bash "$PKG/scripts/task-routing.sh" upsert bad-id dispatcher e s >/dev/null 2>&1; [[ $? -eq 2 ]] \
  && bash "$PKG/scripts/task-routing.sh" upsert gt-236c badrole e s >/dev/null 2>&1; [[ $? -eq 2 ]] \
  && ok "task-routing 非法形态拒绝 rc2（gt-236a⑧b）" || fail "gt-236a⑧b 校验不符"
# ⑨ register-session --role 写入/保留/覆写＋--deregister 幂等
REGS() { bash "$PKG/scripts/register-session.sh" "$@"; }
REGS --sid ses-rr --entity rtt --role worker >/dev/null \
  && [[ $(awk '$3=="ses-rr" {print $5}' "$AGORA_HOME/sessions.map") == worker ]] \
  && REGS --sid ses-rr --entity rtt >/dev/null \
  && [[ $(awk '$3=="ses-rr" {print $5}' "$AGORA_HOME/sessions.map") == worker ]] \
  && REGS --sid ses-rr --entity rtt --role dispatcher >/dev/null \
  && [[ $(awk '$3=="ses-rr" {print $5}' "$AGORA_HOME/sessions.map") == dispatcher ]] \
  && REGS --sid ses-rr --entity rtt --deregister >/dev/null \
  && [[ $(awk '$3=="ses-rr"' "$AGORA_HOME/sessions.map" | wc -l) == 0 ]] \
  && REGS --sid ses-rr --entity rtt --deregister >/dev/null \
  && ok "register-session --role 写入/保留/覆写＋--deregister 幂等（gt-236a⑨）" || fail "gt-236a⑨ 注册面不符"
REGS --sid ses-rr2 --entity rtt --role badrole >/dev/null 2>&1; [[ $? -eq 2 ]] \
  && ok "register-session 非法 role 拒绝 rc2（gt-236a⑨b）" || fail "gt-236a⑨b 校验不符"
# ⑩ 精准层 routed sid 白名单硬闸（R1 C 册实弹闭合：../ 形态写侧放行→消费端拦截落兜底）
map_add rt4 ses-rf "2027-01-01T00:00:00+08:00"
printf '%s' '{"data":{"title":"rf"}}' > "$NB_HOME/who/ses-rf.json"
bash "$PKG/scripts/task-routing.sh" upsert gt-236e dispatcher rt4 '../evil' >/dev/null
msg_add_ev rt4 done gt-236e
rt_reset rt4; NB
[[ $(grep -cE 'api/session/(\.\.|evil)' "$NB_HOME/calls.log") == 0 \
    && $(grep -c "sid=\.\./evil skip bad-sid routed" "$DBGLOG") == 1 \
    && $(grep -c "sid=ses-rf inject-ok.*kind=F" "$DBGLOG") == 1 ]] \
  && ok "精准层 routed sid 白名单拦截＋落兜底（gt-236a⑩）" || fail "gt-236a⑩ 白名单闸不符"
# ⑪ 无 summary 行信件：不误判 progress 静默吞（R1 B 册空针修复——丢不得契约）
map_add ns1 ses-ns "2027-01-01T00:00:00+08:00"
printf '%s' '{"data":{"title":"ns"}}' > "$NB_HOME/who/ses-ns.json"
mkdir -p "$AGORA_HOME/inbox/ns1"; echo "- from:x | ts:y | ref:r236ns" > "$AGORA_HOME/inbox/ns1/$(date +%s%N)-ns1.md"
rt_reset ns1; NB
[[ $(nb_calls) == 1 && -f "$AGORA_HOME/.git/notify-wm/ns1" ]] \
  && ok "无 summary 信件照常注入不静默吞（gt-236a⑪）" || fail "gt-236a⑪ 空事件不符（$(nb_calls)）"
# ⑫ AGORA_SESSION_TTL_H 非数字：sanitize 保 daemon 不死＋回落 24（R1 B 册 set -u 炸桥修复）
map_add_ts st2 ses-st2 "2020-01-01T00:00:00+08:00"
msg_add_ev st2 done gt-236d
rt_reset st2
AGORA_SESSION_TTL_H=abc NB; RC236=$?
[[ $RC236 -eq 0 && $(grep -c "sid=ses-st2 skip stale ts=2020" "$DBGLOG") == 1 ]] \
  && ok "TTL_H 非数字 sanitize 不炸桥＋回落缺省（gt-236a⑫）" || fail "gt-236a⑫ sanitize 不符（rc=$RC236）"
# ⑬ 精准层实体匹配（R2#2）：routing 行属他实体→视为无行落兜底，禁跨实体误投
map_add mm1 ses-mm "2027-01-01T00:00:00+08:00"
printf '%s' '{"data":{"title":"mm"}}' > "$NB_HOME/who/ses-mm.json"
RT_ADD gt-236f dispatcher OTHER-ENT ses-other
msg_add_ev mm1 done gt-236f
rt_reset mm1; NB
[[ $(grep -cE 'api/session/ses-other' "$NB_HOME/calls.log") == 0 \
    && $(grep -c "skip routed-entity-mismatch task=gt-236f" "$DBGLOG") == 1 \
    && $(grep -c "sid=ses-mm inject-ok.*kind=F" "$DBGLOG") == 1 ]] \
  && ok "精准层跨实体拒投落兜底（gt-236a⑬）" || fail "gt-236a⑬ 实体匹配不符"
# ⑭ 精准层定向 delegated worker 会话照投（R2#7：任务亲和定向同 post.sh T3 ack 注入先例；
# delegated 排除仅约束兜底广播的实体信），dead 照旧拦截
map_add wd1 ses-wd "2027-01-01T00:00:00+08:00"
printf '%s' '{"data":{"parentID":"ses_p","title":"agora: gt-236g worker"}}' > "$NB_HOME/who/ses-wd.json"
RT_ADD gt-236a7 worker wd1 ses-wd
msg_add_ev wd1 ack gt-236a7
rt_reset wd1; NB
[[ $(nb_calls) == 1 && $(grep -c "sid=ses-wd inject-ok.*kind=R" "$DBGLOG") == 1 ]] \
  && ok "精准层定向 delegated worker 会话照投（gt-236a⑭）" || fail "gt-236a⑭ 定向 worker 不符"

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
bash "$PKG/scripts/derive-board.sh"
grep -q "$POLLT2" "$AGORA_HOME/board/conflicts.md" \
  && ok "双清 claim 回放兜底入 conflicts" || fail "双清 claim 回放兜底入 conflicts"

echo "===== 增量推导（derive-cache） ====="
python3 -c "import json;c=json.load(open('$AGORA_HOME/.git/derive-cache.json'));assert c['v']==5 and c['watermark']" \
  && ok "增量缓存已建立" || fail "增量缓存已建立"
S0=$(python3 -c "import json;print(json.load(open('$AGORA_HOME/.git/derive-cache.json'))['stats']['incr'])")
bash "$PKG/scripts/derive-board.sh"
S1=$(python3 -c "import json;print(json.load(open('$AGORA_HOME/.git/derive-cache.json'))['stats']['incr'])")
[[ $S1 -gt $S0 ]] && ok "无新事件走增量路径" || fail "无新事件走增量路径（$S0→$S1）"
rm -rf "$T/board.snap"; cp -r "$AGORA_HOME/board" "$T/board.snap"
rm "$AGORA_HOME/.git/derive-cache.json"; bash "$PKG/scripts/derive-board.sh"
diff -r "$T/board.snap" "$AGORA_HOME/board" >/dev/null && ok "增量与全量结果一致" || fail "增量与全量结果一致"
# 前缀被改（union 合并重排/脏写）→ 自动回退全量重放，结果不变
SHARD=$(LC_ALL=C ls "$AGORA_HOME"/log/*/*.md | head -1)
sed -i '1i <!-- tampered -->' "$SHARD" 2>/dev/null
F0=$(python3 -c "import json;print(json.load(open('$AGORA_HOME/.git/derive-cache.json'))['stats']['full'])")
bash "$PKG/scripts/derive-board.sh"
F1=$(python3 -c "import json;print(json.load(open('$AGORA_HOME/.git/derive-cache.json'))['stats']['full'])")
[[ $F1 -gt $F0 ]] && diff -r "$T/board.snap" "$AGORA_HOME/board" >/dev/null \
  && ok "前缀篡改回退全量且结果一致" || fail "前缀篡改回退全量且结果一致（$F0→$F1）"

echo "===== doctor ====="
# 证据引用推送对账：PROJ 已有本地 evidence refs（attach 段产生）；配空远端 → warn 但不破 ALL GREEN
git init -q --bare "$T/proj-remote.git"
git -C "$PROJ" remote add origin "$T/proj-remote.git" 2>/dev/null || true
OUT=$(bash "$PKG/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "warn | 未推送的证据引用" && echo "$OUT" | grep -q "ALL GREEN" \
  && ok "未推送证据 warn 不破 ALL GREEN" || { fail "未推送证据 warn 不破 ALL GREEN"; echo "$OUT"; }
git -C "$PROJ" push -q origin 'refs/agora/evidence/*' >/dev/null 2>&1
OUT=$(bash "$PKG/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "ok   | 证据引用推送对账" \
  && ok "推送后证据对账转 ok" || { fail "推送后证据对账转 ok"; echo "$OUT"; }
OUT=$(bash "$PKG/scripts/doctor.sh" 2>&1)
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
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" "$PROJ2" "$AGORA_HOME" "$PKG" <<'PYEOF' && ok "check_mail since 水位语义" || fail "check_mail since 水位语义"
import json, subprocess, sys, os
srv, proj2, home, PKG = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
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
subprocess.run(["bash", f"{PKG}/scripts/post.sh", "--actor","tester@proj","--project","proj",
                "--event","progress","--task","gt-wwww","--mention","tester","--body","水位1"],
               env=env, capture_output=True)
m1 = mail(r1); w1 = m1["watermark"]
assert m1["count"] >= 1 and w1
assert since(r1, w1)["count"] == 0, "水位即末尾应无新邮件"
subprocess.run(["bash", f"{PKG}/scripts/post.sh", "--actor","tester@proj","--project","proj",
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
bash "$PKG/scripts/derive-board.sh" >/dev/null
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
grep -qxF 'sessions.map merge=union' "$H2/.gitattributes" \
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
OUT=$(AGORA_HOME="$H2" bash "$PKG/scripts/doctor.sh" 2>&1); RC=$?
[[ $RC -eq 1 ]] && echo "$OUT" | grep -q "合并中断" && ok "doctor 检出 MERGE_HEAD 残留" || fail "doctor 检出 MERGE_HEAD 残留"
OUT=$(AGORA_HOME="$H2" bash "$PKG/scripts/doctor.sh" --fix 2>&1)
[[ ! -f "$H2/.git/MERGE_HEAD" ]] && echo "$OUT" | grep -q "ALL GREEN" \
  && ok "doctor --fix 恢复合并中断" || { fail "doctor --fix 恢复合并中断"; echo "$OUT"; }

# --- wiki-write 权限模型 ---
bash "$PKG/scripts/wiki-write.sh" --actor rival@proj2 --path entities/tester.md --mode replace <<< "篡改" \
  2>/dev/null; [[ $? -eq 5 ]] && ok "wiki replace owner 不符被拒(rc=5)" || fail "wiki replace owner 不符被拒(rc=5)"
bash "$PKG/scripts/wiki-write.sh" --actor tester@proj --path topics/roadmap.md --mode replace <<< "议题" >/dev/null \
  && ok "wiki 新建 topics 页" || fail "wiki 新建 topics 页"
bash "$PKG/scripts/wiki-write.sh" --actor rival@proj2 --path topics/roadmap.md --mode append <<< "补充" >/dev/null \
  && grep -q '\*\*rival@proj2\*\*' "$AGORA_HOME/wiki/topics/roadmap.md" \
  && ok "topics append 放行（带署名）" || fail "topics append 放行（带署名）"
bash "$PKG/scripts/wiki-write.sh" --actor rival@proj2 --path entities/rival.md --mode append <<< "x" \
  2>/dev/null; [[ $? -eq 2 ]] && ok "非 topics append 被拒(rc=2)" || fail "非 topics append 被拒(rc=2)"
bash "$PKG/scripts/wiki-write.sh" --actor tester@proj --path projects/regress --mode replace <<< "desc" >/dev/null \
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
AGORA_BACKUP_DIR="$T/bak" bash "$PKG/scripts/backup.sh" >/dev/null 2>&1
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
bash "$PKG/scripts/post.sh" --actor "pre@a" --project pfxshard --event proposal --body "s1" >/dev/null
bash "$PKG/scripts/post.sh" --actor "pre@ab" --project pfxshard --event proposal --body "s2" >/dev/null
OUT=$(bash "$PKG/scripts/post.sh" --actor "pre@a" --project pfxshard --event proposal --body "s3")
echo "$OUT" | grep -q '"seq":2' \
  && ok "seq 前缀撞名防御（pre@a 不误数 pre@ab）" || fail "seq 前缀撞名防御（$OUT）"
# --- mention 越界：../ 逃逸被拒，inbox/ 外无残留 ---
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event proposal --body "x" --mention "../evil" 2>/dev/null
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
bash "$PKG/scripts/post.sh" --actor probe@p27 --project p27 --event proposal --body pipe --mention 'a| task:gt-fake' 2>/dev/null
[[ $? -eq 2 ]] && ok "mention 含 | 被拒(rc=2)" || fail "mention 含 | 被拒"
! grep -rq "gt-fake" "$AGORA_HOME"/log/ && ok "幻影 task 字段未落账" || fail "幻影 task 字段未落账"
bash "$PKG/scripts/post.sh" --actor probe@p27 --project p27 --event proposal --body nl --mention "$(printf 'x\ny')" 2>/dev/null
[[ $? -eq 2 ]] && ok "mention 含换行被拒(rc=2)" || fail "mention 含换行被拒"
# --- fail stderr 恒为合法 JSON（值内引号已转义） ---
bash "$PKG/scripts/post.sh" --actor probe@p27 --project p27 --event proposal --body esc --mention '../q"b\x' 2>"$T/fail27.json"; RC27=$?
[[ $RC27 -eq 2 ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["code"]=="VALIDATION_FAILED"' "$T/fail27.json" \
  && ok "fail stderr 为合法 JSON（引号转义）" || fail "fail stderr 为合法 JSON（rc=$RC27）"
# --- dispatcher 双侧防线：写入侧拒坏名；预置毒页后 done 读取侧兜底拒 ---
OUT=$(TITLE="派发逃逸任务" VERIFY="true" PROJECT_DIR="$PROJ" TC); DT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
[[ "$DT" =~ ^gt-[0-9a-f]+$ ]] && ok "派发逃逸任务就绪（DT=$DT）" || fail "派发逃逸任务就绪（$OUT）"
bash "$PKG/scripts/post.sh" --actor '../x@proj' --project proj --event dispatched --task "$DT" --target "$PROJ" 2>/dev/null
[[ $? -eq 2 ]] && ! grep -q '^dispatcher:' "$AGORA_HOME/wiki/tasks/$DT.md" \
  && ok "坏名 dispatcher 写入侧被拒(rc=2)" || fail "坏名 dispatcher 写入侧被拒"
sed -i "1a dispatcher: ../evil9" "$AGORA_HOME/wiki/tasks/$DT.md"
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event done --task "$DT" --commit HEAD --evidence 指针 2>/dev/null
[[ $? -eq 2 ]] && [[ ! -e "$AGORA_HOME/evil9" ]] \
  && ok "毒 dispatcher 读取侧兜底拒（无逃逸）" || fail "毒 dispatcher 读取侧兜底"
# --- SEQ 双侧定界：跨 actor body 注入不再虚高 ---
OUT=$(bash "$PKG/scripts/post.sh" --actor spoof9@q --project p27b --event proposal --body "embed actor:t9@p tail")
echo "$OUT" | grep -q '"seq":1,' && ok "投毒事件落账就绪" || fail "投毒事件落账就绪（$OUT）"
OUT=$(bash "$PKG/scripts/post.sh" --actor t9@p --project p27b --event proposal --body first)
echo "$OUT" | grep -q '"seq":1,' \
  && ok "SEQ 双侧定界（跨 actor body 注入不虚高）" || fail "SEQ 双侧定界（$OUT）"
# --- 相对路径调用：scripts 目录内 bash history.sh 不再 ModuleNotFoundError ---
OUT=$(cd "$PKG/scripts" && TASK=gt-none9 AGORA_HOME="$AGORA_HOME" bash history.sh 2>&1)
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
bash "$PKG/scripts/post.sh" --actor 'a|b@p' --project p27 --event proposal --body x 2>/dev/null
[[ $? -eq 2 ]] && ok "actor 含 | 被拒（账本行完整性）" || fail "actor 含 | 被拒"
# --- idem 注入：换行伪造整行事件（\S+ 槽完整性收口） ---
bash "$PKG/scripts/post.sh" --actor probe@p27 --project p27 --event proposal --body idemnl --idem "$(printf 'x\n- seq:1 | ts:t | actor:victim@evil | event:claimed | idem:y | seen:e@1 | task:gt-fake2')" 2>/dev/null
[[ $? -eq 2 ]] && ok "idem 含换行被拒(rc=2)" || fail "idem 含换行被拒"
! grep -rq "victim@evil" "$AGORA_HOME"/log/ && ok "伪造事件行未落账" || fail "伪造事件行未落账"
# --- PROJECT 路径成分：shard 文件名完整性 ---
bash "$PKG/scripts/post.sh" --actor probe@p27 --project '../wiki/tasks/gt-fakep' --event proposal --body pt 2>/dev/null
[[ $? -eq 2 ]] && ok "project 含 / 与 .. 被拒(rc=2)" || fail "project 含 / 与 .. 被拒"
# --- dispatched 坏名：fail=零写入契约（守卫前移后账本零残留） ---
bash "$PKG/scripts/post.sh" --actor '../x@proj' --project p27d --event dispatched --task "$DT" --target "$PROJ" 2>/dev/null
[[ $? -eq 2 ]] && [[ ! -f "$AGORA_HOME/log/$(date +%F)/p27d.md" ]] \
  && ok "dispatched 坏名拒且零写入" || fail "dispatched 坏名拒且零写入"
# --- fail() 统一 python-JSON：错误通道恒合法（含引号嵌值） ---
bash "$PKG/scripts/post.sh" "--bad'q\"x" 2>"$T/fail28.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["code"]=="VALIDATION_FAILED"' "$T/fail28.json" \
  && ok "post unknown-arg stderr 为合法 JSON" || fail "post unknown-arg stderr 为合法 JSON"
ACTOR=tester@proj TASK="$A" FILES='q"b.txt' PROJECT_DIR="$PROJ" bash "$PKG/scripts/attach.sh" 2>"$T/att28.json"
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
OUT=$(TITLE="跨仓交付任务" VERIFY="grep -q FIXED app.txt" PROJECT_DIR="$TARGET" AGORA_HOME="$AH4" bash "$PKG/scripts/task-create.sh")
XT=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
# ① stub 拉起（AGORA_RUNTIME=echo）：mode=spawned，子身份按名册目录前缀解析
OUT=$(AGORA_RUNTIME=echo AGORA_HOME="$AH4" bash "$PKG/scripts/dispatch.sh" --actor orch@orch --project "$TARGET" --task "$XT" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' && ok "dispatch stub 返回 mode:spawned" || fail "dispatch stub 返回 mode:spawned（$OUT）"
echo "$OUT" | grep -q '"child_actor":"worker@target"' && ok "dispatch 名册解析子身份 worker@target" || fail "dispatch 名册解析子身份 worker@target（$OUT）"
# ② 子会话照协议回报：claimed → done（verify 门真实执行 grep -q FIXED app.txt）
AGORA_HOME="$AH4" bash "$PKG/scripts/post.sh" --actor worker@target --project target --event claimed --task "$XT" >/dev/null
AGORA_HOME="$AH4" bash "$PKG/scripts/post.sh" --actor worker@target --project target --event done --task "$XT" --commit HEAD --evidence "通过" >/dev/null \
  && ok "子会话 done 通过 verify 门" || fail "子会话 done 通过 verify 门"
# ③ 账本断言：事件序列 / done 自动 @派单方 / 全链无 verify_failed / 任务页 dispatcher 标注（规格 §4.7 第 7 条）
H=$(TASK="$XT" AGORA_HOME="$AH4" bash "$PKG/scripts/history.sh")
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
OUT=$(TITLE="尾引号verify任务" VERIFY='test "$(cat f.txt)" = "ANS"' PROJECT_DIR="$TARGET" AGORA_HOME="$AH4" bash "$PKG/scripts/task-create.sh")
XT2=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
AGORA_HOME="$AH4" bash "$PKG/scripts/post.sh" --actor worker@target --project target --event claimed --task "$XT2" >/dev/null
AGORA_HOME="$AH4" bash "$PKG/scripts/post.sh" --actor worker@target --project target --event done --task "$XT2" --commit HEAD --evidence "通过" >/dev/null
TASK="$XT2" AGORA_HOME="$AH4" bash "$PKG/scripts/history.sh" | python3 -c "
import json,sys
evs=[e['event'] for e in json.load(sys.stdin)['events']]
assert evs==['claimed','done'], evs
" && ok "尾引号标量 verify 类 done 过门（成对剥离后原样透传）" || fail "尾引号标量 verify 类 done 未过门（verify_failed）"
# ⑤ history.sh 裸调用 fail-fast（gt-ca34 翻转 r1 合同：静默缺省=改名后静默错路径根因，未设必报错指名 AGORA_HOME）
_BH=$(env -u AGORA_HOME HOME="$H4" TASK="$XT" bash "$PKG/scripts/history.sh" 2>&1) && _BRC=0 || _BRC=$?
[[ "$_BRC" -ne 0 && "$_BH" == *AGORA_HOME* ]] \
  && ok "history.sh 裸调用 fail-fast（env 未设报错指名 AGORA_HOME，gt-ca34）" || fail "history.sh 裸调用未 fail-fast 或报错未指名 AGORA_HOME（rc=$_BRC，gt-ca34）"
# ⑥ 同任务双派生双审计行：dispatch_id 纳秒哈希天然唯一 → run 不同 → dispatched idem 不同（重派/reopened 链路审计行不被连续窗口吞）
AGORA_RUNTIME=echo AGORA_HOME="$AH4" bash "$PKG/scripts/dispatch.sh" --actor orch@orch --project "$TARGET" --task "$XT" >/dev/null 2>&1
N=$(cat "$AH4"/log/*/*.md 2>/dev/null | grep -F "task:$XT" | grep -c "event:dispatched")
[ "$N" -eq 2 ] && ok "同任务二次派生 dispatched 审计行落账（基线 1 + 新增 1）" || fail "同任务二次派生 dispatched 行被吞（共 $N 条，期望 2）"
# ⑦ dedup 旗标透传：dispatch 响应 JSON 含裸布尔 dedup 键（正常落账路径 = false）
OUT=$(AGORA_RUNTIME=echo AGORA_HOME="$AH4" bash "$PKG/scripts/dispatch.sh" --actor orch@orch --project "$TARGET" --task "$XT")
echo "$OUT" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
assert d.get('dedup') is False, d
" && ok "dispatch 响应 JSON 含 dedup:false（裸布尔）" || fail "dispatch 响应 JSON 缺 dedup:false（$OUT）"

# ⑧ gt-eefd 子会话身份兜底：server cwd=派单方目录（模拟共享 MCP 进程 env 继承），
#   仅 env 携带 dispatch 上下文 → post 不带 actor 落账 child_actor（账本 dispatched 记录的 child,
#   权威于派发时点）；显式 actor 恒优先；无 env 对照组照旧进程级 ACTOR（兜底不越权）
OUT=$(TITLE="身份兜底任务" VERIFY="true" PROJECT_DIR="$TARGET" AGORA_HOME="$AH4" bash "$PKG/scripts/task-create.sh")
XG=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
AGORA_HOME="$AH4" bash "$PKG/scripts/post.sh" --actor orch@orch --project target --event dispatched --task "$XG" \
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
OUT=$(TITLE="worktree 任务" VERIFY="true" PROJECT_DIR="$W5" AGORA_HOME="$AH5" bash "$PKG/scripts/task-create.sh")
XW=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
rm -f "$AH5"/raw/dispatches/*.live
OUT=$(AGORA_RUNTIME=true AGORA_HOME="$AH5" bash "$PKG/scripts/dispatch.sh" --actor tester@repo --project "$W5" --task "$XW" 2>&1)
echo "$OUT" | grep -q '"child_actor":"tester@repo"' && ok "worktree 路径派发归属主 repo 实体（project=repo）" || fail "worktree 路径派发（$OUT）"
rm -f "$AH5"/raw/dispatches/*.live
OUT=$(AGORA_RUNTIME=true AGORA_HOME="$AH5" bash "$PKG/scripts/dispatch.sh" --actor tester@repo --project "$H5/no-such-repo" --task "$XW" 2>&1)
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
OUT=$(AGORA_RUNTIME=true AGORA_HOME="$AH5" bash "$PKG/scripts/dispatch.sh" --actor tester@repo --project "$W5/src" --task "$XW" 2>&1)
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
# ⑨ gt-85c3：非 wt 任务 spawn 强制树隔离（混分支根治 gt-236a/762a）
# a) 无 wt_dir 任务 → 自动补建 <REPO>__wt-<task>__<ts>（默认分支基点）＋任务页回填 wt_dir＋分支 wt/<task>
AWT=$(TITLE="auto-wt 任务" VERIFY="true" PROJECT_DIR="$R5" AGORA_HOME="$AH5" bash "$PKG/scripts/task-create.sh")
AWT=$(echo "$AWT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
rm -f "$AH5"/raw/dispatches/*.live
OUT=$(AGORA_RUNTIME=true AGORA_HOME="$AH5" bash "$PKG/scripts/dispatch.sh" --actor tester@repo --project "$R5" --task "$AWT" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' && echo "$OUT" | grep -q '"wt_created"' \
  && ok "auto-wt：无树任务 spawn 补建＋wt_created 在场" || fail "auto-wt 补建缺失（$OUT）"
ls -d "$H5/repo__wt-${AWT}__"* >/dev/null 2>&1 && ok "auto-wt：专属树已建（<REPO>__wt-<task>__<ts> 命名域）" || fail "auto-wt 树未建"
grep -q "^wt_dir:" "$AH5/wiki/tasks/$AWT.md" && ok "auto-wt：任务页 wt_dir 回填（下次派发幂等锚）" || fail "auto-wt 页未回填"
git -C "$R5" show-ref --verify --quiet "refs/heads/wt/$AWT" && ok "auto-wt：分支 wt/<task> 在场" || fail "auto-wt 分支缺失"
# b) nowt: true → 豁免不建树＋warn 显式
NWT=$(TITLE="nowt 豁免任务" VERIFY="true" PROJECT_DIR="$R5" AGORA_HOME="$AH5" bash "$PKG/scripts/task-create.sh")
NWT=$(echo "$NWT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
sed -i "2,/^---\$/s|^---\$|nowt: true\n---|" "$AH5/wiki/tasks/$NWT.md"
rm -f "$AH5"/raw/dispatches/*.live
OUT=$(AGORA_RUNTIME=true AGORA_HOME="$AH5" bash "$PKG/scripts/dispatch.sh" --actor tester@repo --project "$R5" --task "$NWT" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' && echo "$OUT" | grep -q "nowt: true 豁免" \
  && ok "nowt 豁免：spawn 放行＋warn 显式" || fail "nowt 豁免异常（$OUT）"
ls -d "$H5/repo__wt-${NWT}__"* >/dev/null 2>&1 && fail "nowt 豁免却建了树" || ok "nowt 豁免：零树隔离跳过"
# c) 已有 wt_dir → 不重复建（复用 a 的回填页再派）
NB=$(ls -d "$H5/repo__wt-${AWT}__"* | wc -l)
rm -f "$AH5"/raw/dispatches/*.live
OUT=$(AGORA_RUNTIME=true AGORA_HOME="$AH5" bash "$PKG/scripts/dispatch.sh" --actor tester@repo --project "$R5" --task "$AWT" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' && [ "$(ls -d "$H5/repo__wt-${AWT}__"* | wc -l)" = "$NB" ] \
  && ok "已有 wt_dir：不重复建树" || fail "已有 wt_dir 重复建树（$OUT）"
# d) ocr：同任务并发双派发 → per-repo flock＋锁内重读复用对手方回填 → 恰建一树（TOCTOU 回归钉；gt-85c3 并发面）
CWT=$(TITLE="并发补建任务" VERIFY=true PROJECT_DIR="$R5" AGORA_HOME="$AH5" bash "$PKG/scripts/task-create.sh" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
rm -f "$AH5"/raw/dispatches/*.live
AGORA_RUNTIME=true AGORA_HOME="$AH5" AGORA_LOCK_WAIT=30 bash "$PKG/scripts/dispatch.sh" --actor tester@repo --project "$R5" --task "$CWT" >/dev/null 2>&1 &
AGORA_RUNTIME=true AGORA_HOME="$AH5" AGORA_LOCK_WAIT=30 bash "$PKG/scripts/dispatch.sh" --actor tester@repo --project "$R5" --task "$CWT" >/dev/null 2>&1 &
wait
cd "$T"   # ocr：早前分节 cd 进 H5 内，rm 前必须退出——否则后续分节在已删 cwd 上跑（shell-init getcwd 报错/相对操作哑火）
[ "$(ls -d "$H5/repo__wt-${CWT}__"* 2>/dev/null | wc -l)" = 1 ] \
  && ok "同任务并发派发恰建一树（flock＋锁内重读）" || fail "并发重复建树（gt-85c3 锁回归）"
rm -rf "$H5"

echo "===== gt-575d：重启前挂起盘点＋BOOT done 收尾清单 ====="
H7=$(mktemp -d); AH7="$H7/agora"; REPO7="$H7/repo"
mkdir -p "$REPO7"; (cd "$REPO7" && git init -q . && git -c user.name=t -c user.email=t@l commit -q --allow-empty -m i)
AGORA_HOME="$AH7" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
mkdir -p "$AH7/wiki/entities"
printf -- '---\nname: pt575\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$REPO7" > "$AH7/wiki/entities/pt575.md"
(cd "$AH7" && git add -A && AGORA_MECHANICAL=1 git commit -qm ent >/dev/null)
P575=$(TITLE="盘点任务" VERIFY=true PROJECT_DIR="$REPO7" AGORA_HOME="$AH7" bash "$PKG/scripts/task-create.sh")
P575=$(echo "$P575" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
AGORA_HOME="$AH7" bash "$PKG/scripts/register-session.sh" --sid ses-p575 --entity pt575 >/dev/null
AGORA_HOME="$AH7" bash "$PKG/scripts/post.sh" --actor pt575@repo --project repo --event dispatched \
  --task "$P575" --target "$REPO7" --child pt575 --run "raw/dispatches/d-p575.log" --session ses-p575 >/dev/null
OUT=$(AGORA_HOME="$AH7" bash "$PKG/scripts/pending-sessions.sh")
echo "$OUT" | grep -q "ses-p575" && echo "$OUT" | grep -q "$P575" \
  && ok "盘点：在册＋未终态会话列出（sid＋task 联结）" || fail "盘点缺挂起项（$OUT）"
AGORA_HOME="$AH7" bash "$PKG/scripts/post.sh" --actor pt575@repo --project repo --event done \
  --task "$P575" --commit HEAD --evidence x >/dev/null
OUT=$(AGORA_HOME="$AH7" bash "$PKG/scripts/pending-sessions.sh")
echo "$OUT" | grep -q "可安全重启" && ok "盘点：终态后出列（可安全重启）" || fail "盘点未出列（$OUT）"
# ocr-24：reopened 清终态（scan_tasks 同口径）——done→reopened→再派发的活 worker 须重新入列
AGORA_HOME="$AH7" bash "$PKG/scripts/post.sh" --actor pt575@repo --project repo --event reopened \
  --task "$P575" --reason "返工重开（盘点回归注入）" >/dev/null
AGORA_HOME="$AH7" bash "$PKG/scripts/post.sh" --actor pt575@repo --project repo --event dispatched \
  --task "$P575" --target "$REPO7" --child pt575 --run "raw/dispatches/d-p575b.log" --session ses-p575 >/dev/null
OUT=$(AGORA_HOME="$AH7" bash "$PKG/scripts/pending-sessions.sh")
echo "$OUT" | grep -q "ses-p575" && ok "盘点：reopened 再派发的活会话重新入列（ocr-24）" || fail "盘点 reopened 盲区（$OUT）"
AGORA_HOME="$AH7" bash "$PKG/scripts/post.sh" --actor pt575@repo --project repo --event cancelled \
  --task "$P575" --reason "盘点回归清场" >/dev/null
grep -q "退场收尾三查" "$PKG/scripts/dispatch.sh" && grep -q "知识积累已提交" "$PKG/scripts/dispatch.sh" \
  && grep -q "worktree 清理确认" "$PKG/scripts/dispatch.sh" && grep -q "遗留项显式注明" "$PKG/scripts/dispatch.sh" \
  && ok "BOOT done 收尾三查清单在场（知识积累/worktree/遗留项）" || fail "BOOT 收尾清单缺失"
rm -rf "$H7"

echo "===== gt-8fe1：derive done 出列权威化＋doctor seq 核销 ====="
H8=$(mktemp -d); AH8="$H8/agora"; REPO8="$H8/repo"
mkdir -p "$REPO8"; (cd "$REPO8" && git init -q . && git -c user.name=t -c user.email=t@l commit -q --allow-empty -m i)
AGORA_HOME="$AH8" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
mkdir -p "$AH8/wiki/entities"
printf -- '---\nname: px\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$REPO8" > "$AH8/wiki/entities/px.md"
(cd "$AH8" && git add -A && AGORA_MECHANICAL=1 git commit -qm ent >/dev/null)
P8() { AGORA_HOME="$AH8" bash "$PKG/scripts/post.sh" --actor "$@"; }
X1=$(TITLE="retired盲化done" VERIFY=true PROJECT_DIR="$REPO8" AGORA_HOME="$AH8" TC)
X1=$(echo "$X1" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
P8 px@repo --project repo --event retired --reason "wave 让行" >/dev/null   # wave 让行型 retired——活跃 actor 被误盲化（当日实证形态）
P8 px@repo --project repo --event claimed --task "$X1" >/dev/null
P8 px@repo --project repo --event done --task "$X1" --commit HEAD --evidence x >/dev/null
AGORA_HOME="$AH8" bash "$PKG/scripts/derive-board.sh" >/dev/null
grep -q "^- $X1$" "$AH8/board/todo.md" \
  && fail "C1-a：retired 盲化吞 done，任务滞 todo" || ok "C1-a：retired 盲化下 done 出列（先于盲化，todo 无此任务）"
X2=$(TITLE="未认领done" VERIFY=true PROJECT_DIR="$REPO8" AGORA_HOME="$AH8" TC)
X2=$(echo "$X2" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
P8 px@repo --project repo --event done --task "$X2" --commit HEAD --evidence x >/dev/null
AGORA_HOME="$AH8" bash "$PKG/scripts/derive-board.sh" >/dev/null
grep -q "^- $X2$" "$AH8/board/todo.md" \
  && fail "C1-b：未认领 done 滞 todo" || ok "C1-b：未认领任务直发 done 出列（owner 放宽 None）"
# C2：seq 缺口 → doctor 红 rc1 → diagnosed seq-waive 核销 → ok rc0（不删行，runbook §seq）
FP8="$AH8/log/$(date +%F)/px.md"
mkdir -p "$(dirname "$FP8")"
printf -- '- seq:99 | ts:%s | actor:px@repo | event:proposal | idem:seqgapfix8fe1 | seen:repo@1 | body:注入缺口行\n' "$(date -Is)" >> "$FP8"
OUT=$(AGORA_HOME="$AH8" bash "$PKG/scripts/doctor.sh" 2>&1); RC=$?
echo "$OUT" | grep -q "seq 断档" && [ "$RC" = 1 ] \
  && ok "C2：seq 缺口未核销置红 rc1" || fail "C2 缺口应红（rc=$RC $OUT）"
P8 px@repo --project repo --event diagnosed --task "$X1" \
  --conclusion "seq-waive=$(date +%F)/px.md:px@repo 缺口行已人工核对（gt-8fe1 测试注入；不删行留痕口径）" >/dev/null
OUT=$(AGORA_HOME="$AH8" bash "$PKG/scripts/doctor.sh" 2>&1); RC=$?
echo "$OUT" | grep -q "已核销" && [ "$RC" = 0 ] \
  && ok "C2：diagnosed seq-waive 核销后 ok rc0" || fail "C2 核销未生效（rc=$RC $OUT）"
# C3（ocr-5）：idem 连续重复同通道核销——红文案/键口径（idem 值非 actor）/核销 ok 全链钉死
printf -- '- seq:90 | ts:%s | actor:px@repo | event:progress | idem:dup8fe1 | seen:repo@90 | task:%s | body:a\n- seq:91 | ts:%s | actor:px@repo | event:progress | idem:dup8fe1 | seen:repo@91 | task:%s | body:b\n' \
  "$(date -Is)" "$X2" "$(date -Is)" "$X2" >> "$FP8"
OUT=$(AGORA_HOME="$AH8" bash "$PKG/scripts/doctor.sh" 2>&1); RC=$?
echo "$OUT" | grep -q "连续重复 idem" && [ "$RC" = 1 ] \
  && ok "C3：连续重复 idem 置红 rc1" || fail "C3 idem 未红（rc=$RC $OUT）"
P8 px@repo --project repo --event diagnosed --task "$X2" \
  --conclusion "idem-waive=$(date +%F)/px.md:dup8fe1 测试注入行已人工核对（不删行留痕口径）" >/dev/null
OUT=$(AGORA_HOME="$AH8" bash "$PKG/scripts/doctor.sh" 2>&1); RC=$?
echo "$OUT" | grep -q "已核销" && [ "$RC" = 0 ] \
  && ok "C3：diagnosed idem-waive 核销后 ok rc0" || fail "C3 idem 核销未生效（rc=$RC $OUT）"
# C4（ocr-8/9 负例）：他日期同分片名的 seq 缺口不得被既有核销吞——新格式键含 date，跨日必红
mkdir -p "$AH8/log/2026-10-25"
printf -- '- seq:50 | ts:2026-10-25T10:00:00+08:00 | actor:px@repo | event:proposal | idem:seqgapneg8fe1 | seen:repo@1 | body:跨日负例注入\n' > "$AH8/log/2026-10-25/px.md"
OUT=$(AGORA_HOME="$AH8" bash "$PKG/scripts/doctor.sh" 2>&1); RC=$?
echo "$OUT" | grep -q "seq 断档" && [ "$RC" = 1 ] \
  && ok "C4：他日期同分片名缺口不误吞（负例红）" || fail "C4 负例被误吞（rc=$RC $OUT）"
rm -rf "$H8"

# --- post.sh 读取侧三件 + board 心跳 age（gt-4ea1 F/E）---
# 坏名（含反斜杠）dispatcher 拒 done + fail 零写入（全新 project 无 shard 残留）
TF=$(TITLE="毒dispatcher任务" VERIFY="true" PROJECT_DIR="$PROJ" TC | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
printf 'dispatcher: bo\\ss\n' >> "$AGORA_HOME/wiki/tasks/$TF.md"
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@projx --project projx --event done --task "$TF" --commit HEAD --evidence x 2>&1)
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
bash "$PKG/scripts/derive-board.sh" >/dev/null 2>&1
grep -qE "进展（[0-9]+min前）: 心跳测试" "$AGORA_HOME/board/in-progress.md" && ok "board 显示心跳 age" || fail "board 无心跳 age"

echo "===== 身份裁决不冻结（2026-10-20 gt-9f24 事故回归） ====="
# server 启动早于实体页覆盖：启动期 auto-register 因同名页 O_EXCL 撞名让位 → 匿名；
# 旧代码冻结终身（共享 server 08:39 启动早于 10:14 实体页 → 派生会话写路径全拒）；
# 修后每次工具调用重裁决 → 实体页后到补 dirs，同进程内身份立即生效
if [ "$REG_OK" = 1 ]; then
LATE="$REG/late"   # gt-583b：可注册域夹具（/tmp 族已拒注册，原 $T/late 会使 O_EXCL 让位路径失活）
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
# 启动期：late.md dirs 未含 cwd → 启动期 auto-register 因同名页 O_EXCL 撞名让位 → 匿名
# （冻结代码下此值此后不再变化）
you0 = you()
assert you0 != "late@late", f"夹具应保证 late 覆盖是后到的，实际启动即 {you0}"
# 实体页后到覆盖 cwd（模拟实体页晚于 server 启动）
f = f"{home}/wiki/entities/late.md"
txt = open(f).read().replace("/nonexistent-late-xyz", late)
open(f, "w").write(txt)
assert you() == "late@late", f"后到覆盖应立即生效，实际 {you()}"
p.stdin.close()
PYEOF
else
ok "身份裁决不冻结（后到覆盖同进程生效）（skip：\$HOME=worktree 布局 REG 归主不可注册）"
fi
rm -rf "$REG"   # 可注册夹具域用毕即清（真 $HOME 不留残；trap EXIT 兜底中断路径）

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

echo "===== dispatch 深度默认5＋账本推导＋配额账本化（gt-2845 K3 复审） ====="
rm -f "$AGORA_HOME/sessions.map"   # 前序桥段残留清场（交互注册已不算在场，仅保持净场）
# 清场：前序段落的活 dispatched（账本口径）全部 cancelled 出集——本段配额计数需净场
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
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
DSP()  { AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" "$@"; }
DSPQ() { AGORA_RUNTIME=echo AGORA_MAX_SPAWN=3 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" "$@"; }   # gt-8c5b：默认改 30 后显式钉 3 保语义
TID() { echo "$1" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p'; }
D1=$(TID "$(TITLE="深度a" VERIFY=true PROJECT_DIR="$PROJ" TC)"); D2=$(TID "$(TITLE="深度b" VERIFY=true PROJECT_DIR="$PROJ" TC)")
D3=$(TID "$(TITLE="深度c" VERIFY=true PROJECT_DIR="$PROJ" TC)")
E1=$(TID "$(TITLE="链a" VERIFY=true PROJECT_DIR="$PROJ" TC)"); E2=$(TID "$(TITLE="链b" VERIFY=true PROJECT_DIR="$PROJ" TC)")
E3=$(TID "$(TITLE="链c" VERIFY=true PROJECT_DIR="$PROJ" TC)"); E4=$(TID "$(TITLE="链d" VERIFY=true PROJECT_DIR="$PROJ" TC)")
E5=$(TID "$(TITLE="链e" VERIFY=true PROJECT_DIR="$PROJ" TC)"); F1=$(TID "$(TITLE="配额" VERIFY=true PROJECT_DIR="$PROJ" TC)")
# ① env 深度：默认 5 下 NEXT=3/4 放行（DEPTH=2/3）、NEXT=5 拒（DEPTH=4）
AGORA_DEPTH=2 DSP --task "$D1" 2>/dev/null | grep -q '"mode":"spawned"' && ok "深度默认5：DEPTH=2(NEXT=3) 放行" || fail "深度默认5：DEPTH=2 放行"
AGORA_DEPTH=3 DSP --task "$D2" 2>/dev/null | grep -q '"mode":"spawned"' && ok "深度默认5：DEPTH=3(NEXT=4) 放行" || fail "深度默认5：DEPTH=3 放行"
AGORA_DEPTH=4 DSP --task "$D3" 2>&1 | grep -q DEPTH_EXCEEDED && ok "深度默认5：DEPTH=4(NEXT=5) 拒" || fail "深度默认5：DEPTH=4 拒"
# ② 账本推导：dispatcher_task 链深度与 env 取 max（配额窗已开至 9 不干扰）
DSP --task "$E1" >/dev/null 2>&1   # E1 基线派发（depth 1）
AGORA_DEPTH=0 DSP --task "$E2" --dispatcher-task "$E1" 2>/dev/null | grep -q '"mode":"spawned"' && ok "链派发 E2(dtask=E1) 放行" || fail "链派发 E2(dtask=E1) 放行"
AGORA_DEPTH=0 DSP --task "$E3" --dispatcher-task "$E2" 2>/dev/null | grep -q '"mode":"spawned"' && ok "账本链 NEXT=3 放行（默认5语义）" || fail "账本链 NEXT=3 应放行"
AGORA_DEPTH=0 DSP --task "$E4" --dispatcher-task "$E3" 2>/dev/null | grep -q '"mode":"spawned"' && ok "账本链 NEXT=4 放行" || fail "账本链 NEXT=4 应放行"
AGORA_DEPTH=0 DSP --task "$E5" --dispatcher-task "$E4" 2>&1 | grep -q DEPTH_EXCEEDED && ok "账本推导：env=0 但链深 NEXT=5 拒" || fail "账本推导拒（env 0 链深 5）"
cat "$AGORA_HOME"/log/*/*.md | grep -F "task:$E2" | grep "event:dispatched" | grep -q "dispatcher_task:$E1" && ok "dispatched 落账含 dispatcher_task" || fail "dispatched 落账含 dispatcher_task"
# ③ 配额账本化（默认 MAX_SPAWN=3）：零 .live 但账本活派发 6 → 拒第 7；终态出集后放行
DSPQ --task "$F1" 2>&1 | grep -q QUOTA_EXCEEDED && ok "配额账本化：6 活派发（零 .live）拒第 7" || fail "配额账本化拒（零 .live）"
for _cq in "$D1" "$E1" "$E2" "$E3"; do POST tester@proj --event cancelled --task "$_cq" >/dev/null; done
DSPQ --task "$F1" 2>/dev/null | grep -q '"mode":"spawned"' && ok "终态出集后配额放行" || fail "终态出集后配额放行"
# ④ 配额分域＋全局总闸（gt-8c5b）：域键＝账本 actor 字符串（不细分 host，跨机共享账本同域合并）——A 域满不挡 B；总和超措辞分档
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'   # 先清零 tester 域（②③残留 D2/E4/F1 会污染恰好5 的摆法）
import glob, re, sys
home = sys.argv[1]
disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
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
mkdir -p "$T/proj-t2"   # tester2 独立覆盖目录：同径 $PROJ 会与 tester 并列二义（resolve_entity 同深 glob 序定胜负），child 归属翻转打碎 S5 在场/K5——实测回归
printf -- '---\nname: tester2\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$T/proj-t2" > "$AGORA_HOME/wiki/entities/tester2.md"
(cd "$AGORA_HOME" && git add -A && AGORA_MECHANICAL=1 git commit -qm "entities tester2")
Q1=$(TID "$(TITLE="分域a1" VERIFY=true PROJECT_DIR="$PROJ" TC)"); Q2=$(TID "$(TITLE="分域a2" VERIFY=true PROJECT_DIR="$PROJ" TC)")
Q3=$(TID "$(TITLE="分域a3" VERIFY=true PROJECT_DIR="$PROJ" TC)"); Q4=$(TID "$(TITLE="分域a4" VERIFY=true PROJECT_DIR="$PROJ" TC)")
Q5=$(TID "$(TITLE="分域a5" VERIFY=true PROJECT_DIR="$PROJ" TC)"); Q6=$(TID "$(TITLE="分域a6" VERIFY=true PROJECT_DIR="$PROJ" TC)")
QB1=$(TID "$(TITLE="分域b1" VERIFY=true PROJECT_DIR="$T/proj-t2" TC)"); QB2=$(TID "$(TITLE="分域b2" VERIFY=true PROJECT_DIR="$T/proj-t2" TC)")
DSP5() { AGORA_RUNTIME=echo AGORA_MAX_SPAWN=5 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" "$@"; }
DSPB() { AGORA_RUNTIME=echo bash "$PKG/scripts/dispatch.sh" --actor tester2@proj --project "$T/proj-t2" "$@"; }
for _t in "$Q1" "$Q2" "$Q3" "$Q4" "$Q5"; do DSP5 --task "$_t" >/dev/null 2>&1; done
DSP5 --task "$Q6" 2>&1 | grep -q "分域满" && ok "分域：A 域 5/5 满拒 A 第 6（分域措辞）" || fail "分域：A 域满应拒第 6"
DSPB --task "$QB1" 2>/dev/null | grep -q '"mode":"spawned"' && ok "分域：A 域满不挡 B（B 域 0/30 放行）" || fail "分域：A 域满不应挡 B"
AGORA_MAX_SPAWN_GLOBAL=6 DSPB --task "$QB2" 2>&1 | grep -q "总量满" && ok "总量闸：A5+B1=6 各域未超总和超，拒（总量措辞）" || fail "总量闸：总和超应拒（总量措辞）"
for _t in "$Q1" "$Q2" "$Q3" "$Q4" "$Q5"; do POST tester@proj --event cancelled --task "$_t" >/dev/null 2>&1; done
POST tester2@proj --event cancelled --task "$QB1" >/dev/null 2>&1
# .live→actor 归属回归（评审 O2）：账本侧出集（diagnosed）、仅留名下 .live，域闸仍触发——覆盖 runs/live_by/relpath 归属路径
LV="raw/dispatches/d-11fea001.log"
POST tester@proj --event dispatched --task "$Q6" --target "$PROJ" --child tester --run "$LV" >/dev/null 2>&1
POST tester@proj --event diagnosed --task "$Q6" --conclusion stub >/dev/null 2>&1   # 出账本活跃集，仅余 .live
touch "$AGORA_HOME/$LV.live"
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=1 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$Q6" 2>&1 | grep -q "分域满" \
  && ok ".live 分域归属：仅名下 .live 也计域值" || fail ".live 分域归属未计入域值"
rm -f "$AGORA_HOME/$LV.live"

echo "===== dispatch 发射加固＋凭据预写＋wt 免在场优先（全量委托 L1 Task4） ====="
rm -f "$AGORA_HOME/sessions.map"
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
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
DSPRAW() { AGORA_RUNTIME="${RT:-echo}" AGORA_VERIFY_WIN="${VW:-2}" bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "${P:-$PROJ}" "$@"; }
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
# ② wt 免在场优先：sessions.map 交互注册在场 → 任务一律 spawned（在场仅认委托子会话 gt-0ed3）
printf '%s tester sess-fake %s\n' "$(hostname)" "$(date +%s)" >> "$AGORA_HOME/sessions.map"
G2=$(TID "$(TITLE="在场豁免" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=t4b TC)")
DSPRAW --task "$G2" 2>/dev/null | grep -q '"mode":"spawned"' && ok "wt 任务免在场优先（spawned）" || fail "wt 任务免在场优先"
N1=$(TID "$(TITLE="在场对照" VERIFY=true PROJECT_DIR="$PROJ" TC)")
DSPRAW --task "$N1" 2>/dev/null | grep -q '"mode":"spawned"' && ok "非 wt 交互注册占坑直接派生（spawned，gt-0ed3）" || fail "非 wt 交互注册占坑应直接派生"
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
rm -f "$AGORA_HOME/sessions.map"
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
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
MERGE() { bash "$PKG/scripts/merge.sh" --actor tester@proj --task "$1"; }
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
AGORA_RUNTIME=echo bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$MC" --dispatcher-task "$MB" >/dev/null 2>&1
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
# ⑧ 非 wt 闭环（gt-7117）：页无 wt_dir＝直改仓任务——done commit 已在主仓默认分支→出票补 merged，无树操作；
# verify 背书＝done 时机械 verify 锚 project_dir（对齐 wt 幂等路径⑤「已含→只补账不重验」）
N8=$(TID "$(TITLE="非wt闭环" VERIFY=true PROJECT_DIR="$PROJ" TC)")
echo nwt > "$PROJ/nwt-file"; git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@l commit -qm nwt
POST tester@proj --event claimed --task "$N8" >/dev/null
POST tester@proj --event done --task "$N8" --commit "$(git -C "$PROJ" rev-parse HEAD)" --evidence ok >/dev/null
MERGE "$N8" 2>/dev/null | grep -q '"result":"merged"' && ok "⑧ 非 wt 闭环 merged JSON" || fail "⑧ 非 wt 闭环 merged JSON"
LEDEV "$N8" merged | grep -q "commit:$(git -C "$PROJ" rev-parse HEAD)" && ok "⑧ merged 落账 commit=主仓 HEAD" || fail "⑧ merged 落账 commit=主仓 HEAD"
[ -z "$(ls -d "$T"/proj__wt-${N8}__* 2>/dev/null)" ] && ok "⑧ 非 wt 无树操作" || fail "⑧ 非 wt 无树操作"
MERGE "$N8" >/dev/null 2>&1
[ "$(LEDEV "$N8" merged | grep -c "event:merged")" -eq 1 ] && ok "⑧ 重跑幂等（merged 恰一条）" || fail "⑧ 重跑幂等（merged 恰一条）"
# ⑧b done commit 未并入主仓→NOT_IN_TARGET 拒、无 merged 落账
N8B=$(TID "$(TITLE="非wt未并" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$N8B" >/dev/null   # ⑧d 闸后 claimed 链＝非 wt 闭环前置（夹具态=生产态）
D8C=$(git -C "$PROJ" -c user.name=t -c user.email=t@l commit-tree 'HEAD^{tree}' -m dangling8b)
POST tester@proj --event done --task "$N8B" --commit "$D8C" --evidence ok >/dev/null
MERGE "$N8B" 2>&1 | grep -q NOT_IN_TARGET && ok "⑧b done 未并入主仓被拒" || fail "⑧b done 未并入主仓被拒"
[ -z "$(LEDEV "$N8B" merged)" ] && ok "⑧b 拒后无 merged 落账" || fail "⑧b 拒后无 merged 落账"
# ⑧c 账本无 done 事件→锚点缺失拒
N8C=$(TID "$(TITLE="非wt无done" VERIFY=true PROJECT_DIR="$PROJ" TC)")
MERGE "$N8C" 2>&1 | grep -q VALIDATION_FAILED && ok "⑧c 无 done commit 拒" || fail "⑧c 无 done commit 拒"
# ⑧d actor 链闸（gt-7117 评审 C-1 fail-closed）：无 claimed 直 done→VALIDATION_FAILED；done≠首个 claimed actor→DONE_ACTOR_MISMATCH
N8D=$(TID "$(TITLE="非wt无claimed" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST rival@proj2 --event done --task "$N8D" --commit "$(git -C "$PROJ" rev-parse HEAD)" --evidence ok >/dev/null
MERGE "$N8D" 2>&1 | grep -q VALIDATION_FAILED && ok "⑧d 无 claimed 链拒（fail-closed）" || fail "⑧d 无 claimed 链拒（fail-closed）"
N8E=$(TID "$(TITLE="非wt冒领done" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$N8E" >/dev/null
POST rival@proj2 --event done --task "$N8E" --commit "$(git -C "$PROJ" rev-parse HEAD)" --evidence ok >/dev/null
MERGE "$N8E" 2>&1 | grep -q DONE_ACTOR_MISMATCH && ok "⑧d done actor≠claimed actor 拒" || fail "⑧d done actor≠claimed actor 拒"
# ⑧e（R1 评审锚定回归）：自由文本字段不得伪造/污染链闸信号——progress body 引 event:claimed 不放行；done evidence 引 actor:x 不假拒
N8F=$(TID "$(TITLE="非wt伪claimed" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST rival@proj2 --event progress --task "$N8F" --body "补录 event:claimed 待查" >/dev/null
POST rival@proj2 --event done --task "$N8F" --commit "$(git -C "$PROJ" rev-parse HEAD)" --evidence ok >/dev/null
MERGE "$N8F" 2>&1 | grep -q VALIDATION_FAILED && ok "⑧e 自由文本伪造 claimed 不放行" || fail "⑧e 自由文本伪造 claimed 不放行"
N8G=$(TID "$(TITLE="非wt证据引actor" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$N8G" >/dev/null
POST tester@proj --event done --task "$N8G" --commit "$(git -C "$PROJ" rev-parse HEAD)" --evidence "handoff reviewed by actor:alice" >/dev/null
MERGE "$N8G" 2>/dev/null | grep -q '"result":"merged"' && ok "⑧e evidence 引 actor:x 不假拒" || fail "⑧e evidence 引 actor:x 不假拒"
# ⑧e 补（R2 评审）：非行尾伪造 actor（evidence 后随字段＝生产常态）不放行；末条 done 垃圾 commit 不回退旧锚
N8H=$(TID "$(TITLE="非wt中位伪造actor" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$N8H" >/dev/null
POST rival@proj2 --event done --task "$N8H" --commit "$(git -C "$PROJ" rev-parse HEAD)" --evidence "fin actor:tester@proj" --body wrap >/dev/null
MERGE "$N8H" 2>&1 | grep -q DONE_ACTOR_MISMATCH && ok "⑧e 非行尾伪造 actor 不放行" || fail "⑧e 非行尾伪造 actor 不放行"
N8I=$(TID "$(TITLE="非wt末条垃圾commit" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$N8I" >/dev/null
POST tester@proj --event done --task "$N8I" --commit "$(git -C "$PROJ" rev-parse HEAD)" --evidence ok >/dev/null
POST tester@proj --event done --task "$N8I" --commit HEAD --evidence 重跑 >/dev/null
MERGE "$N8I" 2>&1 | grep -q VALIDATION_FAILED && ok "⑧e 末条垃圾 commit 不回退旧锚" || fail "⑧e 末条垃圾 commit 不回退旧锚"
# ⑧f（gt-e5cc）：done 锚点三盲区——点分片可见＋多 done 按 ts 取末条＋复合 commit 值容错＋漂移 HEAD 不吃票（gt-762a 回归）
SHDIR="$AGORA_HOME/log/$(date +%Y-%m-%d)"; mkdir -p "$SHDIR"
DOTLINE() { printf -- '- seq:1 | ts:%s | actor:tester@proj | event:done | idem:%s | task:%s | commit:%s | evidence:fixture\n' "$1" "$2" "$3" "$4"; }
# ⑧f-1 正例（gt-236a 实形＋R1 B1 形态）：ts 晚的真锚（复合值，分支名段含 8 位 hex run 10222158）落 .a8f1.md（路径序在前），
#   ts 早的垃圾 done 落 .z8f1.md（路径序在后）——老 tail -1 取路径序末行必取垃圾，单候提取必误取 10222158；
#   新实现 ts 末条＋多候验祖先命中真锚（点分片可见性同段锁定）
N8J=$(TID "$(TITLE="非wt点分片done" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$N8J" >/dev/null
C8J=$(git -C "$PROJ" rev-parse HEAD)
DOTLINE "2026-10-26T00:00:01+08:00" a8f1 "$N8J" "proj@wt-fix-10222158:$C8J + other@master:$C8J" > "$SHDIR/.a8f1.md"
DOTLINE "2026-10-26T00:00:00+08:00" z8f1 "$N8J" "HEAD" > "$SHDIR/.z8f1.md"
MERGE "$N8J" 2>/dev/null | grep -q '"result":"merged"' && ok "⑧f 点分片可见＋ts 末条胜路径序＋复合值多候验祖先" || fail "⑧f 点分片/ts 序/复合 commit 锚点"
# ⑧f-2 负例（②判别向）：ts 晚的垃圾 commit 落 .a8f2.md（路径序在前），ts 早的真锚落 .z8f2.md（路径序在后）——
#   老 tail -1 取路径序末行取到真锚会误并；新 ts 末条＝垃圾 → 零候选 VALIDATION_FAILED（不回退旧锚）
N8K=$(TID "$(TITLE="非wt末条垃圾ts序" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$N8K" >/dev/null
DOTLINE "2026-10-26T00:00:01+08:00" a8f2 "$N8K" "HEAD" > "$SHDIR/.a8f2.md"
DOTLINE "2026-10-26T00:00:00+08:00" z8f2 "$N8K" "$C8J" > "$SHDIR/.z8f2.md"
MERGE "$N8K" 2>&1 | grep -q VALIDATION_FAILED && ok "⑧f 多 done 取 ts 末条：末条垃圾 commit 拒（不回退旧锚）" || fail "⑧f ts 末条语义"
# ⑧f-3 漂移 HEAD 不吃票（gt-762a 跨任务错乱回归）：检出切到任务分支时非 wt 目标仍＝默认分支
N8L=$(TID "$(TITLE="非wt漂移目标" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$N8L" >/dev/null
DEFA=$(git -C "$PROJ" symbolic-ref --short HEAD); PRE8F=$(git -C "$PROJ" rev-parse HEAD)
git -C "$PROJ" checkout -q -b drift8f3
echo drift > "$PROJ/drift8f3.txt"; git -C "$PROJ" add -A; git -C "$PROJ" -c user.name=t -c user.email=t@local commit -qm drift8f3
DX=$(git -C "$PROJ" rev-parse HEAD)
POST tester@proj --event done --task "$N8L" --commit "$DX" --evidence ok >/dev/null
MERGE "$N8L" 2>&1 | grep -q NOT_IN_TARGET && ok "⑧f 检出漂移期 done 不在默认分支被拒（gt-762a 回归）" || fail "⑧f 漂移期 NOT_IN_TARGET"
git -C "$PROJ" update-ref "refs/heads/$DEFA" "$DX"   # 产出落主支（ff 语义）
MERGE "$N8L" 2>/dev/null | grep -q '"result":"merged"' && ok "⑧f 产出落主支后补票" || fail "⑧f 产出落主支补票"
LEDEV "$N8L" merged | grep -q "branch:$DEFA" && ok "⑧f 票面 branch=默认分支（非漂移检出）" || fail "⑧f 票面 branch=默认分支"
# R2（ocr-5）：夹具自清——主支指针复位漂移前基点，防 drift8f3 提交泄漏进后续段落的夹具基线（账本行保留无妨）
git -C "$PROJ" update-ref "refs/heads/$DEFA" "$PRE8F"
git -C "$PROJ" checkout -q "$DEFA"; git -C "$PROJ" branch -q -D drift8f3

# ⑨ 跨仓 wt 形态显式拒（gt-78da A3）：wt_dir 属他仓→CROSS_REPO_WT＋拆分指引；零合并零落账零碰他仓树
git init -q "$T/other" && git -C "$T/other" -c user.name=t -c user.email=t@l commit -q --allow-empty -m init
git -C "$T/other" worktree add -q "$T/other-wt" -b wt9
printf -- '---\nwt_dir: %s/other-wt\nproject_dir: %s\nverify: "true"\n---\n' "$T" "$PROJ" > "$AGORA_HOME/wiki/tasks/gt-c999.md"
MERGE gt-c999 2>&1 | grep -q CROSS_REPO_WT && ok "⑨ 跨仓 wt 显式拒" || fail "⑨ 跨仓 wt 显式拒"
[ -z "$(LEDEV gt-c999 merged)" ] && ok "⑨ 拒后无 merged 落账" || fail "⑨ 拒后无 merged 落账"
[ -d "$T/other-wt" ] && ok "⑨ 他仓树不被触碰" || fail "⑨ 他仓树不被触碰"

echo "===== poll 补档：重派/孤儿/豁免/GC/host（全量委托 L1 Task7） ====="
rm -f "$AGORA_HOME/sessions.map"
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
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
           AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo bash "$PKG/scripts/poll.sh" 2>/dev/null; }
LEV() { cat "$AGORA_HOME"/log/*/*.md "$AGORA_HOME"/log/*/.*.md 2>/dev/null | grep -E "(^|[|] )task:$1( |$)" | grep "event:$2"; }   # gt-40cc：点分片伴生（跨分片核验禁裸 glob，终闸 ocr）
MKWT2() { TID "$(TITLE="$1" VERIFY="true" PROJECT_DIR="$PROJ" WT=1 IDEM="$2" TC)"; }
# ① done-unmerged：poll → diagnosed（未合并）＋恢复性重派上游
PU=$(MKWT2 "上游u" t7a); PD_=$(MKWT2 "下游d" t7b)
AGORA_RUNTIME=echo bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$PD_" --dispatcher-task "$PU" >/dev/null 2>&1
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
AGORA_RUNTIME=echo bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$GD" --dispatcher-task "$GU" >/dev/null 2>&1
WG=$(ls -d "$T"/proj__wt-${GD}__*); echo s > "$WG/sfile"; git -C "$WG" add -A; git -C "$WG" -c user.name=t -c user.email=t@l commit -qm s
POST tester@proj --event claimed --task "$GD" >/dev/null
POST tester@proj --event done --task "$GD" --commit HEAD --evidence ok >/dev/null
git -C "$PROJ" merge -q --ff-only "wt/$GD" 2>/dev/null   # 已实际并入主仓，账本不落 merged（簿记滞后形态）
POLLT >/dev/null
[ -z "$(LEV "$GD" diagnosed)" ] && [ -z "$(LEV "$GU" dispatched)" ] \
  && ok "①b git 已并＋账本无 merged → 梯子安静（不诊断不重派）" || fail "①b 簿记滞后误诊/误重派（diag=$(LEV "$GD" diagnosed | head -1)）"
# ② 重派上限：3 次后第 4 次 escalated、不再派
QU=$(MKWT2 "上限u" t7c); QD=$(MKWT2 "上限d" t7d)
AGORA_RUNTIME=echo bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$QD" --dispatcher-task "$QU" >/dev/null 2>&1
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
  bash "$PKG/scripts/poll.sh" >/dev/null 2>&1   # 宽限大：全留
[ -d "$WR" ] && ok "④ 宽限内不删" || fail "④ 宽限内不删"
POLLT >/dev/null   # 宽限 0：净树删、脏树留
[ ! -d "$WG" ] && ok "④ 终态＋宽限尽＋clean→删" || fail "④ 净树未删"
[ -d "$WD" ] && ok "④ dirty 树只报告不删" || fail "④ dirty 树被误删"
rm -f "$WD/dirty-file"
OR=$(MKWT2 "缺页树" t7j); WO=$(ls -d "$T"/proj__wt-${OR}__*)
rm -f "$AGORA_HOME/wiki/tasks/$OR.md"
bash "$PKG/scripts/doctor.sh" 2>/dev/null | grep -q "__wt-" && ok "④ 缺任务页树 doctor 报告" || fail "④ doctor 未报告缺页树"
[ -d "$WO" ] && ok "④ 缺页树不删" || fail "④ 缺页树被误删"
# ⑤ parent 链 watchdog ×4 豁免：改写观察时钟模拟 45min 无事件
PT_=$(TID "$(TITLE="豁免母" TC)"); CN=$(TID "$(TITLE="豁免子" PARENT="$PT_" TC)")
POST tester@proj --event claimed --task "$PT_" >/dev/null; POST tester@proj --event claimed --task "$CN" >/dev/null
AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 \
  bash "$PKG/scripts/poll.sh" >/dev/null 2>&1   # 只为武装观察时钟
python3 - "$AGORA_HOME" <<'PYEOF'
import json, os, sys, time
f = f"{sys.argv[1]}/.git/poll-state.json"
s = json.load(open(f))
for t, e in s.get("_activity", {}).items():
    if isinstance(e, dict): e["since"] = time.time() - 45*60
json.dump(s, open(f, "w"))
PYEOF
AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 \
  bash "$PKG/scripts/poll.sh" >/dev/null 2>&1
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
  bash "$PKG/scripts/poll.sh" 2>/dev/null)
echo "$R" | grep -q "$HO" && echo "$R" | grep -q "wt_host" && [ -z "$(LEV "$HO" dispatched)" ] \
  && ok "⑥ wt_host 异机任务拾取跳过（held）" || fail "⑥ host 限定"
# ⑥b 终态核查棒：merged 已由 derive 消费（gt-5a59）→ merged 落账即离板（post.sh 同锁重推导），
# mention 零派发——雪球根因消除；账本终态守卫（gt-99af 修复一）留作派生滞后窗第二道防线
TZ=$(TID "$(TITLE="终态不派" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
tick "$TZ"; POST tester@proj --event merged --task "$TZ" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null; untick "$TZ"
POST rival@proj2 --event progress --task "$TZ" --mention tester --body "终态后不应派发" >/dev/null
POLLT >/dev/null
[ -z "$(LEV "$TZ" dispatched)" ] && ! grep -q "^- $TZ" "$AGORA_HOME/board/todo.md" \
  && ok "⑥b 终态（merged）任务 todo 不残留＋mention 不派发（雪球根因消除）" || fail "⑥b 终态任务被派发或 todo 残留（got: $(LEV "$TZ" dispatched | head -1)）"
# ⑥b-lag 滞后形态（ocr-R1#2 改判）：raw 追加 merged（不经 post.sh 同锁 derive）→ 提及拾取前的
# 看板一度滞后。注意 poll.sh:38 启动即 derive——新 derive 下滞后窗在生产路径结构性不可达，
# gt-99af 修复一（held 终态守卫）降为崩溃窗纵深；此处锚定可达不变量：滞后形态零派发＋poll 自愈离板
TZ2=$(TID "$(TITLE="终态滞后窗" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
POST rival@proj2 --event progress --task "$TZ2" --mention tester --body "滞后窗不应派发" >/dev/null
printf -- '- seq:98701 | ts:%s | actor:agora-mcp@proj | event:merged | idem:rawmg1 | seen:proj@0 | task:%s | commit:%s\n' \
  "$(date --iso-8601=seconds)" "$TZ2" "$(git -C "$PROJ" rev-parse HEAD)" >> "$AGORA_HOME/log/$(date +%F)/proj.md"
RB=$(POLLT)
[ -z "$(LEV "$TZ2" dispatched)" ] && ! grep -q "^- $TZ2" "$AGORA_HOME/board/todo.md" \
  && ok "⑥b-lag 滞后形态：零派发＋poll 启动 derive 自愈离板" || fail "⑥b-lag 滞后形态失守（dispatched=$(LEV "$TZ2" dispatched | head -1)）"
# ⑦ stale-live 回归（既有档）
SL=$(MKWT2 "滞留" t7l)
POST tester@proj --event claimed --task "$SL" >/dev/null
POST tester@proj --event dispatched --task "$SL" --target "$PROJ" --child tester --run "raw/dispatches/d-stale.log" >/dev/null
touch "$AGORA_HOME/raw/dispatches/d-stale.log.live"; touch -d '2 hours ago' "$AGORA_HOME/raw/dispatches/d-stale.log.live"
AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=0 \
  bash "$PKG/scripts/poll.sh" >/dev/null 2>&1
LEV "$SL" diagnosed | grep -q "滞留" && ok "⑦ .live 滞留→diagnosed（既有档回归）" || fail "⑦ stale-live"
rm -f "$AGORA_HOME/raw/dispatches/d-stale.log.live"   # gt-2153：清 stale 标记——teardown 轮询须零等待

# ⑧⑨⑩＋R5 gt-caf3 终闸发现核销（gt-40cc）：同秒 tie/GC stale prune/未尝试重派 null＋裸 glob 守卫
# ⑧ 同秒 tie：cancelled（点分片，先扫）与 dispatched（后扫分片）同秒 → 终态不被孤儿档复活重派（gt-caf3 ①）
TT=$(MKWT2 "tie终态" t9a)
TS8="$(date -Iseconds)"; D8="$(date +%F)"
mkdir -p "$AGORA_HOME/log/$D8"
printf -- '- seq:991 | ts:%s | actor:orch@.tiep | event:cancelled | idem:t9c1 | seen:x | task:%s\n' "$TS8" "$TT" > "$AGORA_HOME/log/$D8/.tie-orch.md"
printf -- '- seq:992 | ts:%s | actor:tester@proj | event:dispatched | idem:t9c2 | seen:x | task:%s | run:raw/dispatches/d-tie8.log | target:%s | child:tester\n' "$TS8" "$TT" "$PROJ" > "$AGORA_HOME/log/$D8/tie-wd.md"
POLLT >/dev/null
[ "$(LEV "$TT" dispatched | grep -c event:dispatched)" -eq 1 ] && [ -z "$(LEV "$TT" diagnosed | grep -F 孤儿)" ] \
  && ok "⑧ 同秒 cancelled+dispatched 平局取终态（不复活）" || fail "⑧ tie（disp=$(LEV "$TT" dispatched | grep -c event:dispatched)）"
rm -f "$AGORA_HOME/log/$D8/.tie-orch.md" "$AGORA_HOME/log/$D8/tie-wd.md"
# ⑧b 同秒 done+cancelled 跨分片 → closer 胜，done-unmerged 梯子不误燃（gt-40cc① 同源残角，终闸 A 册）
TB=$(MKWT2 "tie双终态" t9d)
TS9="$(date -Iseconds)"; D9="$(date +%F)"
printf -- '- seq:993 | ts:%s | actor:tester@proj | event:cancelled | idem:t9d1 | seen:x | task:%s\n' "$TS9" "$TB" > "$AGORA_HOME/log/$D9/.tie2-orch.md"
printf -- '- seq:994 | ts:%s | actor:tester@proj | event:done | idem:t9d2 | seen:x | task:%s | commit:x | evidence:ok\n' "$TS9" "$TB" > "$AGORA_HOME/log/$D9/tie2-wd.md"
POLLT >/dev/null
[ -z "$(LEV "$TB" diagnosed | grep -F 未合并)" ] && ok "⑧b 同秒 done+cancelled closer 胜（梯子安静）" || fail "⑧b done-unmerged 误燃（$(LEV "$TB" diagnosed | head -1)）"
rm -f "$AGORA_HOME/log/$D9/.tie2-orch.md" "$AGORA_HOME/log/$D9/tie2-wd.md"
# ⑧c 同秒 reopened+dispatched 同片（redispatch.sh 一次性流常规产形）→ 0 阶同片按追加序＝真因果序，
# 孤儿/idle-kick 探测不得被 reopened 升阶瞎掉（终闸 ocr high）
TC=$(MKWT2 "tie重开" t9f)
TSA="$(date -Iseconds)"
printf -- '- seq:995 | ts:%s | actor:tester@proj | event:reopened | idem:t9f1 | seen:x | task:%s\n' "$TSA" "$TC" > "$AGORA_HOME/log/$D9/tie3-wd.md"
printf -- '- seq:996 | ts:%s | actor:tester@proj | event:dispatched | idem:t9f2 | seen:x | task:%s | run:raw/dispatches/d-tie3.log | target:%s | child:tester\n' "$TSA" "$TC" "$PROJ" >> "$AGORA_HOME/log/$D9/tie3-wd.md"
POLLT >/dev/null
[ -n "$(LEV "$TC" diagnosed | grep -F 孤儿)" ] && ok "⑧c 同秒 reopened+dispatched 追加序胜（孤儿探测在线）" || fail "⑧c 孤儿探测被瞎（rank 升阶回归）"
rm -f "$AGORA_HOME/log/$D9/tie3-wd.md"
# ⑨ GC：空壳残留＋stale 注册 → prune 后 branch -D 删净（gt-caf3 ②；不修则每例残一分支永不回收）
GT2=$(MKWT2 "gc空壳" t9b); WG2=$(ls -d "$T"/proj__wt-${GT2}__*)
echo g > "$WG2/g2file"; git -C "$WG2" add -A; git -C "$WG2" -c user.name=t -c user.email=t@l commit -qm g2
POST tester@proj --event claimed --task "$GT2" >/dev/null
POST tester@proj --event done --task "$GT2" --commit HEAD --evidence ok >/dev/null
git -C "$PROJ" merge -q --ff-only "wt/$GT2" 2>/dev/null
tick "$GT2"; POST tester@proj --event merged --task "$GT2" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null; untick "$GT2"
rm -rf "$WG2"; mkdir "$WG2"   # 空壳＋stale 注册：remove validation failed → rmdir 可删 → branch -D 拒删形态
POLLT >/dev/null
git -C "$PROJ" rev-parse -q --verify "refs/heads/wt/$GT2" >/dev/null && fail "⑨ GC 空壳 stale：分支泄漏" || ok "⑨ GC 空壳 stale 注册：prune 后分支删净"
# ⑨b owner 未定：注册摘除＋空壳 → 不跑仓库级 git 操作（C 册 RCE 收口），显报＋空壳收敛＋分支保留（终闸 ocr）
GT3=$(MKWT2 "gc无主" t9e); WG3=$(ls -d "$T"/proj__wt-${GT3}__*)
POST tester@proj --event claimed --task "$GT3" >/dev/null
POST tester@proj --event done --task "$GT3" --commit HEAD --evidence ok >/dev/null
git -C "$PROJ" merge -q --ff-only "wt/$GT3" 2>/dev/null
tick "$GT3"; POST tester@proj --event merged --task "$GT3" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null; untick "$GT3"
rm -rf "$WG3"; mkdir "$WG3"; rm -rf "$PROJ/.git/worktrees"/proj__wt-${GT3}__*   # 摘注册：main_repo_of 与反查双断链
PO9=$(POLLT)
echo "$PO9" | python3 -c "
import json, sys
r = json.loads(sys.stdin.read())
k = [x for x in r['wt_branch_kept'] if x['task'] == '$GT3']
assert k and 'owner 未定' in k[0]['err'], (r['wt_branch_kept'], r['wt_remove_failed'])
" && ok "⑨b owner 未定显报（wt_branch_kept，B-M7 同口径）" || fail "⑨b owner 未定未显报"
[ ! -d "$WG3" ] && ok "⑨b 空壳收敛（rmdir 无 owner 也清，防永不收敛）" || fail "⑨b 空壳未收敛"
git -C "$PROJ" rev-parse -q --verify "refs/heads/wt/$GT3" >/dev/null && ok "⑨b 分支保守保留（无误删）" || fail "⑨b 分支被误删"
git -C "$PROJ" branch -q -D "wt/$GT3" 2>/dev/null; rm -rf "$WG3"   # 清场：不污染后续段落
# ⑩ 未尝试重派记 null：SPAWN=0 孤儿档 → redispatched:null（区别尝试失败 false）（gt-caf3 ③）
ON=$(MKWT2 "未尝试" t9c)
POST tester@proj --event dispatched --task "$ON" --target "$PROJ" --child tester --run "raw/dispatches/d-none9.log" >/dev/null
PO=$(AGORA_POLL_SPAWN=0 AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=0 AGORA_WT_GRACE_MIN=0 AGORA_DISPATCH_TIMEOUT=0 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo bash "$PKG/scripts/poll.sh" 2>/dev/null)
echo "$PO" | python3 -c "
import json, sys
r = json.loads(sys.stdin.read())
e = [x for x in r['orphan_diag'] if x['task'] == '$ON']
assert e and e[0]['redispatched'] is None, r['orphan_diag']
" && ok "⑩ 孤儿未尝试重派记 null" || fail "⑩ 未尝试重派未记 null"
# R5 (gt-40cc)：smoke 账本扫描禁裸 glob——守 python glob 与 LEV 两种命名形态（点分片必须伴生；
# gt-3ea2 点仓盲同类：跨分片核验禁裸 glob，终闸 ocr）。其余内生 cat 断言为已知边界不守（区域局部
# 任务，点分片事件不涉）——重构收口归专门批次，不在核销批扩面
BARE_GLOB=$(grep -F 'glob.glob(f"{home}/log/*/*.md")' "$PKG/tests/smoke-test.sh" | grep -vcF '.*.md' || true)
BARE_LEV=$(grep -F 'LEV() {' "$PKG/tests/smoke-test.sh" | grep -vcF '.*.md' || true)
[ "$((BARE_GLOB + BARE_LEV))" -eq 0 ] && ok "R5 smoke 账本扫描全带点分片伴生 glob" || fail "R5 裸 glob 残留 $BARE_GLOB+$BARE_LEV 处"

echo "===== BOOT 链式协议＋setup 钩子（全量委托 L1 Task8） ====="
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
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
AGORA_RUNTIME=echo AGORA_VERIFY_WIN=2 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$B1" 2>/dev/null | grep -q '"mode":"spawned"' \
  && ok "setup 任务派发 spawned" || fail "setup 任务派发"
[ -f "$T/setup-marker" ] && ok "setup: 在树内（spawn 前）执行（侧效文件）" || fail "setup 执行"
BOOTJSON=$(AGORA_RUNTIME=echo AGORA_VERIFY_WIN=2 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$B1" 2>/dev/null)
# setup 失败→零落账零 spawn
sed -i 's|^setup: .*|setup: exit 1|' "$AGORA_HOME/wiki/projects/proj.md"
B2=$(TID "$(TITLE="setup失败" VERIFY="true" PROJECT_DIR="$PROJ" WT=1 IDEM=t8b TC)")
OUT=$(AGORA_RUNTIME=echo AGORA_VERIFY_WIN=2 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$B2" 2>&1)
echo "$OUT" | grep -q SETUP_FAILED && ok "setup 失败→SETUP_FAILED" || fail "setup 失败 JSON"
cat "$AGORA_HOME"/log/*/*.md | grep -E "(^|[|] )task:$B2( |$)" | grep -q "event:dispatched" && fail "setup 失败零落账" || ok "setup 失败零落账"
sed -i 's|^setup: .*|setup: true|' "$AGORA_HOME/wiki/projects/proj.md"
# BOOT 关键词（从账本 dispatched 的 BOOT 不可见——直接源码断言＋行为断言走 grep 源文件）
for kw in "装环境" "不自己合并" "恢复性重派" "rebase"; do
  grep -q "$kw" "$PKG/scripts/dispatch.sh" && ok "BOOT 含「$kw」" || fail "BOOT 含「$kw」"
done

echo "===== 终审修复批（三分册 B-C1/W1-5 + A-W1/W2 + C-W1/W2 + S1/S3/M2/M5） ====="
# F1 (B-C1): GC 判据＝merged/cancelled，done 单独不足——done 未合并的净树不删
F1=$(TID "$(TITLE="gc-done未删" VERIFY="true" PROJECT_DIR="$PROJ" WT=1 IDEM=f1 TC)")
WF1=$(ls -d "$T"/proj__wt-${F1}__*)
echo f > "$WF1/ff"; git -C "$WF1" add -A; git -C "$WF1" -c user.name=t -c user.email=t@l commit -qm f1
POST tester@proj --event claimed --task "$F1" >/dev/null
POST tester@proj --event done --task "$F1" --commit HEAD --evidence ok >/dev/null
AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=0 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo \
  bash "$PKG/scripts/poll.sh" >/dev/null 2>&1
[ -d "$WF1" ] && ok "F1 done(未 merged)净树 GC 不删" || fail "F1 done 未合并树被删（数据丢失）"
# F2 (B-W1): task-create 锁超时不得假成功
( exec 9>"$AGORA_HOME/.git/post.lock"; flock -n 9 && sleep 6 ) &
OUT=$(AGORA_LOCK_WAIT=1 TITLE="锁超时" VERIFY=true PROJECT_DIR="$PROJ" TC 2>&1); RC=$?
sleep 6
[[ $RC -ne 0 ]] && ! echo "$OUT" | grep -q '"task"' && ok "F2 锁超时非零退出无假成功 JSON" || fail "F2 锁超时假成功（rc=$RC）"
# F3 (B-W2): merge 目标分支漂移守卫（上游树检出非目标分支→拒）
F3U=$(TID "$(TITLE="漂移u" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f3u TC)"); W3U=$(ls -d "$T"/proj__wt-${F3U}__*)
F3D=$(TID "$(TITLE="漂移d" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f3d TC)"); W3D=$(ls -d "$T"/proj__wt-${F3D}__*)
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$F3D" --dispatcher-task "$F3U" >/dev/null 2>&1
echo x > "$W3D/xf"; git -C "$W3D" add -A; git -C "$W3D" -c user.name=t -c user.email=t@l commit -qm x
git -C "$W3D" rebase -q "wt/$F3U" 2>/dev/null; DC3=$(git -C "$W3D" rev-parse HEAD)
echo u > "$W3U/uf"; git -C "$W3U" add -A; git -C "$W3U" -c user.name=t -c user.email=t@l commit -qm uf   # gt-7ca0：上游须有真实提交（零提交分支 tip==main 会按祖先检查回落 main，漂移守卫路径够不着）
git -C "$W3U" checkout -qb side-branch 2>/dev/null   # 上游树检出他支
OUT=$(bash "$PKG/scripts/merge.sh" --actor tester@proj --task "$F3D" 2>&1)
echo "$OUT" | grep -q TARGET_DETACHED && ok "F3 目标分支漂移被拒" || fail "F3 漂移未拒（$OUT）"
git -C "$W3U" checkout -q "wt/$F3U" 2>/dev/null; git -C "$W3U" branch -qD side-branch 2>/dev/null
# F4 (B-W5): 配额僵尸出集——last=diagnosed 的 dispatched 不占额
Z1=$(TID "$(TITLE="僵1" VERIFY=true PROJECT_DIR="$PROJ" TC)"); Z2=$(TID "$(TITLE="僵2" VERIFY=true PROJECT_DIR="$PROJ" TC)")
Z3=$(TID "$(TITLE="僵3" VERIFY=true PROJECT_DIR="$PROJ" TC)"); Z4=$(TID "$(TITLE="僵4" VERIFY=true PROJECT_DIR="$PROJ" TC)")
for z in Z1 Z2 Z3; do
  POST tester@proj --event dispatched --task "${!z}" --target "$PROJ" --child tester --run "raw/dispatches/d-z$z.log" >/dev/null
  POST tester@proj --event diagnosed --task "${!z}" --conclusion "秒死占位测试" >/dev/null
done
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=3 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$Z4" 2>/dev/null | grep -q '"mode":"spawned"' \
  && ok "F4 last=diagnosed 出集（3 僵尸后第 4 派放行）" || fail "F4 配额僵尸 wedge"
# F5 (A-W1): dispatcher_task 机械推导（未传时取 actor 最近 claimed 无终态任务）
C5=$(TID "$(TITLE="推导源" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$C5" >/dev/null
D5=$(TID "$(TITLE="推导目标" VERIFY=true PROJECT_DIR="$PROJ" TC)")
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$D5" >/dev/null 2>&1
cat "$AGORA_HOME"/log/*/*.md | grep -E "(^|[|] )task:$D5( |$)" | grep event:dispatched | grep -q "dispatcher_task:$C5" \
  && ok "F5 dispatcher_task 机械推导落账" || fail "F5 推导缺失"
# F5b (gt-6769): 推导「最近」按事件 ts 判——跨分片并存时文件序≠时序（跨 UTC 日期分片分裂＋union 点分片，三连挂实证）；
# 假行放排序靠后分片＋ts 早 30 分钟：旧码按文件序误选假行（红），修后按 ts 选真源（绿）；混合时区 tz-aware 可比
F5B="$AGORA_HOME/log/$(date +%F)/repb.md"
mkdir -p "$(dirname "$F5B")"   # ocr：跨午夜跑批当日分片可能尚无事件落账——缺目录重定向静默失败→断言空转绿
printf -- '- seq:1 | ts:%s | actor:tester@proj | event:claimed | idem:f5b1 | seen:repb@90 | task:gt-00000f5\n' "$(date -d '30 minutes ago' --iso-8601=seconds)" > "$F5B"
F5C=$(TID "$(TITLE="推导时序源" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$F5C" >/dev/null
F5D=$(TID "$(TITLE="推导时序目标" VERIFY=true PROJECT_DIR="$PROJ" TC)")
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$F5D" >/dev/null 2>&1
LEV "$F5D" dispatched | grep -q "dispatcher_task:$F5C" \
  && ok "F5b 推导最近按 ts 判（跨分片文件序≠时序不误选）" || fail "F5b 推导按文件序误选（gt-6769）"
# F5b (gt-6769): 跨 UTC 日期分片分裂——同一账本里 claimed 行的时序必须按 ts（offset-aware）判，
# 不得以分片目录文件序当新近度代理。构造：遗留 claimed（旧瞬间 ts）落今日分片（扫描序靠后），
# 新 claimed（新瞬间 ts，+00:00 UTC 形态）落昨日分片（扫描序靠前）——推导必须取新 claimed。
F5B="$T/f5b-agora"; AGORA_HOME="$F5B" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
mkdir -p "$F5B/wiki/entities"
printf -- '---\nname: ux\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$PROJ" > "$F5B/wiki/entities/ux.md"
F5B_TODAY=$(date +%F); F5B_YEST=$(date -d "1 day ago" +%F)
mkdir -p "$F5B/log/$F5B_TODAY" "$F5B/log/$F5B_YEST"
printf -- '- seq:1 | ts:2026-01-01T00:00:00+08:00 | actor:ux@proj | event:claimed | idem:f5b1 | seen:p@1 | task:gt-f5b1\n' >> "$F5B/log/$F5B_TODAY/proj.md"
printf -- '- seq:1 | ts:%s | actor:ux@proj | event:claimed | idem:f5b2 | seen:p@1 | task:gt-f5b2\n' "$(date --iso-8601=seconds)" >> "$F5B/log/$F5B_YEST/proj.md"
F5B_D=$(TITLE="gt6769跨分片推导" VERIFY=true PROJECT_DIR="$PROJ" AGORA_HOME="$F5B" TC | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 AGORA_HOME="$F5B" bash "$PKG/scripts/dispatch.sh" --actor ux@proj --project "$PROJ" --task "$F5B_D" >/dev/null 2>&1
cat "$F5B"/log/*/*.md | grep -E "(^|[|] )task:$F5B_D( |$)" | grep event:dispatched | grep -q "dispatcher_task:gt-f5b2" \
  && ok "F5b 跨日期分片推导按 ts 新近度（文件序不倒转）" || fail "F5b 分片分裂推导取陈旧 claimed（gt-6769）"
rm -rf "$F5B"
# F6 (A-W2): done-unmerged diagnosed 必 mention 派单方（跑一轮 MERGE_WAIT=0 产生诊断）
AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo \
  bash "$PKG/scripts/poll.sh" >/dev/null 2>&1
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
bash "$PKG/scripts/merge.sh" --actor tester@proj --task "$F8T" >/dev/null 2>&1
cat "$AGORA_HOME"/log/*/*.md | grep -E "(^|[|] )task:$F8T( |$)" | grep event:merged | grep -q "branch:" \
  && ok "F8 merged 落账含 branch" || fail "F8 merged 无 branch 字段"
# F9 (S3): merge.sh wt_host 异机守卫
F9T=$(TID "$(TITLE="异机合并" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f9 TC)"); W9=$(ls -d "$T"/proj__wt-${F9T}__*)
echo y > "$W9/yf"; git -C "$W9" add -A; git -C "$W9" -c user.name=t -c user.email=t@l commit -qm y
sed -i "s/^wt_host: .*/wt_host: other-99/" "$AGORA_HOME/wiki/tasks/$F9T.md"
bash "$PKG/scripts/merge.sh" --actor tester@proj --task "$F9T" 2>&1 | grep -q WT_HOST_MISMATCH && ok "F9 wt_host 异机合并被拒" || fail "F9 异机合并未拒"
# F10 (B-W3): reset 并发守卫——verify 期间目标推进则不回滚
F10=$(TID "$(TITLE="并发守卫" VERIFY='git commit --allow-empty -qm adv; false' PROJECT_DIR="$PROJ" WT=1 IDEM=f10 TC)")
WA=$(ls -d "$T"/proj__wt-${F10}__*)
echo c > "$WA/cf"; git -C "$WA" add -A; git -C "$WA" -c user.name=t -c user.email=t@l commit -qm c
PRE10=$(git -C "$PROJ" rev-parse HEAD)
OUT=$(bash "$PKG/scripts/merge.sh" --actor tester@proj --task "$F10" 2>&1)
[ "$(git -C "$PROJ" rev-parse HEAD)" != "$PRE10" ] && ok "F10 verify 窗口并发推进不被 reset 吞" || fail "F10 并发提交被 reset 吞"
git -C "$PROJ" reset -q --hard "$PRE10"   # 测试现场复位
# F11 (M5): poll 重派上游时透传其原链 dispatcher_task
F11U=$(TID "$(TITLE="透传u" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f11u TC)")
F11P=$(TID "$(TITLE="透传p" VERIFY=true PROJECT_DIR="$PROJ" TC)")   # u 的上游（pp）
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$F11U" --dispatcher-task "$F11P" >/dev/null 2>&1
POST tester@proj --event claimed --task "$F11U" >/dev/null
F11D=$(TID "$(TITLE="透传d" VERIFY=true PROJECT_DIR="$PROJ" WT=1 IDEM=f11d TC)")
AGORA_RUNTIME=echo AGORA_MAX_SPAWN=9 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$F11D" --dispatcher-task "$F11U" >/dev/null 2>&1
WD11=$(ls -d "$T"/proj__wt-${F11D}__*); echo t > "$WD11/tf"; git -C "$WD11" add -A; git -C "$WD11" -c user.name=t -c user.email=t@l commit -qm t
POST tester@proj --event claimed --task "$F11D" >/dev/null
POST tester@proj --event done --task "$F11D" --commit HEAD --evidence ok >/dev/null
AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=9 AGORA_RUNTIME=echo \
  bash "$PKG/scripts/poll.sh" >/dev/null 2>&1
cat "$AGORA_HOME"/log/*/*.md | grep -E "(^|[|] )task:$F11U( |$)" | grep event:dispatched | tail -1 | grep -q "dispatcher_task:$F11P" \
  && ok "F11 poll 重派透传原链 dispatcher_task" || fail "F11 重派链断裂"


echo "===== 已知风险批次（B-M3 孤儿判据 / B-M4 重派回报 / B-M7 GC 可见性 / doctor UTF-8） ====="
# 清场前奏：前序段落遗留活 dispatched 全部 cancelled 出集（配额/孤儿口径净场，沿 BOOT 段模式）
for _t in $(python3 - "$AGORA_HOME" <<'PYEOF'
import glob, re, sys
home = sys.argv[1]; disp, terminal = {}, set()
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
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
  bash "$PKG/scripts/poll.sh" 2>/dev/null)
echo "$OUT" | python3 -c 'import json,sys
d = json.load(sys.stdin); tid = sys.argv[1]
sys.exit(0 if any(e.get("task") == tid and e.get("redispatched") is False for e in d.get("orphan_diag", [])) else 1)' "$R4" \
  && ok "R2 重派失败记 redispatched:false（B-M4）" || fail "R2 重派失败未回报（B-M4）"
R5=$(MKWT2 "重派成功" r3m5)
POST tester@proj --event dispatched --task "$R5" --target "$PROJ" --child tester --run "raw/dispatches/d-r3.log" >/dev/null
OUT=$(AGORA_MERGE_WAIT_MIN=9999 AGORA_ORPHAN_MIN=0 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=99 AGORA_RUNTIME=echo \
  bash "$PKG/scripts/poll.sh" 2>/dev/null)
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
  bash "$PKG/scripts/poll.sh" 2>/dev/null)
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
bash "$PKG/scripts/post.sh" --actor tester@projx --project .projx --event claimed --task "$H1" >/dev/null
grep -q "^- $H1" "$AGORA_HOME/board/in-progress.md" 2>/dev/null && ok "点仓 claimed 上板（derive 可见）" || fail "点仓 claimed 上板（derive 盲）"
bash "$PKG/scripts/post.sh" --actor tester@projx --project .projx --event done --task "$H1" --commit HEAD --evidence ok >/dev/null
grep -q "^- $H1" "$AGORA_HOME/board/in-progress.md" 2>/dev/null && fail "点仓 done 后离板" || ok "点仓 done 后离板"
git -C "$PX" merge -q --ff-only "wt/$H1" 2>/dev/null
tick "$H1"
bash "$PKG/scripts/post.sh" --actor tester@projx --project .projx --event merged --task "$H1" --commit "$(git -C "$PX" rev-parse HEAD)" --branch "$(git -C "$PX" symbolic-ref --short HEAD)" >/dev/null
untick "$H1"
OUT=$(AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 AGORA_DISPATCH_TIMEOUT=9999 bash "$PKG/scripts/poll.sh" 2>/dev/null)
echo "$OUT" | python3 -c 'import json,sys
d = json.load(sys.stdin); tid = sys.argv[1]
sys.exit(1 if any(e.get("task") == tid for e in d.get("merge_wait_diag", [])) else 0)' "$H1" \
  && ok "点仓 merged 后梯子安静（poll 可见 merged）" || fail "点仓 merged 仍被诊断（poll 盲）"

echo "===== L2 API 通道批（T1 适配器契约 stub 测 / T2 API 派生 / T3 ack 注入 / T4 注入式续跑 / T5 在场 API 化） ====="
# stub：假 opencode CLI 进 PATH（只钉 L2 契约字段，形状照 v2.1.2 openapi 实证——{"data":…} 包裹/outcome/time.idle/location.directory/delivery:"queue"）
FAKEDIR="$T/fakebin"; FAKE_HOME="$T/fakeapi"; mkdir -p "$FAKEDIR" "$FAKE_HOME"
cat > "$FAKEDIR/opencode" <<'STUB'
#!/usr/bin/env bash
# 假 opencode（smoke 专用）。FAKE_HOME/ctrl: none|health_fail|create_fail|inject_fail|inject_slow|status_dead
set -u
FH="${FAKE_HOME:?FAKE_HOME required}"
log() { printf '%s\n' "$*" >> "$FH/calls.log"; }
case "${1:-}" in
  --version) echo "opencode v2.1.2-fake"; exit 0 ;;
  run) log "run $*"; exit 0 ;;
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
    [ "$CTRL" = inject_slow ] && sleep 2   # C 二期 K5：撑开 inject 窗口让 pgid 落盘可观测
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
    O=""; [ -f "$FH/active_outcome" ] && O=",\"outcome\":\"$(cat "$FH/active_outcome")\",\"time\":{\"created\":1,\"idle\":2}"   # gt-762a：done 残留形态（outcome+idle → status 归一 idle）
    echo "{\"data\":{\"id\":\"ses_act1\",\"title\":\"$(cat "$FH/active_title" 2>/dev/null || echo "")\",\"location\":{\"directory\":\"$(cat "$FH/active_dir" 2>/dev/null || echo /nonexist)\"}$O}}"; exit 0 ;;
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
# S1f create title 透传（gt-2845②）：create <dir> [title] → body title 透传；缺省 agora
fake_reset none
FAKE create "$PROJ" "agora: gt-abc1 标题甲" >/dev/null 2>&1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["title"]=="agora: gt-abc1 标题甲" else 1)' "$FAKE_HOME/create_body.json" \
  && ok "S1f create title 透传" || fail "S1f create title 透传"
fake_reset none
FAKE create "$PROJ" >/dev/null 2>&1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["title"]=="agora" else 1)' "$FAKE_HOME/create_body.json" \
  && ok "S1f create title 缺省 agora" || fail "S1f create title 缺省 agora"
# S1c inject：rc0＋delivery:"queue"＋文本透传；断电 rc1
fake_reset none
if FAKE inject ses_fake9 "hello 队列" >/dev/null 2>&1; then ok "S1c inject rc0"; else fail "S1c inject rc0"; fi
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("delivery")=="queue" and d.get("text")=="hello 队列" else 1)' "$FAKE_HOME/last_prompt.json" \
  && ok "S1c inject queue 透传" || fail "S1c inject queue 透传"
fake_reset inject_fail
if FAKE inject ses_fake9 x >/dev/null 2>&1; then fail "S1c inject 断电应 rc1"; else ok "S1c inject 断电 rc1"; fi
# S1d alive：目录命中/不命中；delegated 过滤＝目录命中 ∧ title 前缀 "agora: gt-"（委托子会话机械锚 gt-2845②/gt-0ed3）
echo "$PROJ" > "$FAKE_HOME/active_dir"; : > "$FAKE_HOME/active_title"; fake_reset none
if FAKE alive "$PROJ" >/dev/null 2>&1; then ok "S1d alive 命中 rc0"; else fail "S1d alive 命中"; fi
if FAKE alive "$PROJ" delegated >/dev/null 2>&1; then fail "S1d alive delegated 交互会话(title空)应 rc1"; else ok "S1d alive delegated 交互会话(title空) rc1"; fi
printf 'agora: gt-abc1 标题甲' > "$FAKE_HOME/active_title"
if FAKE alive "$PROJ" delegated >/dev/null 2>&1; then ok "S1d alive delegated 委托 title 命中 rc0"; else fail "S1d alive delegated 委托 title 命中"; fi
echo /nonexist > "$FAKE_HOME/active_dir"
if FAKE alive "$PROJ" delegated >/dev/null 2>&1; then fail "S1d alive delegated 不命中应 rc1"; else ok "S1d alive delegated 不命中 rc1"; fi
# S1d done 残留（gt-762a）：delegated title 命中但 outcome=succeeded → 不在场（worker 退场残留不算）
echo "$PROJ" > "$FAKE_HOME/active_dir"; echo succeeded > "$FAKE_HOME/active_outcome"
if FAKE alive "$PROJ" delegated >/dev/null 2>&1; then fail "S1d alive delegated done残留(outcome=succeeded)应 rc1"; else ok "S1d alive delegated done残留 rc1"; fi
rm -f "$FAKE_HOME/active_outcome"; echo /nonexist > "$FAKE_HOME/active_dir"   # 清场回「不命中」形态
# S1e status：idle/dead 归一
fake_reset none
[ "$(FAKE status ses_x 2>/dev/null)" = "idle" ] && ok "S1e status idle" || fail "S1e status idle"
fake_reset status_dead
[ "$(FAKE status ses_x 2>/dev/null)" = "dead" ] && ok "S1e status dead" || fail "S1e status dead"
# S1g abort：POST /api/session/<sid>/interrupt（C 二期 gt-0a34 spike：v2.1.2 openapi 实证端点在场）
fake_reset none
FAKE abort ses_fake9 >/dev/null 2>&1
grep -q "api POST /api/session/ses_fake9/interrupt" "$FAKE_HOME/calls.log" \
  && ok "S1g abort 契约 POST /session/{id}/interrupt" || fail "S1g abort（$(tail -1 "$FAKE_HOME/calls.log" 2>/dev/null)）"

# ---- T2: dispatch API 通道（sid 落账 / 回落零残留 / 凭据预写不变 / inject 败兜底） ----
POSTD() { PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" AGORA_MAX_SPAWN=99 AGORA_RUNTIME_API=1 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" "$@"; }
T2A=$(TID "$(TITLE="API派生" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
fake_reset none
OUT=$(POSTD --task "$T2A")
echo "$OUT" | grep -q '"channel":"api"' && echo "$OUT" | grep -q '"session":"ses_' \
  && ok "S2a API 派生输出 channel+session" || fail "S2a API 派生输出（got: $OUT）"
LEV "$T2A" dispatched | grep -q 'session:ses_' && ok "S2a sid 落账 session:ses_*" || fail "S2a sid 落账"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); t=d.get("title",""); sys.exit(0 if t.startswith("agora: "+sys.argv[2]+" ") and t.endswith("API派生") and len(t.split(" ",2)[2])<=60 else 1)' "$FAKE_HOME/create_body.json" "$T2A" \
  && ok "S2e create title 格式 agora: <task> <title截60>" || fail "S2e create title 格式（$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("title",""))' "$FAKE_HOME/create_body.json" 2>/dev/null)）"
T2B=$(TID "$(TITLE="API回落" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
fake_reset health_fail
OUT=$(POSTD --task "$T2B")
echo "$OUT" | grep -q '"channel":"api"' && fail "S2b health_fail 未回落 run" || ok "S2b health_fail 回落 run"
[ "$(LEV "$T2B" dispatched | wc -l)" = 1 ] && LEV "$T2B" dispatched | grep -q 'session:ses_' \
  && ok "S2b 回落零残留＋sid 统一承载（恰一条 dispatched 含 session:ses_*）" || fail "S2b 回落残留/sid 缺失"
RUN2B=$(echo "$OUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')
grep -q "^EXIT:1=0" "$AGORA_HOME/$RUN2B" 2>/dev/null && ok "S2b run 通道 EXIT:1=0" || fail "S2b run EXIT 缺失"
SID2B=$(LEV "$T2B" dispatched | sed -n 's/.*session:\(ses_[^| ]*\).*/\1/p')
grep -q -- "--session $SID2B" "$FAKE_HOME/calls.log" 2>/dev/null \
  && grep -q -- "--title agora: $T2B " "$FAKE_HOME/calls.log" \
  && ok "S2b run --session 落预生成 sid＋--title 同名（与账本一致）" || fail "S2b run 参数与账本 sid 不一致"
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
POSTI() { PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" bash "$PKG/scripts/post.sh" --actor "$1" --project "${1#*@}" "${@:2}"; }
T3A=$(TID "$(TITLE="ack注入" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T3A" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t3a.log" --session ses_t3a >/dev/null
fake_reset none
POSTI tester@proj --event ack --task "$T3A" --body "plan ack 放行" >/dev/null
grep -q "PROMPT-OK" "$FAKE_HOME/calls.log" 2>/dev/null \
  && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("text")=="ack 已落账，继续" and d.get("delivery")=="queue" else 1)' "$FAKE_HOME/last_prompt.json" \
  && ok "S3a ack 触发 inject（ack 已落账，继续 / queue）" || fail "S3a ack 未触发 inject"
# S3b: inject 失败 best-effort 不阻塞
T3B=$(TID "$(TITLE="ack注入败" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T3B" \
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
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T3D" \
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
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
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
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4U" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4u.log" --session ses_up1 >/dev/null
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4D" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4d.log" --dispatcher-task "$T4U" >/dev/null
POST tester@proj --event done --task "$T4D" --commit HEAD --evidence ok >/dev/null
POLL4() { PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 \
  AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=99 AGORA_REDISPATCH_MAX=99 AGORA_RUNTIME=opencode AGORA_RUNTIME_API=1 bash "$PKG/scripts/poll.sh" 2>/dev/null; }
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
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4U2" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4u2.log" >/dev/null
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4D2" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4d2.log" --dispatcher-task "$T4U2" >/dev/null
POST tester@proj --event done --task "$T4D2" --commit HEAD --evidence ok >/dev/null
fake_reset none
OUT=$(PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=9999 AGORA_WT_GRACE_MIN=9999 \
  AGORA_DISPATCH_TIMEOUT=9999 AGORA_MAX_SPAWN=99 AGORA_REDISPATCH_MAX=99 AGORA_RUNTIME=echo bash "$PKG/scripts/poll.sh" 2>/dev/null)
echo "$OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); tid=sys.argv[1]
sys.exit(0 if any(e.get("upstream")==tid and e.get("mode")=="spawned" for e in d.get("redispatched",[])) else 1)' "$T4U2" \
  && ok "S4c 无 session 直接重派" || fail "S4c 无 session 行为回归（got: $OUT）"
# S4d: 上游 wt_host≠本机 → 不注入（跨机判则）回落重派（独立对子——mw 状态按任务共享，勿复用 S4a/b 的）
T4U3=$(MKWT2 "跨机上游" t4x); T4D3=$(MKWT2 "跨机下游" t4y)
W4D3=$(ls -d "$T"/proj__wt-${T4D3}__*); echo v > "$W4D3/vfile"; git -C "$W4D3" add -A; git -C "$W4D3" -c user.name=t -c user.email=t@l commit -qm t4d3   # 真未合并态（gt-99af）
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4U3" \
  --target "$PROJ" --child tester --run "raw/dispatches/d-t4u3.log" --session ses_up3 >/dev/null
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$T4D3" \
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

# ---- T5: 在场 API 化（alive delegated＝仅认委托子会话；交互占坑直接 spawn gt-0ed3；wt 无条件 spawn 豁免不动） ----
T5A=$(TID "$(TITLE="交互占坑" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
echo "$PROJ" > "$FAKE_HOME/active_dir"; : > "$FAKE_HOME/active_title"; fake_reset none
OUT=$(POSTD --task "$T5A")
echo "$OUT" | grep -q '"mode":"spawned"' && ok "S5a 交互会话占坑（title 空）→直接 spawn" || fail "S5a 交互占坑未 spawn（got: $OUT）"
T5A2=$(TID "$(TITLE="委托占坑" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
printf 'agora: %s 委托占坑' "$T5A2" > "$FAKE_HOME/active_title"
OUT=$(POSTD --task "$T5A2")
echo "$OUT" | grep -q '"mode":"notified"' && ok "S5a2 委托子会话（title agora: gt-）占坑→notified" || fail "S5a2 委托占坑未通知（got: $OUT）"
[ -z "$(LEV "$T5A2" dispatched)" ] && ok "S5a2 notified 零 dispatched 落账" || fail "S5a2 notified 却落了 dispatched"
T5A3=$(TID "$(TITLE="done残留占坑" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
echo succeeded > "$FAKE_HOME/active_outcome"   # gt-762a：done 残留形态（title 不变＋outcome=succeeded）
OUT=$(POSTD --task "$T5A3")
echo "$OUT" | grep -q '"mode":"spawned"' && ok "S5a3 委托占坑 done 残留（outcome=succeeded）→spawn" || fail "S5a3 done 残留未 spawn（got: $OUT）"
rm -f "$FAKE_HOME/active_outcome"
T5B=$(TID "$(TITLE="alive缺席" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
echo /nonexist > "$FAKE_HOME/active_dir"
OUT=$(POSTD --task "$T5B")
echo "$OUT" | grep -q '"mode":"spawned"' && ok "S5b alive 缺席→正常 spawn" || fail "S5b alive 缺席未 spawn（got: $OUT）"
T5C=$(MKWT2 "wt在场" t5c); WR5C=$(ls -d "$T"/proj__wt-${T5C}__*)
echo "$PROJ" > "$FAKE_HOME/active_dir"
OUT=$(POSTD --task "$T5C")
echo "$OUT" | grep -q '"mode":"spawned"' && [ -f "$WR5C/.omo/agora-delegation/$T5C.md" ] \
  && ok "S5c wt 任务 alive 命中仍无条件 spawn" || fail "S5c wt 在场豁免失效（got: $OUT）"
T5D=$(TID "$(TITLE="API关占坑" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
printf '%s tester ses_legacy %s\n' "$(hostname)" "$(date +%s)" >> "$AGORA_HOME/sessions.map"
OUT=$(PATH="$FAKEDIR:$PATH" FAKE_HOME="$FAKE_HOME" AGORA_MAX_SPAWN=99 AGORA_RUNTIME_API=0 AGORA_RUNTIME=opencode bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$T5D")
echo "$OUT" | grep -q '"mode":"spawned"' && ok "S5d API 关（桥同不可达）sessions.map 不算在场→直接 spawn" || fail "S5d 应直接 spawn（got: $OUT）"
sed -i "\|$(hostname) tester ses_legacy|d" "$AGORA_HOME/sessions.map"   # 清场：勿污染后续

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

# ---- T7: iter_events 点分片盲——history 读面漏 .dotfiles.md 等隐藏分片（gt-6fef，gt-bb0b 复盘） ----
# 构造：点前缀项目分片（.dotfiles.md）落 plan/claimed/done；修复前 glob 漏读致 history 全链断链
DOTSHARD="$AGORA_HOME/log/$(date +%F)/.dotfiles.md"
mkdir -p "$(dirname "$DOTSHARD")"   # 跨午夜翻牌防 cat >> 静默失败（同 T6）
cat >> "$DOTSHARD" <<EOF
- seq:99101 | ts:2026-10-23T19:00:00+08:00 | actor:me@.dotfiles | event:plan | idem:dotf1p | seen:.dotfiles@0 | task:gt-dotf1 | body:点分片计划
- seq:99102 | ts:2026-10-23T19:01:00+08:00 | actor:me@.dotfiles | event:claimed | idem:dotf1c | seen:.dotfiles@0 | task:gt-dotf1
- seq:99103 | ts:2026-10-23T19:02:00+08:00 | actor:me@.dotfiles | event:done | idem:dotf1d | seen:.dotfiles@0 | task:gt-dotf1 | commit:abc1234 | evidence:点分片交付
EOF
# ① iter_events 直读面：点分片内事件可产出
PYTHONPATH="$PKG/scripts" AGORA_HOME="$AGORA_HOME" python3 -c "
import os
import agora_lib as lib
evs = [e.get('event') for _, _, e in lib.iter_events(os.environ['AGORA_HOME'])
       if e.get('task') == 'gt-dotf1']
assert evs == ['plan', 'claimed', 'done'], evs
" && ok "T7 iter_events 产出点分片事件" || fail "T7 iter_events 产出点分片事件"
# ② history.sh 端到端：点分片项目任务返回全链（plan/claimed/done），非空断链
TASK=gt-dotf1 bash "$PKG/scripts/history.sh" | python3 -c "
import json, sys
d = json.load(sys.stdin)
evs = [e['event'] for e in d['events']]
refs = {e['ref'].rsplit(':', 1)[0] for e in d['events']}
assert d['count'] == 3 and evs == ['plan', 'claimed', 'done'], d
assert all(r.endswith('/.dotfiles.md') for r in refs), refs
" && ok "T7 history.sh 点分片任务全链可见（plan/claimed/done）" || fail "T7 history.sh 点分片任务全链可见"

echo
echo "===== A批 K3（gt-2845）：verify 锚点重建＋task_create 防呆＋BOOT 文案＋MAX_DEPTH5 ====="
# ① verify 锚点重建：删树→done 时原地重建（复用 dispatch/merge 锚点逻辑）
R1=$(MKWT2 "锚点重建" gtr1); WR1=$(ls -d "$T"/proj__wt-${R1}__*)
rm -rf "$WR1"
POST tester@proj --event done --task "$R1" --commit HEAD --evidence ok >/dev/null 2>&1
[ -d "$WR1" ] && [ "$(LEV "$R1" done | wc -l)" = 1 ] \
  && ok "verify 锚点重建：删树后 done 原地重建＋verify 真跑" || fail "verify 锚点重建成功路径（树在: [ -d $WR1 ]）"
# ① 双缺失失败路径：树删＋分支删→VERIFY_FAILED 不回退 project_dir
R2=$(MKWT2 "双缺失" gtr2); WR2=$(ls -d "$T"/proj__wt-${R2}__*)
rm -rf "$WR2"; git -C "$PROJ" worktree prune; git -C "$PROJ" branch -D "wt/$R2" >/dev/null 2>&1
OUT=$(POST tester@proj --event done --task "$R2" --commit HEAD --evidence ok 2>&1); RC=$?
[[ $RC -ne 0 ]] && echo "$OUT" | grep -q VERIFY_FAILED && [ ! -d "$WR2" ] \
  && ok "verify 双缺失：VERIFY_FAILED 明确报错（禁回退 project_dir）" || fail "verify 双缺失路径（rc=$RC out=$OUT）"
# ④ task_create 防呆：worktree 形态 project_dir 未带 wt＋title<8 字 → warnings 不阻断
mkdir -p "$T/fk__wt-x"; touch "$T/fk__wt-x/.git"; mkdir -p "$T/fk"
OUT=$(TITLE="短" VERIFY="true" PROJECT_DIR="$T/fk__wt-x" TC); RC=$?
TIDW=$(echo "$OUT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
[[ $RC -eq 0 ]] && [[ "$TIDW" =~ ^gt- ]] && echo "$OUT" | grep -q '__wt-' \
  && echo "$OUT" | grep -q '\.git 为文件' && echo "$OUT" | grep -q 'title 少于 8 字' \
  && [ -f "$AGORA_HOME/wiki/tasks/$TIDW.md" ] \
  && ok "task_create 防呆：两告警触发＋不阻断" || fail "task_create 防呆（rc=$RC out=$OUT）"
OUT=$(TITLE="足够长的正常标题" VERIFY="true" PROJECT_DIR="$T/fk" TC)
echo "$OUT" | grep -q 'warnings' && fail "task_create 防呆误触发（$OUT）" || ok "task_create 干净输入零 warnings"
# ⑥ BOOT 文案（gt-6bef 轮询语义）：plan 落账后回合保持活跃轮询等 ack（双通道＋心跳＋自放行），「即开工不等 ack」死锁文案删除
B1=$(TID "$(TITLE="BOOT文案任务标题够长" VERIFY=true PROJECT_DIR="$PROJ" TC)")
BOUT=$(AGORA_RUNTIME=echo AGORA_MAX_SPAWN=99 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$B1")
RLOG="$AGORA_HOME/$(echo "$BOUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')"
grep -q "轮询等 ack" "$RLOG" && grep -q "agora_check_mail" "$RLOG" && grep -q "自放行" "$RLOG" && grep -q "commit 前重读账本" "$RLOG" && ! grep -q "即开工不等 ack" "$RLOG" \
  && ok "BOOT 文案对齐 gt-6bef 轮询语义（等 ack＝不可逆前置保险）" || fail "BOOT 文案未对齐（$RLOG, out=$BOUT)"
# ⑧ 截断触达＋无 title 行回退（评审 ocr-8：[:60] 此前从未被超长输入触达）
T70=$(printf '甲%.0s' $(seq 1 70))
L1=$(TID "$(TITLE="$T70" VERIFY=true PROJECT_DIR="$PROJ" TC)")
LOUT=$(AGORA_RUNTIME=echo AGORA_MAX_SPAWN=99 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$L1")
LLOG="$AGORA_HOME/$(echo "$LOUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')"
python3 -c 'import re,sys
line=[l for l in open(sys.argv[1],encoding="utf-8") if l.startswith("run --auto")][0]
t=re.search(r"--title agora: (gt-[0-9a-f]+) (\S+)",line).group(2)
sys.exit(0 if len(t)==60 and set(t)=={"甲"} else 1)' "$LLOG" \
  && ok "create/run title 截 60 码点（70 字输入→恰 60）" || fail "title 截断断言（$LLOG）"
NT=$(TID "$(TITLE="无title行回退任务" VERIFY=true PROJECT_DIR="$PROJ" TC)")
sed -i '/^title:/d' "$AGORA_HOME/wiki/tasks/$NT.md"
NOUT=$(AGORA_RUNTIME=echo AGORA_MAX_SPAWN=99 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$NT")
NLOG="$AGORA_HOME/$(echo "$NOUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')"
grep -q -- "--title agora: $NT " "$NLOG" \
  && ok "无 title 行→CTITLE 回退 agora: <task>（--title 恒非空）" || fail "无 title 行回退（$NLOG, out=$NOUT）"
# ⑤ MAX_DEPTH 默认5：代码＋规格＋设计＋README 四处一致
grep -q 'AGORA_MAX_DEPTH:-5' "$PKG/scripts/dispatch.sh" && ! grep -q 'AGORA_MAX_DEPTH:-3' "$PKG/scripts/dispatch.sh" \
  && grep -q 'AGORA_MAX_DEPTH=5' "$PKG/docs/Agora接口规格-v1.md" "$PKG/docs/全量委托设计-v1.md" \
  && ! grep -q 'AGORA_MAX_DEPTH=3' "$PKG/docs/Agora接口规格-v1.md" "$PKG/docs/全量委托设计-v1.md" \
  && grep -q 'AGORA_MAX_DEPTH` (default 5)' "$PKG/README.md" \
  && ! grep -q '（默认 2）时拒绝' "$PKG/docs/Agora接口规格-v1.md" \
  && ok "MAX_DEPTH 默认5：代码＋规格＋设计＋README 同步一致" || fail "MAX_DEPTH 默认值同步不一致"

echo "===== 守卫v2批（gt-ae6f）：mention 拾取环断路＋BOOT 心跳 ====="
POLLV2() { AGORA_MERGE_WAIT_MIN=0 AGORA_ORPHAN_MIN=0 AGORA_WT_GRACE_MIN=0 AGORA_DISPATCH_TIMEOUT=0 \
           AGORA_VERIFY_WIN=2 AGORA_MAX_SPAWN=99 AGORA_RUNTIME=true bash "$PKG/scripts/poll.sh" 2>/dev/null; }
# ① 拾取守卫：done_open（done 未合并）任务 mention 邮件 → 零派发＋held，水位照常推进
G1=$(TID "$(TITLE="守卫一done未合并任务标题够长" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$G1" >/dev/null
POST tester@proj --event done --task "$G1" --commit HEAD --evidence ok >/dev/null
POST rival@proj2 --event progress --task "$G1" --mention tester --body "done 单回声邮件" >/dev/null
GOUT=$(POLLV2)
echo "$GOUT" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert not any(s['task']=='$G1' for s in r['spawned']), r['spawned']
h=[x for x in r['held'] if x['task']=='$G1']
assert h and 'done' in h[0]['reason'], r['held']
" && ok "守卫一：done_open 邮件零派发＋held" || fail "守卫一 done_open（$GOUT）"
GOUT=$(POLLV2)
echo "$GOUT" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert not any(x['task']=='$G1' for x in r['held']+r['spawned']), r
" && ok "守卫一：水位照常推进（二轮零重现）" || fail "守卫一 水位未推进（$GOUT）"
# ② 在飞去重：同任务一轮多封邮件至多一派＋held
G2=$(TID "$(TITLE="守卫二在飞去重任务标题够长" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST rival@proj2 --event progress --task "$G2" --mention tester --body "第一封" >/dev/null
POST rival@proj2 --event progress --task "$G2" --mention tester --body "第二封" >/dev/null
GOUT=$(POLLV2)
echo "$GOUT" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert len([s for s in r['spawned'] if s['task']=='$G2'])==1, r['spawned']
h=[x for x in r['held'] if x['task']=='$G2']
assert h and '在飞去重' in h[0]['reason'], r['held']
" && ok "守卫二：一轮双邮件至多一派＋held" || fail "守卫二 在飞去重（$GOUT）"
# ④ derive-board 一致：owner retired 不把 done 任务踢回 todo（gt-bb0b 风暴根因）
# 注：须先于③执行——retired 是 actor 终态，tester 一经 retired 其后 claimed/done 全被 derive 丢弃
G4=$(TID "$(TITLE="守卫四done不入todo任务标题够长" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$G4" >/dev/null
POST tester@proj --event done --task "$G4" --commit HEAD --evidence ok >/dev/null
POST tester@proj --event retired --task "$G4" --reason "收工" >/dev/null
bash "$PKG/scripts/derive-board.sh"
! grep -q "^- $G4" "$AGORA_HOME/board/todo.md" \
  && ok "守卫四：owner retired 后 done 任务不入 todo（视图与守卫一致）" || fail "守卫四 done 被 retired 踢回 todo"
# ③ retired 降敏：RECHECK 派发会话 retired → 回声邮件下轮零新派＋held
G3=$(TID "$(TITLE="守卫三retired降敏任务标题够长" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST rival@proj2 --event progress --task "$G3" --mention tester --body "首派触发" >/dev/null
POLLV2 >/dev/null
POST tester@proj --event retired --task "$G3" --reason "RECHECK 收工：已被他人认领" --mention tester >/dev/null
GOUT=$(POLLV2)
echo "$GOUT" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert not any(s['task']=='$G3' for s in r['spawned']), r['spawned']
h=[x for x in r['held'] if x['task']=='$G3']
assert h and 'retired' in h[0]['reason'], r['held']
" && ok "守卫三：RECHECK→retired→下轮零新派＋held" || fail "守卫三 retired 降敏（$GOUT）"
# ⑤ BOOT 心跳卫生：认领即 claimed＋每里程碑或每 30min progress（gt-ef79/gt-2e1c 实证）
grep -q "认领即 agora_post(event=claimed" "$PKG/scripts/dispatch.sh" \
  && grep -q "每完成一个里程碑或每 30min agora_post(event=progress" "$PKG/scripts/dispatch.sh" \
  && ok "守卫五：BOOT 文案含认领即 claimed＋每 30min progress 心跳" || fail "守卫五 BOOT 心跳文案缺失"

# ⑥ reopened 返工再拾取回归（终闸 B-F1 修复）：dispatched→done→reopened 后 mention 邮件可再派——
# 在飞去重只认「末次 reopened 后且未被终态闭合」的 dispatched，返工回池不得被 dispatched 历史永久压制。
# 夹具序（wave-1 R2 教训同源）：reopened 须由 owner（rival@proj2）发出——done/reopened 跨分片同秒
# 无因果序（derive 按分片文件序、scan 按 ts 平局文件序，双双会把 reopened 重放在 done 前）
G6=$(TID "$(TITLE="守卫六reopened返工再拾取任务标题够长" VERIFY=true PROJECT_DIR="$PROJ" TC)")
AGORA_RUNTIME=true AGORA_VERIFY_WIN=2 AGORA_MAX_SPAWN=99 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$G6" >/dev/null 2>&1
POST rival@proj2 --event claimed --task "$G6" >/dev/null
POST rival@proj2 --event done --task "$G6" --commit HEAD --evidence ok >/dev/null
POST rival@proj2 --event reopened --task "$G6" --reason "返工重开" >/dev/null
POST rival@proj2 --event progress --task "$G6" --mention tester --body "返工请接单" >/dev/null
GOUT=$(POLLV2)
echo "$GOUT" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert any(s['task']=='$G6' for s in r['spawned']), r['spawned']
" && ok "守卫六：reopened 返工任务可再拾取（不被在飞去重永久压制）" || fail "守卫六 reopened 再拾取（$GOUT）"
# ⑦ 心跳在飞回归（第四波口径判别断言）：dispatched→progress 心跳期间回声邮件 → held 在飞去重——
# 尾部口径（last==dispatched）对此漏放（重派在飞任务），累计口径与本口径均 held
G7=$(TID "$(TITLE="守卫七心跳在飞去重任务标题够长" VERIFY=true PROJECT_DIR="$PROJ" TC)")
AGORA_RUNTIME=true AGORA_VERIFY_WIN=2 AGORA_MAX_SPAWN=99 bash "$PKG/scripts/dispatch.sh" --actor tester@proj --project "$PROJ" --task "$G7" >/dev/null 2>&1
POST rival@proj2 --event progress --task "$G7" --mention tester --body "心跳回声" >/dev/null
GOUT=$(POLLV2)
echo "$GOUT" | python3 -c "
import json,sys
r=json.loads(sys.stdin.read())
assert not any(s['task']=='$G7' for s in r['spawned']), r['spawned']
h=[x for x in r['held'] if x['task']=='$G7']
assert h and '在飞去重' in h[0]['reason'], r['held']
" && ok "守卫七：心跳在飞（dispatched→progress）回声零派＋held" || fail "守卫七 心跳在飞（$GOUT）"

echo "===== gt-5a59：derive merged handler＋blocked 前置守卫 ====="
# 迁移矩阵（任务页合同三用例＋retired 盲化回归）：①claimed→merged 离场（「state 任意→done」甄别形；
# 任务页字面 done→merged 不可甄别——done 已终态 handler 缺席也离场，故取无 done 形，⑥b 覆盖 todo→merged、
# ③覆盖 done→reopened→todo→merged）②done→blocked 不入 blocked 栏（gt-40cc）③done→reopened→todo→merged
# 离场（gt-35b5 sweep 补账生效；reopened 同片落账保因果序，ocr-R1#4）——merged 走机械票（F7 形态）
MB1=$(TID "$(TITLE="g5a59甲claimed后merged离场" VERIFY=true PROJECT_DIR="$PROJ" TC)")
MB2=$(TID "$(TITLE="g5a59乙done后blocked守卫" VERIFY=true PROJECT_DIR="$PROJ" TC)")
MB3=$(TID "$(TITLE="g5a59丙重开后merged离场" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$MB1" >/dev/null
POST tester@proj --event claimed --task "$MB2" >/dev/null
POST tester@proj --event done --task "$MB2" --commit HEAD --evidence ok >/dev/null
POST tester@proj --event claimed --task "$MB3" >/dev/null
POST tester@proj --event done --task "$MB3" --commit HEAD --evidence ok >/dev/null
# ocr-R1#4：reopened 必须与 done/merged 同分片（POST 助手按 actor 后缀路由分片，watchdog@$(hostname)
# 会落他片破坏因果序）——显式 --project proj 同片落账
bash "$PKG/scripts/post.sh" --actor watchdog@proj --project proj --event reopened --task "$MB3" --reason "done-unmerged 阶梯拖回 todo（gt-35b5 形态）" >/dev/null
tick "$MB1"; POST tester@proj --event merged --task "$MB1" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null; untick "$MB1"
POST tester@proj --event blocked --task "$MB2" --reason "合并冲突" >/dev/null
tick "$MB3"; POST tester@proj --event merged --task "$MB3" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null; untick "$MB3"
bash "$PKG/scripts/derive-board.sh"
! grep -q "$MB1" "$AGORA_HOME/board/in-progress.md" 2>/dev/null \
  && python3 -c "import json;c=json.load(open('$AGORA_HOME/.git/derive-cache.json'));assert c['tasks']['$MB1']['state']=='done'" \
  && ok "① claimed→merged 落终态（state==done，离 in-progress）" || fail "① merged 未落终态（$MB1）"
! grep -q "$MB2" "$AGORA_HOME/board/blocked.md" 2>/dev/null \
  && ok "② done 后 blocked 不入 blocked 栏（前置守卫）" || fail "② done 被拖进 blocked（gt-40cc，$MB2）"
! grep -q "$MB3" "$AGORA_HOME/board/todo.md" \
  && ok "③ reopened→todo→merged 离场（sweep 补账生效）" || fail "③ merged 后永驻 todo（gt-35b5，$MB3）"
# ⑤ v4→v5 迁移自愈（ocr-R1#6 gt-0105 先例；gt-8fe1 起当前版 v5）：毒化 v4 缓存（done 任务拨回 todo）→ derive 须作废缓存全量重放补账
python3 -c "
import json
f = '$AGORA_HOME/.git/derive-cache.json'
c = json.load(open(f))
c['v'] = 4; c['tasks']['$MB3']['state'] = 'todo'
json.dump(c, open(f, 'w'))"
bash "$PKG/scripts/derive-board.sh"
! grep -q "$MB3" "$AGORA_HOME/board/todo.md" \
  && python3 -c "import json;c=json.load(open('$AGORA_HOME/.git/derive-cache.json'));assert c['v']==5" \
  && ok "⑤ 毒化 v4 缓存被作废：全量重放自愈＋v5" || fail "⑤ 旧缓存未自愈（$MB3 滞留或版本未翻新）"
# ④ retired 盲化回归：收工会话误发 retired 把共享 actor 整体拉黑（真账本实证 126 条），其后的
# 机械 merged 补账不得被盲——merged 是 merge.sh 机械票终态，非 actor 任务主张
# 注意：此后本套件 AGORA_HOME 内 agora-mcp@proj 被 derive 永久盲化（retired 不可逆），勿再以该
# actor 发状态事件（ocr-R1#3 脚枪标注）
OUT4=$(POST agora-mcp@proj --event retired --task "$MB3" --reason "收工演练（污染共享 actor）")
echo "$OUT4" | grep -q '"seq"' || fail "④ 前置：retired 落账失败（$OUT4）"
MB4=$(TID "$(TITLE="g5a59丁退休actor补merged" VERIFY=true PROJECT_DIR="$PROJ" TC)")
POST tester@proj --event claimed --task "$MB4" >/dev/null
POST tester@proj --event done --task "$MB4" --commit HEAD --evidence ok >/dev/null
bash "$PKG/scripts/post.sh" --actor watchdog@proj --project proj --event reopened --task "$MB4" --reason "阶梯拖回 todo" >/dev/null
tick "$MB4"; POST agora-mcp@proj --event merged --task "$MB4" --commit "$(git -C "$PROJ" rev-parse HEAD)" --branch "$(git -C "$PROJ" symbolic-ref --short HEAD)" >/dev/null; untick "$MB4"
bash "$PKG/scripts/derive-board.sh"
! grep -q "$MB4" "$AGORA_HOME/board/todo.md" \
  && ok "④ retired 后机械 merged 仍闭环离场（不过滤）" || fail "④ retired 盲化机械终态（$MB4）"

echo
echo "===== 多仓关联测试场（B批 gt-2153）：跨仓链/删树重建/中途 cancelled/深度边界＋teardown 竞态 ====="
# 纯 stub/fake runtime 离线跑；MAX_DEPTH 用 env 显式控制；夹具全在 mktemp $T 内，不触真实账本
BREMOTE="$T/b-remote.git"; git init -q --bare "$BREMOTE"
AGORA_REMOTE="file://$BREMOTE" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
REPA="$T/repa"; REPB="$T/repb"; REPC="$T/repc"
for _r in "$REPA" "$REPB" "$REPC"; do
  mkdir -p "$_r"; (cd "$_r" && git init -q . && echo FIXED > app.txt && git add -A && git -c user.name=t -c user.email=t@local commit -qm init)
done
mkdir -p "$AGORA_HOME/wiki/entities"
printf -- '---\nname: borch\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$REPA" > "$AGORA_HOME/wiki/entities/borch.md"
printf -- '---\nname: bmid\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$REPB" > "$AGORA_HOME/wiki/entities/bmid.md"
printf -- '---\nname: bleaf\ndirs:\n  - %s\ncan_spawn: false\n---\n' "$REPC" > "$AGORA_HOME/wiki/entities/bleaf.md"
(cd "$AGORA_HOME" && git add -A && AGORA_MECHANICAL=1 git commit -qm "entities B批测试场" >/dev/null)
BRANCH=$(git -C "$AGORA_HOME" symbolic-ref --short HEAD)
[ "$(git -C "$AGORA_HOME" remote get-url origin)" = "file://$BREMOTE" ] \
  && git -C "$BREMOTE" show-ref --verify -q "refs/heads/$BRANCH" \
  && ok "测试场远端：file:// bare 经 init.sh AGORA_REMOTE 配置＋push 落 bare" || fail "测试场远端 file://（origin=$(git -C "$AGORA_HOME" remote get-url origin 2>&1)）"
OUT=$(AGORA_REMOTE="https://agora.example/acme/agora.git" bash "$PKG/scripts/init.sh" 2>&1); RC=$?
[[ $RC -eq 1 ]] && echo "$OUT" | grep -q "拒绝非 SSH 远端" && [ "$(git -C "$AGORA_HOME" remote get-url origin)" = "file://$BREMOTE" ] \
  && ok "装饰 https URL 被 init.sh 拒绝（rc=1，origin 不动，不实际推送）" || fail "装饰 https URL 处理（rc=$RC out=$OUT）"
BDSP() { AGORA_RUNTIME=echo AGORA_MAX_SPAWN=99 bash "$PKG/scripts/dispatch.sh" "$@"; }

# ① 同仓链 a→b→c→…（dtask 显式链）：MAX_DEPTH=5 下 depth1..4 全放行，NEXT=5 DEPTH_EXCEEDED；env 显式收紧提前拒
SA=$(TID "$(TITLE="同仓链根a标题够长" VERIFY=true PROJECT_DIR="$REPA" TC)")
POST borch@repa --event claimed --task "$SA" >/dev/null
SB=$(TID "$(TITLE="同仓链b标题够长" VERIFY=true PROJECT_DIR="$REPA" TC)")
SC=$(TID "$(TITLE="同仓链c标题够长" VERIFY=true PROJECT_DIR="$REPA" TC)")
SD=$(TID "$(TITLE="同仓链d标题够长" VERIFY=true PROJECT_DIR="$REPA" TC)")
SE=$(TID "$(TITLE="同仓链e标题够长" VERIFY=true PROJECT_DIR="$REPA" TC)")
SF=$(TID "$(TITLE="同仓链f标题够长" VERIFY=true PROJECT_DIR="$REPA" TC)")
SG=$(TID "$(TITLE="同仓链g标题够长" VERIFY=true PROJECT_DIR="$REPA" TC)")
BDSP --actor borch@repa --project "$REPA" --task "$SB" >/dev/null 2>&1                                # dt机械=SA, depth1
BDSP --actor borch@repa --project "$REPA" --task "$SC" --dispatcher-task "$SB" >/dev/null 2>&1        # depth2
BDSP --actor borch@repa --project "$REPA" --task "$SD" --dispatcher-task "$SC" >/dev/null 2>&1        # depth3
BDSP --actor borch@repa --project "$REPA" --task "$SE" --dispatcher-task "$SD" >/dev/null 2>&1        # depth4
LEV "$SE" dispatched | grep -q "dispatcher_task:$SD" \
  && ok "同仓链 a→b→c→d→e 四层派发全落账（dtask 链完整）" || fail "同仓链 dtask 落账缺失"
BDSP --actor borch@repa --project "$REPA" --task "$SF" --dispatcher-task "$SE" 2>&1 | grep -q DEPTH_EXCEEDED \
  && ok "深度边界：MAX_DEPTH=5 链深 NEXT=5 DEPTH_EXCEEDED（到顶）" || fail "深度边界 NEXT=5 未拒"
OUT=$(AGORA_MAX_DEPTH=3 BDSP --actor borch@repa --project "$REPA" --task "$SG" --dispatcher-task "$SC" 2>&1)
echo "$OUT" | grep -q DEPTH_EXCEEDED \
  && ok "env 显式 MAX_DEPTH=3：第 4 层（dtask=SC 链深 3）拒" || fail "env 显式边界未拒（$OUT）"

# ② 跨仓链 a 派 b 仓任务，b 再派 c 仓任务：dtask 机械推导＋账本链可重放
TA=$(TID "$(TITLE="跨仓链根a标题够长" VERIFY=true PROJECT_DIR="$REPA" TC)")
POST borch@repa --event claimed --task "$TA" >/dev/null
TB=$(TID "$(TITLE="跨仓b仓任务标题够长" VERIFY=true PROJECT_DIR="$REPB" WT=1 IDEM=btb TC)")
WRTB=$(ls -d "$T"/repb__wt-${TB}__* 2>/dev/null | head -1)
[ -d "$WRTB" ] && ok "跨仓 b 树随 task_create 建立（wt_dir 登记）" || fail "跨仓 b 树缺失"
OUT=$(BDSP --actor borch@repa --project "$REPB" --task "$TB")
echo "$OUT" | grep -q '"mode":"spawned"' && echo "$OUT" | grep -q '"child_actor":"bmid@repb"' \
  && ok "跨仓链 a 派 b 仓任务（child=bmid@repb 机械解析）" || fail "跨仓 a→b 派发（$OUT）"
POST bmid@repb --event claimed --task "$TB" >/dev/null
TC=$(TID "$(TITLE="跨仓c仓任务标题够长" VERIFY=true PROJECT_DIR="$REPC" TC)")
OUT=$(BDSP --actor bmid@repb --project "$REPC" --task "$TC")
echo "$OUT" | grep -q '"mode":"spawned"' && echo "$OUT" | grep -q '"child_actor":"bleaf@repc"' \
  && ok "跨仓链 b 再派 c 仓任务（child=bleaf@repc）" || fail "跨仓 b→c 派发（$OUT）"
LEV "$TB" dispatched | head -1 | grep -q "dispatcher_task:$TA" && LEV "$TB" dispatched | head -1 | grep -qF "target:$REPB" \
  && ok "账本：TB dispatched 含 dispatcher_task:$TA＋target:repb" || fail "TB 账本链缺失"
LEV "$TC" dispatched | grep -q "dispatcher_task:$TB" && LEV "$TC" dispatched | grep -qF "target:$REPC" \
  && ok "账本：TC dispatched 含 dispatcher_task:$TB＋target:repc" || fail "TC 账本链缺失"
PYTHONPATH="$PKG/scripts" python3 - "$AGORA_HOME" "$TC" <<'PYEOF' && ok "dispatcher_task 链可重放：账本复算 depth(TC)=2" || fail "链重放 depth≠2"
import glob, re, sys
home, tc = sys.argv[1], sys.argv[2]
disp = {}
for f in sorted(glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md")):
    try: lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError: continue
    for line in lines:
        if "event:dispatched" not in line: continue
        m = re.search(r"task:(gt-[0-9a-f]{4,})", line)
        if not m: continue
        d = re.search(r"dispatcher_task:(gt-[0-9a-f]{4,})", line)
        disp[m.group(1)] = d.group(1) if d else ""
def depth(t, seen):
    if t not in disp or t in seen: return 0
    d = disp[t]
    return 1 if not d else 1 + depth(d, seen | {t})
sys.exit(0 if depth(tc, frozenset()) == 2 else 1)
PYEOF

# ③ 上游 wt 树删除 → dispatch 锚点重建
rm -rf "$WRTB"
OUT=$(BDSP --actor borch@repa --project "$REPB" --task "$TB")
echo "$OUT" | grep -q '"mode":"spawned"' && [ -d "$WRTB" ] \
  && ok "上游 wt 树删除后 dispatch 锚点重建（spawned＋目录复在）" || fail "锚点重建（$OUT, [ -d $WRTB ]）"

# ④ D4：链中途 cancelled → done 自动 @ 上行
POST borch@repa --event cancelled --task "$TB" --reason "链中途取消演练" >/dev/null
POST borch@repa --event reopened --task "$TB" --reason "上游改判收口" >/dev/null
POST bmid@repb --event claimed --task "$TB" >/dev/null
POST bmid@repb --event done --task "$TB" --commit HEAD --evidence "取消后收口" >/dev/null
TASK="$TB" bash "$PKG/scripts/history.sh" | python3 -c "
import json,sys
done=[e for e in json.load(sys.stdin)['events'] if e['event']=='done'][-1]
assert 'borch' in (done.get('mention') or ''), done.get('mention')
" && ok "D4：链中途 cancelled→done 自动 @ 上行 borch" || fail "D4 上行 mention 缺 borch"
POST bleaf@repc --event claimed --task "$TC" >/dev/null
POST bleaf@repc --event done --task "$TC" --commit HEAD --evidence "下游交付" >/dev/null
TASK="$TC" bash "$PKG/scripts/history.sh" | python3 -c "
import json,sys
done=[e for e in json.load(sys.stdin)['events'] if e['event']=='done'][-1]
assert 'bmid' in (done.get('mention') or ''), done.get('mention')
" && ok "D4：下游 TC done 自动 @ 上行 bmid（其上游 TB 已 cancelled）" || fail "D4 下游 mention 缺 bmid"

# ⑤ 假 runtime EXIT≠0 秒死 → diagnosed＋恰好一次重试（try1 败→try2 成）
BRT="$T/bretrt"; printf '#!/usr/bin/env bash\n[ "$1" = "--version" ] && exit 0\n[ "${AGORA_TRY:-}" = "1" ] && exit 9\nexit 0\n' > "$BRT"; chmod +x "$BRT"
R5=$(TID "$(TITLE="秒死重试成功任务" VERIFY=true PROJECT_DIR="$REPA" TC)")
OUT=$(AGORA_RUNTIME="$BRT" AGORA_MAX_SPAWN=99 bash "$PKG/scripts/dispatch.sh" --actor borch@repa --project "$REPA" --task "$R5" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' && ok "假 runtime EXIT≠0 秒死→恰好一次重试后 spawned" || fail "重试成功路径（$OUT）"
R5LOG="$AGORA_HOME/$(echo "$OUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')"
grep -q '^EXIT:1=9' "$R5LOG" && grep -q '^EXIT:2=0' "$R5LOG" && [ "$(grep -c '^EXIT:' "$R5LOG")" -eq 2 ] \
  && ok "恰好一次重试（EXIT:1=9→EXIT:2=0，恰 2 行）" || fail "重试标记异常（$(grep '^EXIT:' "$R5LOG" 2>/dev/null | tr '\n' ' ')）"
[ "$(cat "$AGORA_HOME"/log/*/*.md 2>/dev/null | grep -F "task:$R5" | grep -c "event:diagnosed")" -eq 1 ] \
  && ok "秒死 diagnosed 恰好 1 条（重试成功不二次诊断）" || fail "diagnosed 计数异常"

# ⑥ 新会话命名断言：--title agora: gt-xxxx <title>（create/run 同名）
N6=$(TID "$(TITLE="新会话命名断言用例" VERIFY=true PROJECT_DIR="$REPA" TC)")
OUT=$(BDSP --actor borch@repa --project "$REPA" --task "$N6")
N6LOG="$AGORA_HOME/$(echo "$OUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')"
grep -qF -- "--title agora: $N6 新会话命名断言用例" "$N6LOG" \
  && ok "新会话命名：--title agora: gt-xxxx <title>" || fail "命名断言（$(grep -o -- "--title agora: $N6 新会话命名断言用例" "$N6LOG" 2>/dev/null | head -1)）"

# ⑦ teardown 竞态修复：.live 有界轮询（清空或超时）再 rm——子会话存活期禁删夹具目录
SSTUB="$T/bsleeprt"; printf '#!/usr/bin/env bash\n[ "$1" = "--version" ] && exit 0\nsleep 4\nexit 0\n' > "$SSTUB"; chmod +x "$SSTUB"
TEARDOWN_WAIT=20
wait_live_clear() {
  local _i
  for _i in $(seq 1 "$TEARDOWN_WAIT"); do
    [ -z "$(find "$AGORA_HOME/raw/dispatches" -name '*.live' 2>/dev/null)" ] && return 0
    sleep 1
  done
  echo "WARN: teardown 轮询 ${TEARDOWN_WAIT}s 后仍见 .live 滞留" >&2
  return 1
}
O7=$(TID "$(TITLE="teardown竞态用例任务" VERIFY=true PROJECT_DIR="$REPA" TC)")
OUT=$(AGORA_RUNTIME="$SSTUB" AGORA_VERIFY_WIN=1 AGORA_MAX_SPAWN=99 bash "$PKG/scripts/dispatch.sh" --actor borch@repa --project "$REPA" --task "$O7")
echo "$OUT" | grep -q '"mode":"spawned"' && ok "验证窗尽仍活=过：1s 窗口派发返回 spawned" || fail "竞态用例派发（$OUT）"
O7LOG="$AGORA_HOME/$(echo "$OUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')"
# 孤儿探针用本实例独有 stub 路径匹配（mktemp 唯一）——按 task id 全机 pgrep 会与并发 smoke 实例撞名假红（C册 gt-2153）
[ -f "$O7LOG.live" ] && pgrep -f "$SSTUB" >/dev/null \
  && ok "竞态窗现形：dispatch 返回后 .live 在＋子会话进程活（旧逻辑此时 rm 即孤儿）" || fail "竞态窗未现形"
wait_live_clear && [ ! -f "$O7LOG.live" ] && ! pgrep -f "$SSTUB" >/dev/null \
  && ok "teardown 有界轮询：.live 清空＋零孤儿进程" || fail "teardown 轮询后仍有活会话/标记"

echo "===== C一期（gt-b5e9）：cancel 自动推导 / redispatch 合一 / GC 窄域清理 ====="
CANCEL() { bash "$PKG/scripts/cancel.sh" "$@"; }
RDISP()  { AGORA_RUNTIME=echo AGORA_MAX_SPAWN=99 bash "$PKG/scripts/redispatch.sh" "$@"; }
# ① cancel 省略 task：自动取当前 actor 最近无终态已派任务（dispatched∩无终态口径）＋事件附树状态
CA1=$(TID "$(TITLE="cancel自动推导用例一" VERIFY=true PROJECT_DIR="$REPA" TC)")
sed -i "2,/^---\$/s|^---\$|nowt: true\n---|" "$AGORA_HOME/wiki/tasks/$CA1.md"   # gt-85c3 auto-wt 下显式豁免保 non-wt 形态（本断言合同=无树任务 tree:none）
POST borch@repa --event claimed --task "$CA1" >/dev/null
BDSP --actor borch@repa --project "$REPA" --task "$CA1" >/dev/null 2>&1
OUT=$(CANCEL --actor borch@repa)
echo "$OUT" | grep -q "\"task\":\"$CA1\"" && ok "① cancel 省略 task 自动取最近无终态已派任务" || fail "① 自动推导（$OUT）"
LEV "$CA1" cancelled | grep -q "tree:none" && ok "① cancelled 事件附树状态（无 wt_dir=none）" || fail "① 树状态缺失（$(LEV "$CA1" cancelled | head -1)）"
# ② 多活跃返回候选列表：只取最近，其余不误伤
CA2=$(TID "$(TITLE="cancel多活跃用例二" VERIFY=true PROJECT_DIR="$REPA" TC)")
BDSP --actor borch@repa --project "$REPA" --task "$CA2" >/dev/null 2>&1
CA3=$(TID "$(TITLE="cancel多活跃用例三" VERIFY=true PROJECT_DIR="$REPA" TC)")
BDSP --actor borch@repa --project "$REPA" --task "$CA3" >/dev/null 2>&1
# gt-6769 三脚本同钉（ocr-7）：CA2 的早 ts dispatched 行注入排序靠后分片——文件序陷阱在场时旧码误取 CA2
printf -- '- seq:9 | ts:%s | actor:borch@repa | event:dispatched | idem:cfb1 | task:%s | target:%s | child:cfa | run:raw/dispatches/d-cfa.log\n' \
  "$(date -d '30 minutes ago' --iso-8601=seconds)" "$CA2" "$REPA" >> "$AGORA_HOME/log/$(date +%F)/repb.md"
OUT=$(CANCEL --actor borch@repa)
echo "$OUT" | grep -q "\"task\":\"$CA3\"" && echo "$OUT" | grep -qF "$CA2" \
  && [ -z "$(LEV "$CA2" cancelled)" ] && [ -n "$(LEV "$CA3" cancelled)" ] \
  && ok "② 多活跃：取最近且候选列表含全部活跃（其余不误伤）" || { fail "② 多活跃（$OUT）"; grep -h "borch@repa" "$AGORA_HOME"/log/*/repa.md 2>/dev/null | grep -E "event:(dispatched|cancelled)" | tail -8 | cut -c1-190; }
# ③ 已终态再取消拒
CANCEL --actor borch@repa --task "$CA3" 2>/dev/null
[[ $? -eq 4 ]] && ok "③ 已终态再取消拒（rc=4）" || fail "③ 终态拒"
# ⑦ gt-35b5 遗留三缺陷回归：① cancel 行尾 bare task 终态守卫 ／ ② tools/call 非 dict arguments ／ ⑥ 顶层非 dict 帧
echo "===== gt-35b5 遗留三缺陷（① bare 行尾 ② 非参 ⑥ 非 dict 帧） ====="
SHARD35="$AGORA_HOME/log/$(date +%F)/gt35b5.md"; mkdir -p "$(dirname "$SHARD35")"
TS35="$(date +%FT%H:%M:%S)+08:00"
CA5="gt-35b5a"; CA6="gt-35b5b"   # 行尾 bare（bug 形态）／尾随 body（阳性对照）
echo "- seq:1 | ts:$TS35 | actor:borch@repa | event:cancelled | idem:x1 | seen:t@1 | task:$CA5" >> "$SHARD35"
echo "- seq:2 | ts:$TS35 | actor:borch@repa | event:cancelled | idem:x2 | seen:t@1 | task:$CA6 | reason:x" >> "$SHARD35"
CA7="gt-35b5c"   # R1-F3：dispatcher_task 尾段不得被子串误中为终态
echo "- seq:3 | ts:$TS35 | actor:borch@repa | event:dispatched | idem:x3 | seen:t@1 | target:x | dispatcher_task:$CA7" >> "$SHARD35"
CANCEL --actor borch@repa --task "$CA5" 2>/dev/null; [[ $? -eq 4 ]] \
  && ok "① 行尾 bare task 的 cancelled 可见：拒 ALREADY_TERMINAL(rc=4)" || fail "① bare 行尾漏检（ALREADY_TERMINAL 绕过→双终态）"
CANCEL --actor borch@repa --task "$CA6" 2>/dev/null; [[ $? -eq 4 ]] \
  && ok "① 对照：尾随 body 的 cancelled 仍拒(rc=4)" || fail "① 对照组破坏"
CANCEL --actor borch@repa --task "$CA7" 2>/dev/null; [[ $? -eq 5 ]] \
  && ok "①-F3 dispatcher_task 尾段不误判终态（rc=5 非终态拒）" || fail "①-F3 dispatcher_task 子串误中（→rc=4 假终态）"
cd "$REPA" && python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "② tools/call arguments 非 dict：isError 且 server 存活" || fail "② 非 dict arguments 杀共享 server"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = rpc("tools/call", {"name":"agora_task_create","arguments":"oops"}, 2)
assert r.get("result", {}).get("isError"), r
r = rpc("tools/call", {"name":"agora_task_create","arguments":[]}, 4)   # R1：falsy 非 dict 不得 coerce 放行
assert r.get("result", {}).get("isError"), r
r = rpc("tools/call", {"name":"agora_board","arguments":None}, 5)       # null＝无参，既有放行语义
assert "content" in r.get("result", {}) and not r["result"].get("isError"), r
assert rpc("ping", i=3).get("result") == {}, "server 已死"
p.stdin.close()
PYEOF
cd "$REPA" && python3 - "$PKG/server/agora_mcp.py" <<'PYEOF' && ok "⑥ 顶层非 dict 帧：error frame 且 server 存活" || fail "⑥ 顶层非 dict 帧杀共享 server"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
p.stdin.write(json.dumps([1,2,3])+"\n"); p.stdin.flush()
r = json.loads(p.stdout.readline())
assert r.get("error"), r
assert rpc("ping", i=2).get("result") == {}, "server 已死"
p.stdin.close()
PYEOF
# ④ MCP 双形态：agora_cancel 工具调用自动推导落账（十四工具注册断言在 heredoc 内）
CA4=$(TID "$(TITLE="cancel MCP双形态用例" VERIFY=true PROJECT_DIR="$REPA" TC)")
BDSP --actor borch@repa --project "$REPA" --task "$CA4" >/dev/null 2>&1
rm -f "$T/mcp_cancel_task"
(cd "$REPA" && python3 - "$PKG/server/agora_mcp.py" "$T/mcp_cancel_task" <<'PYEOF')
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
tools = [t["name"] for t in rpc("tools/list", i=2)["result"]["tools"]]
assert "agora_cancel" in tools and "agora_redispatch" in tools, tools
r = rpc("tools/call", {"name":"agora_cancel","arguments":{}}, 3)
out = json.loads(r["result"]["content"][0]["text"])
assert out.get("cancelled") and out.get("candidates"), out
open(sys.argv[2], "w").write(out["task"])
p.stdin.close()
PYEOF
MCT=$(cat "$T/mcp_cancel_task" 2>/dev/null)
[[ "$MCT" == "$CA4" ]] && [ -n "$(LEV "$CA4" cancelled)" ] && ok "④ MCP agora_cancel 双形态（注册＋自动推导落账）" || fail "④ MCP cancel（got:$MCT）"
# ⑤ redispatch escalated 一键回池：reopened＋dispatch 合一（零补充 prompt＝标准 BOOT）
RE1=$(TID "$(TITLE="redispatch升级回池任务" VERIFY=true PROJECT_DIR="$REPB" WT=1 IDEM=rc1 TC)")
BDSP --actor borch@repa --project "$REPB" --task "$RE1" >/dev/null 2>&1
sleep 1   # 跨分片同秒违序防御（G6 先例）：escalated 落 hx 分片，与 repa 分片的 dispatched 错开秒级保因果序
POST watchdog@hx --event escalated --task "$RE1" --conclusion "stalled 演练升级" >/dev/null
OUT=$(RDISP --actor borch@repa --task "$RE1")
echo "$OUT" | grep -q '"mode":"spawned"' && [ "$(LEV "$RE1" reopened | grep -c event:reopened)" -eq 1 ] \
  && [ "$(LEV "$RE1" dispatched | grep -c event:dispatched)" -eq 2 ] \
  && ok "⑤ escalated 一键回池：reopened＋重派 spawned" || fail "⑤（$OUT）"
# ⑥ done-unmerged 一键回池
RE2=$(TID "$(TITLE="redispatch未并回池任务" VERIFY=true PROJECT_DIR="$REPB" WT=1 IDEM=rc2 TC)")
BDSP --actor borch@repa --project "$REPB" --task "$RE2" >/dev/null 2>&1
POST bmid@repb --event claimed --task "$RE2" >/dev/null
POST bmid@repb --event done --task "$RE2" --commit HEAD --evidence ok >/dev/null
OUT=$(RDISP --actor borch@repa --task "$RE2")
echo "$OUT" | grep -q '"mode":"spawned"' && [ -n "$(LEV "$RE2" reopened)" ] \
  && ok "⑥ done-unmerged 一键回池：reopened＋重派" || fail "⑥（$OUT）"
# ⑦ in-flight 重派拒
RE3=$(TID "$(TITLE="redispatch在飞拒用例" VERIFY=true PROJECT_DIR="$REPB" TC)")
BDSP --actor borch@repa --project "$REPB" --task "$RE3" >/dev/null 2>&1
OUT=$(RDISP --actor borch@repa --task "$RE3" 2>&1); RC=$?
[[ $RC -ne 0 ]] && echo "$OUT" | grep -q INFLIGHT && ok "⑦ in-flight 重派拒（rc=$RC）" || fail "⑦（rc=$RC $OUT）"
# ⑦b redispatch 省略 task：自动取本 actor 最近 done-unmerged 已派任务回池（bmid 的 TC）
OUT=$(RDISP --actor bmid@repb)
echo "$OUT" | grep -q '"mode":"spawned"' && echo "$OUT" | grep -qF "\"task\":\"$TC\"" \
  && [ -n "$(LEV "$TC" reopened)" ] \
  && ok "⑦b redispatch 省略 task 自动取最近 done-unmerged 回池" || fail "⑦b（$OUT）"
# ⑧ GC 窄域：cancelled＋仅 .omo/agora-delegation/ 凭据 dirty → 自动清树＋删分支
HG=$(MKWT2 "窄域gc命中用例" c1); WHG=$(ls -d "$T"/proj__wt-${HG}__*)
BDSP --actor tester@proj --project "$PROJ" --task "$HG" >/dev/null 2>&1   # 凭据预写 .omo/agora-delegation/
git -C "$WHG" status --porcelain -uall | grep -q ".omo/agora-delegation/" \
  && ok "⑧ 夹具自检：凭据文件在树内且构成 dirty" || fail "⑧ 夹具自检（凭据未现形）"
POST tester@proj --event cancelled --task "$HG" --reason "窄域演练" >/dev/null
POLLT >/dev/null
[ ! -d "$WHG" ] && ! git -C "$PROJ" show-ref --verify -q "refs/heads/wt/$HG" \
  && ok "⑧ 窄域命中：cancelled＋仅凭据 dirty→自动清树＋删分支" || fail "⑧ 窄域未清（tree=$([ -d "$WHG" ] && echo in || echo gone)）"
# ⑨ 有业务文件不清
HB=$(MKWT2 "窄域gc业务用例" c2); WHB=$(ls -d "$T"/proj__wt-${HB}__*)
BDSP --actor tester@proj --project "$PROJ" --task "$HB" >/dev/null 2>&1
echo biz > "$WHB/bizfile"
POST tester@proj --event cancelled --task "$HB" --reason "业务留置演练" >/dev/null
RB=$(POLLT)
[ -d "$WHB" ] && echo "$RB" | grep -qF "$HB" \
  && ok "⑨ 有业务文件不清（wt_kept_dirty 只报告）" || fail "⑨（tree=$([ -d "$WHB" ] && echo kept || echo removed)）"
# ⑩ done 不清（B-C1 回归；done 树含凭据 dirty 也不在窄域）
HD=$(MKWT2 "done不清回归用例" c3); WHD=$(ls -d "$T"/proj__wt-${HD}__*)
BDSP --actor tester@proj --project "$PROJ" --task "$HD" >/dev/null 2>&1
echo dd > "$WHD/ddfile"; git -C "$WHD" add -A; git -C "$WHD" -c user.name=t -c user.email=t@l commit -qm dd
POST tester@proj --event claimed --task "$HD" >/dev/null
POST tester@proj --event done --task "$HD" --commit HEAD --evidence ok >/dev/null
POLLT >/dev/null
[ -d "$WHD" ] && ok "⑩ done 不清（B-C1 回归；窄域仅限 cancelled）" || fail "⑩ done 树被误删"

echo
echo "===== C 二期（gt-0a34）：kill 能力——pgid 落盘 / 进程组 kill / pid 复用防线 / abort 契约 ====="
# K1 run 通道 pgid 落盘：阻塞 stub 派发后 .live=数字 pgid 且组长 cmdline 含任务标识（AGORA_TASK 锚点）
K1=$(TID "$(TITLE="kill能力pgid落盘用例" VERIFY=true PROJECT_DIR="$REPA" TC)")
OUT=$(AGORA_RUNTIME="$SSTUB" AGORA_VERIFY_WIN=1 AGORA_MAX_SPAWN=99 bash "$PKG/scripts/dispatch.sh" --actor borch@repa --project "$REPA" --task "$K1")
echo "$OUT" | grep -q '"mode":"spawned"' || fail "K1 派发失败（$OUT）"
K1LOG="$AGORA_HOME/$(echo "$OUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')"
K1PGID=$(cat "$K1LOG.live" 2>/dev/null)
case "$K1PGID" in ''|*[!0-9]*) fail "K1 run 通道 pgid 落盘（live 内容: $(cat "$K1LOG.live" 2>/dev/null)）" ;; *) ok "K1 run 通道 pgid 落盘（.live=$K1PGID）" ;; esac
tr '\0' ' ' <"/proc/$K1PGID/cmdline" 2>/dev/null | grep -q "$K1" \
  && ok "K1 组长 cmdline 含任务标识（pid 复用校验锚点）" || fail "K1 cmdline 无任务标识"
# K2 cancel --kill 真杀：进程组消失＋.live 清＋body kill:pgid=＋JSON kill 键
OUT=$(CANCEL --actor borch@repa --task "$K1" --kill)
kill -0 -- "-$K1PGID" 2>/dev/null && K2ALIVE=y || K2ALIVE=n
[[ "$K2ALIVE" = n ]] && [ ! -f "$K1LOG.live" ] \
  && ok "K2 真杀：进程组消失＋.live 清" || fail "K2（组活=$K2ALIVE live=$([ -f "$K1LOG.live" ] && echo in || echo gone)）"
LEV "$K1" cancelled | grep -q "kill:pgid=$K1PGID" \
  && ok "K2 cancelled body 附 kill:pgid=" || fail "K2 body 无 kill 标记（$(LEV "$K1" cancelled | head -1)）"
echo "$OUT" | grep -q "\"kill\":\"kill:pgid=$K1PGID\"" \
  && ok "K2 JSON 输出 kill 键" || fail "K2 JSON kill 键（$OUT）"
# K3 pid 复用不误杀：无辜 setsid sleep 伪造 .live → 不 kill（skipped）＋.live 清
setsid sleep 30 & K3PID=$!; sleep 0.3
K3PGID=$(ps -o pgid= -p "$K3PID" 2>/dev/null | tr -d "[:space:]")
K3=$(TID "$(TITLE="kill复用防误杀用例" VERIFY=true PROJECT_DIR="$REPA" TC)")
OUT=$(BDSP --actor borch@repa --project "$REPA" --task "$K3")
K3LOG="$AGORA_HOME/$(echo "$OUT" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p')"
echo "$K3PGID" > "$K3LOG.live"   # 伪造：live 指向无辜长活进程（cmdline 无任务标识）
OUT=$(CANCEL --actor borch@repa --task "$K3" --kill)
kill -0 "$K3PID" 2>/dev/null && K3ALIVE=y || K3ALIVE=n
[[ "$K3ALIVE" = y ]] && echo "$OUT" | grep -q "skipped-cmdline-mismatch" && [ ! -f "$K3LOG.live" ] \
  && ok "K3 pid 复用不误杀：无辜进程仍活＋skipped＋.live 清" \
  || fail "K3（alive=$K3ALIVE out=$OUT）"
kill "$K3PID" 2>/dev/null || true
# K4 无 live：--kill 正常取消（kill:no-live，cancelled 照常落账）
K4=$(TID "$(TITLE="kill无live取消用例" VERIFY=true PROJECT_DIR="$REPA" TC)")
BDSP --actor borch@repa --project "$REPA" --task "$K4" >/dev/null 2>&1   # echo stub 秒死无 live
OUT=$(CANCEL --actor borch@repa --task "$K4" --kill)
echo "$OUT" | grep -q '"kill":"kill:no-live"' && [ -n "$(LEV "$K4" cancelled)" ] \
  && ok "K4 无 live 正常取消（kill:no-live）" || fail "K4（$OUT）"
# K5 API 通道 pgid 落盘：inject_slow 撑窗内 .live=数字 pgid，dispatch 返回后零残留
T2K=$(TID "$(TITLE="API通道pgid落盘用例" VERIFY="true" PROJECT_DIR="$PROJ" TC)")
echo /nonexist > "$FAKE_HOME/active_dir"   # T5 批在场检测残留：不清则 dispatch 命中「目标有活会话」降级 notified，无 spawn
fake_reset inject_slow
POSTD --task "$T2K" >"$T/k5.out" 2>&1 & K5DPID=$!
K5PGID=""
for _i in $(seq 1 50); do   # 10s 窗：全量负载下 dispatch 前置（create/落账 git 提交）耗时波动大
  K5PGID=$(find "$AGORA_HOME/raw/dispatches" -name '*.live' -exec cat {} \; 2>/dev/null | head -1)
  [ -n "$K5PGID" ] && break
  sleep 0.2
done
case "$K5PGID" in ''|*[!0-9]*) fail "K5 API 通道 pgid 落盘（got: $K5PGID; k5.out: $(cat "$T/k5.out" 2>/dev/null)）" ;; *) ok "K5 API 通道 pgid 落盘（.live=$K5PGID）" ;; esac
wait "$K5DPID"
find "$AGORA_HOME/raw/dispatches" -name '*.live' | grep -q . \
  && fail "K5 API 返回后 live 残留" || ok "K5 API 返回后 .live 零残留"

echo
echo "===== 并发九派风暴测试场（B批 gt-2e4f）：9 路并发 dispatch——账本写完整性＋配额保险丝 TOCTOU ====="
# 独立夹具 AGORA_HOME×2（mktemp 隔离，不触主测试账本）；AGORA_RUNTIME=true stub 秒退零会话
# 修复前实证（最小复现）：配额检查在锁外 → MAX_SPAWN=3 下 9/9 全放行（TOCTOU）；修复=落账前 dispatch.lock 锁内复核
SREPO="$T/storm-repo"; mkdir -p "$SREPO"
(cd "$SREPO" && git init -q . && echo FIXED > app.txt && git add -A && git -c user.name=t -c user.email=t@local commit -qm init)
storm_fixture() {  # storm_fixture <home>：init＋entity＋9 任务页（verify=true），任务 id 逐行写 <home>.tasks
  local _h="$1"
  AGORA_HOME="$_h" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
  mkdir -p "$_h/wiki/entities"
  printf -- '---\nname: storm\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$SREPO" > "$_h/wiki/entities/storm.md"
  (cd "$_h" && git add -A && AGORA_MECHANICAL=1 git commit -qm "entities 并发九派" >/dev/null)
  : > "$_h.tasks"
  local _i
  for _i in 1 2 3 4 5 6 7 8 9; do
    local _out _tid
    _out=$(AGORA_HOME="$_h" TITLE="并发九派夹具任务$_i 号" VERIFY=true PROJECT_DIR="$SREPO" bash "$PKG/scripts/task-create.sh" 2>&1)
    _tid=$(echo "$_out" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
    [ -n "$_tid" ] || { fail "并发九派夹具任务页 $_i（$_out）"; return 1; }
    echo "$_tid" >> "$_h.tasks"
  done
}
STORM_PIDS=()
SDSP() {  # SDSP <home> <max_spawn> <task> <out 前缀>：后台发射一路 dispatch，stdout/stderr/rc 分文件收
  local _h="$1" _m="$2" _t="$3" _o="$4"
  (
    export AGORA_HOME="$_h" AGORA_RUNTIME=true AGORA_MAX_SPAWN="$_m" AGORA_LOCK_WAIT=30   # ocr：auto-wt 串行化后 5s 缺省在负载抖动下吃紧——本段测 TOCTOU 正确性非锁等待压强
    bash "$PKG/scripts/dispatch.sh" --actor storm@stormrepo --project "$SREPO" --task "$_t" \
      > "$_o.out" 2> "$_o.err"
    echo $? > "$_o.rc"
  ) &
  STORM_PIDS+=($!)
}
STORM_WAIT() { wait "${STORM_PIDS[@]}"; STORM_PIDS=(); }

# 场景 A（配额内）：MAX_SPAWN=9，9 路零错峰并发——全放行、账本完整、run log 就位 .live 自清
SHOME_A="$T/storm-a/agora"; mkdir -p "$SHOME_A"
storm_fixture "$SHOME_A"
_i=0
while read -r _t; do _i=$((_i+1)); SDSP "$SHOME_A" 9 "$_t" "$T/storm-a/a$_i"; done < "$SHOME_A.tasks"
STORM_WAIT
N=$(grep -l '"mode":"spawned"' "$T/storm-a"/a*.out 2>/dev/null | wc -l)
[ "$N" -eq 9 ] && ok "并发九派A：9/9 spawned（配额内零错峰全放行）" || fail "并发九派A spawned=$N want 9"
N=$(grep -h 'event:dispatched' "$SHOME_A"/log/*/*.md 2>/dev/null | wc -l)
[ "$N" -eq 9 ] && ok "并发九派A：9 条 dispatched 全落账（零丢行）" || fail "并发九派A dispatched=$N want 9"
N=$(grep -h 'event:dispatched' "$SHOME_A"/log/*/*.md | sed -n 's/.*run:raw\/dispatches\/\(d-[0-9a-f]*\)\.log.*/\1/p' | sort -u | wc -l)
[ "$N" -eq 9 ] && ok "并发九派A：dispatch_id（run path）互异" || fail "并发九派A dispatch_id 去重=$N want 9"
python3 - "$SHOME_A" "$PKG" <<'PYEOF' && ok "并发九派A：账本分片全量可解析（iter_events 无残缺、seq 连续、idem 无重）" || fail "并发九派A 账本完整性"
import sys, glob
sys.path.insert(0, sys.argv[2] + "/scripts")
import agora_lib
home = sys.argv[1]
raw = 0
for pat in ("/log/*/*.md", "/log/*/.*.md"):
    for f in glob.glob(home + pat):
        with open(f, encoding="utf-8", errors="replace") as fh:
            raw += sum(1 for line in fh if line.startswith("- seq:"))
evs = list(agora_lib.iter_events(home))
assert raw == len(evs), f"parse 残缺: raw={raw} parsed={len(evs)}"
seqs = [e[2]["seq"] for e in evs]
assert seqs == list(range(1, len(seqs) + 1)), f"seq 不连续: {seqs}"
idems = [e[2]["idem"] for e in evs]
assert len(set(idems)) == len(idems), "idem 重复"
assert sum(1 for e in evs if e[2]["event"] == "dispatched") == 9
PYEOF
N=$(ls "$SHOME_A"/raw/dispatches/*.log 2>/dev/null | wc -l)
[ "$N" -eq 9 ] && ok "并发九派A：9 个 run log 就位" || fail "并发九派A run log=$N want 9"
_LIVEA=$(find "$SHOME_A/raw/dispatches" -name '*.live' 2>/dev/null | wc -l)
_BADLOG=0
for _f in "$SHOME_A"/raw/dispatches/*.log; do grep -q '^EXIT:1=0$' "$_f" || _BADLOG=$((_BADLOG+1)); done
[ "$_LIVEA" -eq 0 ] && [ "$_BADLOG" -eq 0 ] \
  && ok "并发九派A：stub 秒退 EXIT:1=0×9，.live 自清归零" || fail "并发九派A .live=$_LIVEA 坏log=$_BADLOG"

# 场景 B（配额满，保险丝）：MAX_SPAWN=3 同构 9 路并发——恰 3 spawned、6 QUOTA_EXCEEDED 零残留
SHOME_B="$T/storm-b/agora"; mkdir -p "$SHOME_B"
storm_fixture "$SHOME_B"
_i=0
while read -r _t; do _i=$((_i+1)); SDSP "$SHOME_B" 3 "$_t" "$T/storm-b/b$_i"; done < "$SHOME_B.tasks"
STORM_WAIT
N=$(grep -l '"mode":"spawned"' "$T/storm-b"/b*.out 2>/dev/null | wc -l)
[ "$N" -eq 3 ] && ok "并发九派B：恰 3 spawned（锁内复核先到者占额）" || fail "并发九派B spawned=$N want 3"
N=$(grep -l QUOTA_EXCEEDED "$T/storm-b"/b*.err 2>/dev/null | wc -l)
[ "$N" -eq 6 ] && ok "并发九派B：6 个 QUOTA_EXCEEDED（保险丝触发）" || fail "并发九派B QUOTA=$N want 6"
python3 - "$T/storm-b" <<'PYEOF' && ok "并发九派B：被拒 stderr 恒合法 JSON 且 code=QUOTA_EXCEEDED、rc=8；放行 rc=0" || fail "并发九派B JSON/rc 契约"
import glob, json, sys
d = sys.argv[1]
quota = 0; okrc = 0
for f in sorted(glob.glob(d + "/*.err")):
    with open(f, encoding="utf-8") as fh:
        lines = [l.strip() for l in fh if l.strip()]
    if not lines: continue
    payload = json.loads(lines[-1])          # fail() 错误通道恒 JSON
    assert payload["code"] == "QUOTA_EXCEEDED", payload
    quota += 1
for f in sorted(glob.glob(d + "/*.rc")):
    rc = open(f).read().strip()
    if rc == "8": okrc += 1
assert quota == 6, f"QUOTA JSON={quota}"
assert okrc == 6, f"rc8={okrc}"
assert sorted(open(f).read().strip() for f in glob.glob(d + "/*.rc")) == ["0"]*3 + ["8"]*6
PYEOF
_BADRJ=0
_i=0
while read -r _t; do
  _i=$((_i+1))
  if ! grep -q '"mode":"spawned"' "$T/storm-b/b$_i.out" 2>/dev/null; then
    grep -h "task:$_t" "$SHOME_B"/log/*/*.md 2>/dev/null | grep -q 'event:dispatched' && _BADRJ=$((_BADRJ+1))
  fi
done < "$SHOME_B.tasks"
[ "$_BADRJ" -eq 0 ] && ok "并发九派B：被拒 6 任务零 dispatched 落账（QUOTA 前置拒绝零残留）" || fail "并发九派B 被拒落账=$_BADRJ"
N=$(ls "$SHOME_B"/raw/dispatches/*.log 2>/dev/null | wc -l)
_LIVEB=$(find "$SHOME_B/raw/dispatches" -name '*.live' 2>/dev/null | wc -l)
[ "$N" -eq 3 ] && [ "$_LIVEB" -eq 0 ] \
  && ok "并发九派B：仅 3 个 run log、.live 归零（被拒者零 log 零 live）" || fail "并发九派B log=$N live=$_LIVEB"
# 槽位释放语义：锁内 3 额全占（stub 秒退但账本口径仍在飞）→ 重派第 7 个拒；其一 done 出集后同任务放行
_REJ=""; _i=0
while read -r _t; do
  _i=$((_i+1))
  if [ -z "$_REJ" ] && ! grep -q '"mode":"spawned"' "$T/storm-b/b$_i.out" 2>/dev/null; then _REJ="$_t"; fi
done < "$SHOME_B.tasks"
_SPA=""; _i=0
while read -r _t; do
  _i=$((_i+1))
  if [ -z "$_SPA" ] && grep -q '"mode":"spawned"' "$T/storm-b/b$_i.out" 2>/dev/null; then _SPA="$_t"; fi
done < "$SHOME_B.tasks"
SPOST() { AGORA_HOME="$SHOME_B" bash "$PKG/scripts/post.sh" --actor storm@stormrepo --project "$(basename "$SREPO")" "$@"; }
OUT=$(AGORA_HOME="$SHOME_B" AGORA_RUNTIME=true AGORA_MAX_SPAWN=3 \
  bash "$PKG/scripts/dispatch.sh" --actor storm@stormrepo --project "$SREPO" --task "$_REJ" 2>&1)
echo "$OUT" | grep -q QUOTA_EXCEEDED \
  && ok "并发九派B：槽位未释放时重派第 7 个拒（账本口径占额，零 .live 也计数）" || fail "并发九派B 重派第7未拒（$OUT）"
SPOST --event claimed --task "$_SPA" >/dev/null
SPOST --event done --task "$_SPA" --commit HEAD --evidence "并发九派槽位释放" >/dev/null \
  || fail "并发九派B 夹具 done 失败"
OUT=$(AGORA_HOME="$SHOME_B" AGORA_RUNTIME=true AGORA_MAX_SPAWN=3 \
  bash "$PKG/scripts/dispatch.sh" --actor storm@stormrepo --project "$SREPO" --task "$_REJ" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' \
  && ok "并发九派B：done 出集后重派第 7 个成功（槽位释放语义）" || fail "并发九派B 重派第7未放行（$OUT）"
# 锁超时契约（ocr-R0）：外部占住 dispatch.lock → AGORA_LOCK_WAIT=1 快速失败 rc3＋JSON QUOTA_LOCK＋零落账零 spawn
_TL=$(AGORA_HOME="$SHOME_B" TITLE="并发九派锁超时夹具任务" VERIFY=true PROJECT_DIR="$SREPO" bash "$PKG/scripts/task-create.sh" \
  | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
(
  flock -w 30 7 && sleep 5      # 模拟在飞 dispatch 持有 dispatch.lock
) 7>"$SHOME_B/.git/dispatch.lock" &
_LOCKPID=$!
sleep 0.5                        # 保证持锁方先赢
OUT=$(AGORA_HOME="$SHOME_B" AGORA_RUNTIME=true AGORA_MAX_SPAWN=99 AGORA_LOCK_WAIT=1 \
  bash "$PKG/scripts/dispatch.sh" --actor storm@stormrepo --project "$SREPO" --task "$_TL" 2>&1); _RC=$?
wait "$_LOCKPID"
echo "$OUT" | grep -q QUOTA_LOCK && [ "$_RC" -eq 3 ] \
  && [ -z "$(grep -h "task:$_TL" "$SHOME_B"/log/*/*.md 2>/dev/null)" ] \
  && [ "$(ls "$SHOME_B"/raw/dispatches/*.log 2>/dev/null | wc -l)" -eq 4 ] \
  && ok "并发九派B：锁超时 fail-fast（rc3＋QUOTA_LOCK＋零落账零 spawn）" || fail "并发九派B 锁超时（rc=$_RC out=$OUT）"

# 风暴后账本健康：两夹具 AGORA_HOME 各跑 doctor——seq 连续、idem 无重复、flock 正常（ALL GREEN 即内检全过）
OUT=$(AGORA_HOME="$SHOME_A" bash "$PKG/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "ALL GREEN" && ok "并发九派doctor：场景A 夹具 ALL GREEN" || { fail "并发九派doctor A"; echo "$OUT"; }
OUT=$(AGORA_HOME="$SHOME_B" bash "$PKG/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "ALL GREEN" && ok "并发九派doctor：场景B 夹具（含 done 终态）ALL GREEN" || { fail "并发九派doctor B"; echo "$OUT"; }

echo
echo "===== 合同卫生（gt-b9fb）：verify 静态守卫＋任务页机械字段修正通道＋doctor idem 文案一致化 ====="
# ① verify 合同静态守卫：三种坏合同各告警恰一次（warnings 非阻断），好合同零告警
VG_A=$(TID "$(TITLE="守卫绝对路径合同用例" VERIFY="bash /abs/main-repo/tests/smoke.sh" PROJECT_DIR="$REPA" TC)")
VG_B=$(TID "$(TITLE="守卫AGORAHOME合同用例" VERIFY='bash $AGORA_HOME/main-repo/tests/smoke.sh' PROJECT_DIR="$REPA" TC)")
VG_C=$(TID "$(TITLE="守卫引号绝对路径用例" VERIFY='bash "/abs/main-repo/tests/smoke.sh"' PROJECT_DIR="$REPA" TC)")
VG_OK=$(TID "$(TITLE="守卫好合同对照用例" VERIFY="bash tests/smoke-test.sh" PROJECT_DIR="$REPA" TC)")
GVA_OUT=$(BDSP --actor borch@repa --project "$REPA" --task "$VG_A" 2>/dev/null)
echo "$GVA_OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); w=d.get("warnings",[])
assert d.get("mode")=="spawned", d
assert len(w)==1 and "绝对路径" in w[0], w' \
  && ok "守卫①绝对路径坏合同告警恰一次（不阻断）" || fail "守卫①绝对路径（$GVA_OUT）"
GVB_OUT=$(BDSP --actor borch@repa --project "$REPA" --task "$VG_B" 2>/dev/null)
echo "$GVB_OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); w=d.get("warnings",[])
assert len(w)==1 and "AGORA_HOME" in w[0], w' \
  && ok "守卫①\$AGORA_HOME 坏合同告警恰一次" || fail "守卫①\$AGORA_HOME（$GVB_OUT）"
GVC_OUT=$(BDSP --actor borch@repa --project "$REPA" --task "$VG_C" 2>/dev/null)
echo "$GVC_OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); w=d.get("warnings",[])
assert len(w)==1 and "绝对路径" in w[0], w' \
  && ok "守卫①引号包裹绝对路径同防（告警恰一次）" || fail "守卫①引号绝对路径（$GVC_OUT）"
GVOK_OUT=$(BDSP --actor borch@repa --project "$REPA" --task "$VG_OK" 2>/dev/null)
echo "$GVOK_OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d.get("mode")=="spawned" and "warnings" not in d, d' \
  && ok "守卫①好合同（仓内相对路径）零告警" || fail "守卫①好合同误告警（$GVOK_OUT）"

# ② 任务页机械字段修正通道：仅 dispatcher actor；amended 留痕；merge.sh 按新值走
AMUP=$(TID "$(TITLE="amend链上游对照任务" VERIFY=true PROJECT_DIR="$PROJ" TC)")   # 非 wt 上游：merge 目标保持主仓默认分支
AM=$(MKWT "amend修正任务标题够长" "true" b9a); WAM=$(ls -d "$T"/proj__wt-${AM}__*)
echo a > "$WAM/amend-file"; git -C "$WAM" add -A >/dev/null; git -C "$WAM" -c user.name=t -c user.email=t@l commit -qm am
BDSP --actor tester@proj --project "$PROJ" --task "$AM" --dispatcher-task "$AMUP" >/dev/null 2>&1   # dispatcher: tester 标注
grep -q "^dispatcher: tester$" "$AGORA_HOME/wiki/tasks/$AM.md" \
  && ok "② 前置：dispatched 落 dispatcher 标注" || fail "② dispatcher 未标注（amend 权限锚点缺失）"
printf '正文引用旧合同：verify: body-note-keep\n' >> "$AGORA_HOME/wiki/tasks/$AM.md"   # F1 回归夹具：正文同前缀行不得被 amend 连带改写
NEWWT="$T/proj__wt-${AM}__moved"
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM" --set "wt_dir=$NEWWT" 2>&1)
grep -q "^wt_dir: $NEWWT$" "$AGORA_HOME/wiki/tasks/$AM.md" \
  && ok "② dispatcher 修正 wt_dir（页 frontmatter 原位改写）" || fail "② amend 改写（$OUT）"
grep -q "verify: body-note-keep" "$AGORA_HOME/wiki/tasks/$AM.md" \
  && ok "② F1 回归：正文同前缀行不被 amend 改写（frontmatter 锚定）" || fail "② F1 正文被连带改写"
LEV "$AM" amended | grep -q "event:amended" \
  && ok "② amended 事件落账留痕（历史行未改）" || fail "② amended 事件缺失（$OUT）"
rm -rf "$WAM"   # 旧树离场：merge 只能按页上新值重建
OUT=$(MERGE "$AM" 2>/dev/null)
echo "$OUT" | grep -q '"result":"merged"' && grep -q a "$PROJ/amend-file" && [ ! -d "$NEWWT" ] \
  && ok "② merge.sh 按修正后 wt_dir 走（新值重建→合并→清树）" || fail "② merge 按新值（out=$OUT olddir=$([ -d "$WAM" ] && echo in || echo gone) newdir=$([ -d "$NEWWT" ] && echo in || echo gone)）"
# 权限收窄：非 dispatcher 拒且零写入
AM2=$(MKWT "amend权限对照任务" "true" b9b); WAM2=$(ls -d "$T"/proj__wt-${AM2}__*)
BDSP --actor tester@proj --project "$PROJ" --task "$AM2" --dispatcher-task "$AMUP" >/dev/null 2>&1
FM_BEFORE=$(grep '^wt_dir:' "$AGORA_HOME/wiki/tasks/$AM2.md")
OUT=$(bash "$PKG/scripts/post.sh" --actor rival@proj2 --project proj2 --event amended --task "$AM2" --set "wt_dir=$T/hijack" 2>&1); RC=$?
[[ $RC -ne 0 ]] && echo "$OUT" | grep -q AMEND_FORBIDDEN \
  && [[ "$(grep '^wt_dir:' "$AGORA_HOME/wiki/tasks/$AM2.md")" == "$FM_BEFORE" ]] \
  && [ -z "$(LEV "$AM2" amended)" ] \
  && ok "② 非 dispatcher 被拒（AMEND_FORBIDDEN，页与账本零写入）" || fail "② 非 dispatcher 未拒（rc=$RC $OUT）"
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" 2>/dev/null
[[ $? -eq 2 ]] && ok "② amended 缺 --set 被拒(rc=2)" || fail "② 缺 --set 未拒"
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set "title=hijack" 2>/dev/null
[[ $? -eq 2 ]] && ok "② 非机械字段（title）被拒" || fail "② 非机械字段未拒"
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event proposal --body x --set "wt_dir=/x" 2>/dev/null
[[ $? -eq 2 ]] && ok "② F3 回归：非 amended 事件带 --set 显式拒" || fail "② F3 非 amended 带 set 未拒"
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set "wt_dir=$T/elsewhere/steal" 2>&1); RC=$?
[[ $RC -ne 0 ]] && echo "$OUT" | grep -q "主仓同级" && [[ "$(grep '^wt_dir:' "$AGORA_HOME/wiki/tasks/$AM2.md")" == "$FM_BEFORE" ]] \
  && ok "② C-F3 回归：wt_dir 越主仓同级命名域被拒（页零写入）" || fail "② C-F3 未拒（rc=$RC $OUT）"
# C-F2 回归：amend verify 换约后 done 的 derived 显式标注（评审者可见，不阻断）
AM3=$(TID "$(TITLE="amend换约标注任务标题够长" VERIFY=true PROJECT_DIR="$PROJ" TC)")
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event dispatched --task "$AM3" --target "$PROJ" --child tester --run "raw/dispatches/d-b9am3.log" >/dev/null
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM3" --set "verify=true" 2>&1)
grep -q "^verify: true$" "$AGORA_HOME/wiki/tasks/$AM3.md" \
  && ok "② C-F2 前置：amend verify 换约落页" || fail "② C-F2 前置（$OUT）"
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event done --task "$AM3" --commit HEAD --evidence x)
echo "$OUT" | grep -q "verify_amended" \
  && ok "② C-F2 回归：done derived 显式标注 verify_amended" || fail "② C-F2 标注缺失（$OUT）"
# ocr-E 回归：值级边界（转义往返 / | 拒 / 空值拒）——落 AM2（无 merge 夹具耦合）
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set 'verify=bash a&b\c.sh' 2>&1)
grep -Fq 'verify: bash a&b\c.sh' "$AGORA_HOME/wiki/tasks/$AM2.md" \
  && ok "② ocr-E：set 值 & 与反斜杠 sed 转义往返无损" || fail "② ocr-E 转义（$OUT）"
# gt-064b 回移：set 竖线放行（非前导指示符）——含管道 verify 的 amend 受理链
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set 'verify=true | true' 2>&1); RC=$?
[[ $RC -eq 0 ]] && grep -Fq 'verify: true | true' "$AGORA_HOME/wiki/tasks/$AM2.md" \
  && ok "② gt-064b：set 值含 | 放行且页 frontmatter 原值落页" || fail "② gt-064b 竖线放行链失败(rc=$RC $OUT)"
B64=$(printf '%s' 'true | true' | base64 | tr -d '\n')
LEV "$AM2" amended | grep -qF "set:verify=$B64" \
  && ok "② gt-064b：账本留痕 key 明文＋值 b64（事件行零裸管道）" || fail "② gt-064b 留痕形态不符"
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set 'wt_dir=/a|b' 2>/dev/null
[[ $? -eq 2 ]] && ok "② ocr-E：set 值 wt_dir 含 | 仍被拒(rc=2，命名域闸)" || fail "② ocr-E wt_dir | 未拒"
bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set 'wt_dir=' 2>/dev/null
[[ $? -eq 2 ]] && ok "② ocr-E：set 空值被拒(rc=2)" || fail "② ocr-E 空值未拒"
# ocr2-H1/H2 回归：本任务专属命名＋project_dir 名册域＋混改窗
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set "wt_dir=$T/proj__wt-gt-9999__0000" 2>&1); RC=$?
[[ $RC -ne 0 ]] && echo "$OUT" | grep -q "本任务专属" \
  && ok "② ocr2-H1：wt_dir 指他任务树名被拒（basename 钉死）" || fail "② ocr2-H1 未拒（rc=$RC $OUT）"
UNREG_B9="/tmp/opencode/gt-b9fb-unreg-probe"; mkdir -p "$UNREG_B9"   # gt-583b 后 /tmp 族 server 侧拒注册；此处更双保险断言 post.sh 侧名册外 project_dir 被拒
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set "project_dir=$UNREG_B9" 2>&1); RC=$?
rm -rf "$UNREG_B9"
[[ $RC -ne 0 ]] && echo "$OUT" | grep -q "名册已注册" \
  && ok "② ocr2-H2：project_dir 改名册外目录被拒（锚点不可迁）" || fail "② ocr2-H2 未拒（rc=$RC $OUT）"
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set "project_dir=$PROJ" --set "wt_dir=$NEWWT" 2>&1); RC=$?
[[ $RC -ne 0 ]] && echo "$OUT" | grep -q "混改" \
  && ok "② ocr2：project_dir×wt_dir 同次混改被拒（漂移窗）" || fail "② ocr2 混改未拒（rc=$RC $OUT）"
# gt-2508 分流：wt_dir 指主仓本体→拒且 hint 附凭据文件路由；专属树错名照旧走命名规范（ocr2-H1 已断）
OUT=$(bash "$PKG/scripts/post.sh" --actor tester@proj --project proj --event amended --task "$AM2" --set "wt_dir=$PROJ" 2>&1); RC=$?
[[ $RC -ne 0 ]] && echo "$OUT" | grep -q "主仓本体" && echo "$OUT" | grep -q "agora-delegation" \
  && ok "② 分流：wt_dir 指主仓本体被拒＋hint 附凭据文件路由（gt-2508）" || fail "② 分流 hint 缺失（rc=$RC $OUT）"
# MCP 面：amended 经 agora_post 工具（枚举＋set 透传）——dispatcher 修正 verify 合同
cd "$PROJ" && python3 - "$PKG/server/agora_mcp.py" "$AM2" <<'PYEOF' && ok "② MCP agora_post amended（枚举+set 透传）" || fail "② MCP amended 未通"
import json, subprocess, sys
p = subprocess.Popen(["python3", sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(m, ps=None, i=1):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":m,"params":ps or {}})+"\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
rpc("initialize", {})
r = rpc("tools/call", {"name":"agora_post","arguments":{"event":"amended","task":sys.argv[2],"set":["verify=bash tests/smoke-test.sh"]}}, 2)
d = json.loads(r["result"]["content"][0]["text"])
assert d.get("seq"), d
p.stdin.close()
PYEOF
grep -q '^verify: bash tests/smoke-test.sh$' "$AGORA_HOME/wiki/tasks/$AM2.md" \
  && ok "② MCP amend 改写 verify 合同（修正通道全脸可用）" || fail "② MCP amend 页未改写"

# ③ doctor idem 恢复文案与 doctor-runbook 一致（标注无效不删行）
SH9="$AGORA_HOME/log/$(date +%F)/proj.md"
mkdir -p "$(dirname "$SH9")"
printf -- '- seq:1 | ts:%s | actor:idemdup@p9 | event:proposal | idem:dupb9 | seen:p9@0\n' "$(date --iso-8601=seconds)" >> "$SH9"
printf -- '- seq:2 | ts:%s | actor:idemdup@p9 | event:proposal | idem:dupb9 | seen:p9@0\n' "$(date --iso-8601=seconds)" >> "$SH9"
OUT=$(bash "$PKG/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "发 diagnosed 标注无效行 ref" && echo "$OUT" | grep -q "doctor-runbook §idem" \
  && ! echo "$OUT" | grep -q "删除后续行" \
  && ok "③ doctor idem 文案与 runbook 一致（标注不删行）" || fail "③ doctor idem 文案（$(echo "$OUT" | grep "idem" | head -2)）"

# gt-2508：账本面 dirty 审计——机械写即 commit（post.sh git add -A），未提交改动=绕写痕迹（python 直写实证的 bash 盲区）
printf '\nbypass-trace: direct-write\n' >> "$AGORA_HOME/wiki/tasks/$AM2.md"
OUT=$(bash "$PKG/scripts/doctor.sh" 2>&1)
echo "$OUT" | grep -q "绕过工具直写痕迹" && echo "$OUT" | grep -q "git 可回滚" && echo "$OUT" | grep -q "wiki/tasks/$AM2.md" \
  && ok "③ doctor 账本面 dirty 审计（绕写痕迹 warn 指名道姓）" || fail "③ doctor dirty 审计缺失（$(echo "$OUT" | grep -c "绕过工具直写痕迹")）"
git -C "$AGORA_HOME" checkout -q -- "wiki/tasks/$AM2.md"   # 夹具还原，防污染后续断言

echo "===== 四缺口红测试批（gt-7ca0）：actor碰撞推导/链目标死循环/配额自锁/idle停转自恢复 ====="
# 独立夹具（B批模式）：每场景独立 AGORA_HOME（mktemp 隔离，不触主测试账本）；stub runtime 离线
QLEDEV() { cat "$1"/log/*/*.md "$1"/log/*/.*.md 2>/dev/null | grep -F "task:$2" | grep "event:$3"; }

# ---- 场景a（actor 碰撞推导）：同名 actor 先 claim 同项目任务 A（在飞）再派发 B → B 不继承 dispatcher_task:A ----
QA_HOME="$T/qa/agora"; mkdir -p "$QA_HOME"
AGORA_HOME="$QA_HOME" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
QAREPO="$T/qa-repo"; mkdir -p "$QAREPO"
(cd "$QAREPO" && git init -q . && echo FIXED > app.txt && git add -A && git -c user.name=t -c user.email=t@local commit -qm init)
QBREPO="$T/qa-repo2"; mkdir -p "$QBREPO" && (cd "$QBREPO" && git init -q .)
mkdir -p "$QA_HOME/wiki/entities"
printf -- '---\nname: qa\ndirs:\n  - %s\n  - %s\ncan_spawn: true\n---\n' "$QAREPO" "$QBREPO" > "$QA_HOME/wiki/entities/qa.md"
(cd "$QA_HOME" && git add -A && AGORA_MECHANICAL=1 git commit -qm entities >/dev/null)
QAPOST() { AGORA_HOME="$QA_HOME" bash "$PKG/scripts/post.sh" --actor "$1" --project "$2" "${@:3}"; }
QATC() { TID "$(AGORA_HOME="$QA_HOME" TITLE="$1" VERIFY=true PROJECT_DIR="$QAREPO" bash "$PKG/scripts/task-create.sh")"; }
QADSP() { AGORA_RUNTIME=echo AGORA_HOME="$QA_HOME" bash "$PKG/scripts/dispatch.sh" --actor qa@qa-repo --project "$QAREPO" --task "$1"; }
# 主断言：A 在飞（同项目、无链证据）→ 派 B 不得挂 dispatcher_task:A
QA_A=$(QATC "qa碰撞在飞任务A")
QAPOST qa@qa-repo qa-repo --event dispatched --task "$QA_A" --target "$QAREPO" --child qa --run "raw/dispatches/d-qa-a.log" >/dev/null
QAPOST qa@qa-repo qa-repo --event claimed --task "$QA_A" >/dev/null
QA_B=$(QATC "qa碰撞新派任务B")
QOUT_B=$(QADSP "$QA_B" 2>&1)
echo "$QOUT_B" | grep -q '"mode":"spawned"' && ok "场景a：B 派发放行" || fail "场景a：B 派发未放行（$QOUT_B）"
! QLEDEV "$QA_HOME" "$QA_B" dispatched | grep -q "dispatcher_task:" \
  && ok "场景a：同 actor 同项目 claimed 不推导为链（B 不挂 dispatcher_task:A）" \
  || fail "场景a：B 被误挂 dispatcher_task:A（actor 碰撞推导未排除同项目 claimed）"
# 对照1：跨项目 claimed 仍推导为链（真链保留）。C 事件落 qa-repo 分片（扫描序早于后文的 E）
QA_C=$(TID "$(AGORA_HOME="$QA_HOME" TITLE="qa跨仓在飞C" VERIFY=true PROJECT_DIR="$QBREPO" bash "$PKG/scripts/task-create.sh")")
QAPOST qa@qa-repo qa-repo --event dispatched --task "$QA_C" --target "$QBREPO" --child qa --run "raw/dispatches/d-qa-c.log" >/dev/null
QAPOST qa@qa-repo qa-repo --event claimed --task "$QA_C" >/dev/null
QA_D=$(QATC "qa跨仓新派D")
QADSP "$QA_D" >/dev/null 2>&1
QLEDEV "$QA_HOME" "$QA_D" dispatched | grep -q "dispatcher_task:$QA_C" \
  && ok "场景a对照1：跨项目 claimed 仍推导 dispatcher_task（真链保留）" \
  || fail "场景a对照1：跨项目链推导被误伤"
# 对照2：同项目 claimed 但自带链证据（E 自身挂在 R 链上）→ 仍推导（链上工人同仓再派不断链）
QA_R=$(QATC "qa链根R")
QAPOST qa@qa-repo qa-repo --event dispatched --task "$QA_R" --target "$QAREPO" --child qa --run "raw/dispatches/d-qa-r.log" >/dev/null
QA_E=$(QATC "qa链上E")
QAPOST qa@qa-repo qa-repo --event dispatched --task "$QA_E" --target "$QAREPO" --child qa --run "raw/dispatches/d-qa-e.log" --dispatcher-task "$QA_R" >/dev/null
QAPOST qa@qa-repo qa-repo --event claimed --task "$QA_E" >/dev/null
QA_F=$(QATC "qa链上新派F")
QADSP "$QA_F" >/dev/null 2>&1
QLEDEV "$QA_HOME" "$QA_F" dispatched | grep -q "dispatcher_task:$QA_E" \
  && ok "场景a对照2：同项目 claimed 有链证据仍推导（E 是链上子任务）" \
  || fail "场景a对照2：链证据 carve-out 被误伤"
rm -rf "$QA_HOME" "$QAREPO" "$QBREPO"

# ---- 场景b（链目标死循环）：上游已并入 main（tip 是 main 祖先/分支已清）→ 下游 merge 目标回落 main ----
QB_HOME="$T/qb/agora"; mkdir -p "$QB_HOME"
AGORA_HOME="$QB_HOME" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
QGREPO="$T/qb-repo"; mkdir -p "$QGREPO"
(cd "$QGREPO" && git init -q -b main . && echo BASE > base.txt && git add -A && git -c user.name=t -c user.email=t@local commit -qm init)
mkdir -p "$QB_HOME/wiki/entities"
printf -- '---\nname: mer\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$QGREPO" > "$QB_HOME/wiki/entities/mer.md"
(cd "$QB_HOME" && git add -A && AGORA_MECHANICAL=1 git commit -qm entities >/dev/null)
QBPOST() { AGORA_HOME="$QB_HOME" bash "$PKG/scripts/post.sh" --actor mer@qb-repo --project qb-repo "$@"; }
QBTC() { TID "$(AGORA_HOME="$QB_HOME" TITLE="$1" VERIFY=true PROJECT_DIR="$QGREPO" WT=1 bash "$PKG/scripts/task-create.sh")"; }
QBCM() { echo "$2" > "$1/$3"; git -C "$1" add -A >/dev/null; git -C "$1" -c user.name=t -c user.email=t@l commit -qm "$3"; }
# b1：上游分支在场且 tip 已是 main 祖先（手动 ff 并主、分支保留）→ 下游合并目标回落 main
QBU1=$(QBTC "qb上游U1"); QWU1=$(ls -d "$T"/qb-repo__wt-${QBU1}__*)
QBD1=$(QBTC "qb下游D1"); QWD1=$(ls -d "$T"/qb-repo__wt-${QBD1}__*)
QBCM "$QWU1" up up1; QBCM "$QWD1" down down1
git -C "$QWD1" rebase -q "wt/$QBU1"
QBPOST --event dispatched --task "$QBD1" --target "$QGREPO" --child mer --run "raw/dispatches/d-qb-d1.log" --dispatcher-task "$QBU1" >/dev/null
git -C "$QGREPO" merge -q --ff-only "wt/$QBU1"   # 上游并入 main（绕过 merge.sh，分支 wt/U1 保留在场）
UTIP1=$(git -C "$QGREPO" rev-parse "wt/$QBU1")
DC1=$(git -C "$QGREPO" rev-parse "wt/$QBD1")
QOUT_B1=$(AGORA_HOME="$QB_HOME" bash "$PKG/scripts/merge.sh" --actor mer@qb-repo --task "$QBD1" 2>&1)
echo "$QOUT_B1" | grep -q '"result":"merged"' && ok "场景b1：下游合并闭环" || fail "场景b1：下游合并失败（$QOUT_B1）"
QLEDEV "$QB_HOME" "$QBD1" merged | grep -q "branch:main" \
  && ok "场景b1：合并目标回落 main（上游 tip 已是 main 祖先不锚上游分支）" \
  || fail "场景b1：目标仍锚上游 wt 分支（$(QLEDEV "$QB_HOME" "$QBD1" merged | grep -o 'branch:[^ |]*')）"
[ "$(git -C "$QGREPO" rev-parse "wt/$QBU1")" = "$UTIP1" ] \
  && ok "场景b1：上游分支未被复活/移动（tip 不动）" || fail "场景b1：上游分支被动过"
git -C "$QGREPO" merge-base --is-ancestor "$DC1" main \
  && ok "场景b1：下游产出真实并入 main" || fail "场景b1：下游产出未进 main"
# b2：上游已并且分支树已清（gt-2b25 补票三连 NOT_FF 形态）→ 回落 main、不锚点重建复活
QBU2=$(QBTC "qb上游U2"); QWU2=$(ls -d "$T"/qb-repo__wt-${QBU2}__*)
QBD2=$(QBTC "qb下游D2"); QWD2=$(ls -d "$T"/qb-repo__wt-${QBD2}__*)
QBCM "$QWU2" up up2; QBCM "$QWD2" down down2
git -C "$QWD2" rebase -q "wt/$QBU2"
QBPOST --event dispatched --task "$QBD2" --target "$QGREPO" --child mer --run "raw/dispatches/d-qb-d2.log" --dispatcher-task "$QBU2" >/dev/null
AGORA_HOME="$QB_HOME" bash "$PKG/scripts/merge.sh" --actor mer@qb-repo --task "$QBU2" >/dev/null 2>&1   # 上游正常并主（分支/树清理）
if [ -z "$(git -C "$QGREPO" branch --list "wt/$QBU2")" ] && [ ! -d "$QWU2" ]; then
  ok "场景b2前置：上游合并后分支树已清"
else
  fail "场景b2前置：上游清理未生效（branch=$(git -C "$QGREPO" branch --list "wt/$QBU2") dir=$QWU2）"
fi
QOUT_B2=$(AGORA_HOME="$QB_HOME" bash "$PKG/scripts/merge.sh" --actor mer@qb-repo --task "$QBD2" 2>&1)
echo "$QOUT_B2" | grep -q '"result":"merged"' && ok "场景b2：done 未合并下游补票闭环" || fail "场景b2：下游合并失败（$QOUT_B2）"
QLEDEV "$QB_HOME" "$QBD2" merged | grep -q "branch:main" \
  && ok "场景b2：上游已并（分支已清）时目标回落 main（幂等票落账）" \
  || fail "场景b2：目标锚了重建的上游分支（$(QLEDEV "$QB_HOME" "$QBD2" merged | grep -o 'branch:[^ |]*')）"
[ -z "$(git -C "$QGREPO" branch --list "wt/$QBU2")" ] \
  && ok "场景b2：上游分支不被锚点重建复活" || fail "场景b2：wt/$QBU2 被复活"
[ ! -d "$QWU2" ] && ok "场景b2：上游树不重建" || fail "场景b2：上游树被重建"
rm -rf "$QB_HOME" "$QGREPO" "$T"/qb-repo__wt-*

# ---- 场景c（配额自锁）：任务 X 自身活跃占槽时恢复性重派 → 豁免自身槽位放行（MAX_SPAWN 不调大） ----
QC_HOME="$T/qc/agora"; mkdir -p "$QC_HOME"
AGORA_HOME="$QC_HOME" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
QCREPO="$T/qc-repo"; mkdir -p "$QCREPO"
(cd "$QCREPO" && git init -q . && echo FIXED > app.txt && git add -A && git -c user.name=t -c user.email=t@local commit -qm init)
mkdir -p "$QC_HOME/wiki/entities"
printf -- '---\nname: rec\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$QCREPO" > "$QC_HOME/wiki/entities/rec.md"
(cd "$QC_HOME" && git add -A && AGORA_MECHANICAL=1 git commit -qm entities >/dev/null)
QCX=$(TID "$(AGORA_HOME="$QC_HOME" TITLE="qc自锁任务X" VERIFY=true PROJECT_DIR="$QCREPO" bash "$PKG/scripts/task-create.sh")")
QCY=$(TID "$(AGORA_HOME="$QC_HOME" TITLE="qc他任务Y" VERIFY=true PROJECT_DIR="$QCREPO" bash "$PKG/scripts/task-create.sh")")
AGORA_HOME="$QC_HOME" bash "$PKG/scripts/post.sh" --actor rec@qc-repo --project qc-repo --event dispatched --task "$QCX" --target "$QCREPO" --child rec --run "raw/dispatches/d-qc-x.log" >/dev/null
OUT=$(AGORA_HOME="$QC_HOME" AGORA_RUNTIME=true AGORA_MAX_SPAWN=1 \
  bash "$PKG/scripts/dispatch.sh" --actor rec@qc-repo --project "$QCREPO" --task "$QCX" 2>&1)
echo "$OUT" | grep -q '"mode":"spawned"' \
  && ok "场景c：X 自身活跃占槽时重派 X 放行（恢复路径豁免自身槽位）" \
  || fail "场景c：X 重派被自身旧槽锁死 QUOTA（$OUT）"
OUT=$(AGORA_HOME="$QC_HOME" AGORA_RUNTIME=true AGORA_MAX_SPAWN=1 \
  bash "$PKG/scripts/dispatch.sh" --actor rec@qc-repo --project "$QCREPO" --task "$QCY" 2>&1)
echo "$OUT" | grep -q QUOTA_EXCEEDED \
  && ok "场景c：他任务 Y 仍被拒（豁免仅及自身，闸门不虚开）" \
  || fail "场景c：Y 未被拒——豁免越界（$OUT）"
rm -rf "$QC_HOME" "$QCREPO"

# ---- 场景d（idle 停转自恢复）：dispatched 会话 runtime status=idle 超阈且任务未终态 → poll 自动 inject 续跑（账本回执） ----
QD_HOME="$T/qd/agora"; mkdir -p "$QD_HOME"
AGORA_HOME="$QD_HOME" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
QDREPO="$T/qd-repo"; mkdir -p "$QDREPO"
(cd "$QDREPO" && git init -q . && echo FIXED > app.txt && git add -A && git -c user.name=t -c user.email=t@local commit -qm init)
mkdir -p "$QD_HOME/wiki/entities"
printf -- '---\nname: idler\ndirs:\n  - %s\ncan_spawn: true\n---\n' "$QDREPO" > "$QD_HOME/wiki/entities/idler.md"
(cd "$QD_HOME" && git add -A && AGORA_MECHANICAL=1 git commit -qm entities >/dev/null)
# 假 opencode stub：status 由 ctrl 文件控（idle|running）、inject 落证 append
QDBIN="$T/qd-fakebin"; QDFAKE="$T/qd-fake"; mkdir -p "$QDBIN" "$QDFAKE"
cat > "$QDBIN/opencode" <<'STUB'
#!/usr/bin/env bash
FH="${QD_FAKE:?QD_FAKE required}"
case "${1:-}" in
  --version) exit 0 ;;
  api) ;;
  *) exit 2 ;;
esac
shift; M=""; P=""; D=""
while [ $# -gt 0 ]; do case "$1" in
  -d) D="$2"; shift 2 ;;
  *) if [ -z "$M" ]; then M="$1"; elif [ -z "$P" ]; then P="$1"; fi; shift ;;
esac; done
case "$P" in
  */prompt) printf '%s\n' "$D" >> "$FH/prompts.log"; exit 0 ;;
esac
case "$M $P" in
  "GET /api/session/"*)
    if [ "$(cat "$FH/ctrl" 2>/dev/null || echo idle)" = "running" ]; then
      echo '{"data":{"id":"x","time":{"created":1}}}'
    else
      echo '{"data":{"id":"x","outcome":"succeeded","time":{"created":1,"idle":2}}}'
    fi
    exit 0 ;;
esac
echo "not found" >&2; exit 1
STUB
chmod +x "$QDBIN/opencode"
QDPOLL() { PATH="$QDBIN:$PATH" QD_FAKE="$QDFAKE" AGORA_HOME="$QD_HOME" bash "$PKG/scripts/poll.sh" 2>/dev/null; }
QDID=$(TID "$(AGORA_HOME="$QD_HOME" TITLE="qd idle停转任务" VERIFY=true PROJECT_DIR="$QDREPO" WT=1 bash "$PKG/scripts/task-create.sh")")
AGORA_HOME="$QD_HOME" bash "$PKG/scripts/post.sh" --actor idler@qd-repo --project qd-repo --event dispatched --task "$QDID" --target "$QDREPO" --child idler --run "raw/dispatches/d-qd-idle.log" --session ses_qdidle1 >/dev/null
touch "$QD_HOME/raw/dispatches/d-qd-idle.log"   # run log 在场（不撞孤儿档）
: > "$QDFAKE/prompts.log"
QDPOLL >/dev/null   # 首轮：建立 idle 跟踪基线（不 kick）
python3 - "$QD_HOME" "$QDID" <<'PYEOF' && ok "场景d首轮：idle 跟踪建档（不提前 kick）" || fail "场景d首轮：无 idle 跟踪档"
import json, sys, time
f, tid = sys.argv[1] + "/.git/poll-state.json", sys.argv[2]
s = json.load(open(f))
e = s.get("_idle_kick", {}).get(tid)
assert e, "无 _idle_kick 跟踪条目"
e["since"] = time.time() - 3600   # 拨回 1h 前模拟 idle 超阈
json.dump(s, open(f, "w"))
PYEOF
QDOUT=$(QDPOLL)
echo "$QDOUT" | python3 -c 'import json,sys; r=json.load(sys.stdin); tid=sys.argv[1]
assert any(k["task"]==tid and k["injected"] for k in r.get("idle_kicked",[])), r' "$QDID" \
  && ok "场景d：idle 超阈触发 inject 续跑（report 可见）" || fail "场景d：report 无 idle_kicked（$QDOUT）"
QLEDEV "$QD_HOME" "$QDID" diagnosed | grep -q "idle 停转" \
  && ok "场景d：账本可见回执（watchdog diagnosed）" || fail "场景d：账本无 idle 停转回执"
python3 -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]   # 适配器 ensure_ascii=True 落盘，须解析后断言原文
txt="".join(r.get("text","") for r in rows)
assert rows and all(r.get("delivery")=="queue" for r in rows) and "停转自恢复" in txt and "agora_history" in txt and sys.argv[2] in txt, txt' "$QDFAKE/prompts.log" "$QDID" \
  && ok "场景d：inject 携续跑指令送达（stub 落证）" || fail "场景d：inject 未送达或缺续跑指令"
N1=$(wc -l < "$QDFAKE/prompts.log")
QDPOLL >/dev/null   # cadence：kick 后时钟复位，紧接一轮不重复 kick
N2=$(wc -l < "$QDFAKE/prompts.log")
[ "$N1" = "$N2" ] && ok "场景d：kick 后 cadence 不刷屏（时钟复位）" || fail "场景d：重复 kick（$N1→$N2）"
# 对照：status=running（在转）不 kick
printf 'running' > "$QDFAKE/ctrl"
python3 - "$QD_HOME" "$QDID" <<'PYEOF'
import json, sys, time
f, tid = sys.argv[1] + "/.git/poll-state.json", sys.argv[2]
s = json.load(open(f))
s["_idle_kick"][tid] = {"since": time.time() - 3600, "n": 0}
json.dump(s, open(f, "w"))
PYEOF
N3=$(wc -l < "$QDFAKE/prompts.log")
QDPOLL >/dev/null
N4=$(wc -l < "$QDFAKE/prompts.log")
[ "$N3" = "$N4" ] && ok "场景d对照：status=running 不 kick" || fail "场景d对照：running 误 kick（$N3→$N4）"
# 超限升级：已 kick 超过 REDISPATCH_MAX 次 → escalated 而不再 inject
printf 'idle' > "$QDFAKE/ctrl"
QDID2=$(TID "$(AGORA_HOME="$QD_HOME" TITLE="qd idle超限任务" VERIFY=true PROJECT_DIR="$QDREPO" WT=1 bash "$PKG/scripts/task-create.sh")")
AGORA_HOME="$QD_HOME" bash "$PKG/scripts/post.sh" --actor idler@qd-repo --project qd-repo --event dispatched --task "$QDID2" --target "$QDREPO" --child idler --run "raw/dispatches/d-qd-idle2.log" --session ses_qdidle2 >/dev/null
touch "$QD_HOME/raw/dispatches/d-qd-idle2.log"
python3 - "$QD_HOME" "$QDID2" <<'PYEOF'
import json, sys, time
f, tid = sys.argv[1] + "/.git/poll-state.json", sys.argv[2]
s = json.load(open(f))
s["_idle_kick"][tid] = {"since": time.time() - 3600, "n": 99}   # 远超上限
json.dump(s, open(f, "w"))
PYEOF
N5=$(wc -l < "$QDFAKE/prompts.log")
QDPOLL >/dev/null
N6=$(wc -l < "$QDFAKE/prompts.log")
QLEDEV "$QD_HOME" "$QDID2" escalated | grep -q "idle 停转超限" \
  && [ "$N5" = "$N6" ] \
  && ok "场景d：kick 超限升级 escalated（不再 inject）" || fail "场景d：超限未升级或仍 inject（$N5→$N6 escal=$(QLEDEV "$QD_HOME" "$QDID2" escalated | head -1)）"
rm -rf "$QD_HOME" "$QDREPO" "$QDBIN" "$QDFAKE" "$T"/qd-repo__wt-*

echo "===== runtime/report.sh 周报（golden fixture，T3 gt-77a8） ====="
# fixture 账本：r001 3600s 净 / r002 5400s 净 / r003 1200s 脏(reopened+diagnosed) / r004 600s 净 / r005 只派发无 merged
# 期望：中位墙钟 2400s(n=4)、reopened 2、diagnosed 2（其一藏点分片，gt-40cc 规矩）、dispatcher 干预 2、N=2（脏任务居中归零重数）
RPT_H="$T/rpt-agora"; RPT_S="$T/rpt-state"
mkdir -p "$RPT_H/log/2026-10-20" "$RPT_H/log/2026-10-21" "$RPT_H/wiki/tasks" "$RPT_S"
RPTL() { printf -- '- seq:%s | ts:%s | actor:%s | event:%s | idem:rpt%s | task:%s\n' "$2" "$3" "$4" "$5" "$1" "$6" >> "$7"; }
RPT_M="$RPT_H/log/2026-10-20/main.md"; RPT_D="$RPT_H/log/2026-10-21/.dotproj.md"
RPTL 1 1 2026-10-20T10:00:00+08:00 orc@proj dispatched gt-r001 "$RPT_M"
RPTL 2 2 2026-10-20T11:00:00+08:00 orc@proj merged gt-r001 "$RPT_M"
RPTL 3 3 2026-10-20T10:00:00+08:00 orc@proj dispatched gt-r002 "$RPT_M"
RPTL 4 4 2026-10-20T11:30:00+08:00 orc@proj merged gt-r002 "$RPT_M"
RPTL 5 5 2026-10-20T10:00:00+08:00 orc@proj dispatched gt-r003 "$RPT_M"
RPTL 6 6 2026-10-20T10:10:00+08:00 orc@proj reopened gt-r003 "$RPT_M"
RPTL 7 7 2026-10-20T10:15:00+08:00 watchdog@hx diagnosed gt-r003 "$RPT_M"
RPTL 8 8 2026-10-20T10:20:00+08:00 orc@proj merged gt-r003 "$RPT_M"
RPTL 9 9 2026-10-20T10:00:00+08:00 orc@proj dispatched gt-r004 "$RPT_M"
RPTL 10 10 2026-10-20T10:10:00+08:00 orc@proj merged gt-r004 "$RPT_M"
RPTL 11 11 2026-10-20T10:00:00+08:00 orc@proj dispatched gt-r005 "$RPT_M"
RPTL 12 12 2026-10-21T09:00:00+08:00 watchdog@hx diagnosed gt-r005 "$RPT_D"
RPTL 13 13 2026-10-21T09:30:00+08:00 orc@proj reopened gt-r005 "$RPT_D"
for i in 1 2 3 4 5; do printf -- '---\nid: gt-r00%s\ndispatcher: orc\nstatus: open\n---\n' "$i" > "$RPT_H/wiki/tasks/gt-r00$i.md"; done
RPT_RUN() { AGORA_HOME="$RPT_H" AGORA_DRILL_STATE="$RPT_S" bash "$PKG/scripts/runtime/report.sh"; }
find "$RPT_H" -type f -exec sha256sum {} + | sort > "$T/rpt-before"
RPT_OUT=$(RPT_RUN)
find "$RPT_H" -type f -exec sha256sum {} + | sort > "$T/rpt-after"
diff -q "$T/rpt-before" "$T/rpt-after" >/dev/null && ok "report 只读（账本零写入）" || fail "report 写了账本"
echo "$RPT_OUT" | grep -qF '| spawn→merged 中位墙钟 | 2400s (n=4) |' && ok "四数字：中位墙钟精确值 2400s(n=4)" || fail "中位墙钟非 2400s(n=4)"
echo "$RPT_OUT" | grep -qF '| reopened 数 | 2 |' && ok "四数字：reopened=2" || fail "reopened≠2"
echo "$RPT_OUT" | grep -qF '| diagnosed 数 | 2 |' && ok "四数字：diagnosed=2（点分片伴生被扫到）" || fail "diagnosed≠2（点分片盲？）"
echo "$RPT_OUT" | grep -qF '| dispatcher 干预数 | 2 |' && ok "四数字：dispatcher 干预=2" || fail "dispatcher 干预≠2"
echo "$RPT_OUT" | grep -qF 'N=2' && ok "毕业计数：脏任务居中归零重数 N=2" || fail "归零重数错（N≠2）"
echo "$RPT_OUT" | grep -qF 'last_run: N/A' && ok "drill JSON 缺席→N/A（禁计 0）" || fail "drill 缺席未 N/A"
RPT_FILE=$(ls "$RPT_S"/report-*.md 2>/dev/null | head -1)
[ -n "$RPT_FILE" ] && diff <(printf '%s\n' "$RPT_OUT") "$RPT_FILE" >/dev/null && ok "落盘 report-<YYYY-Www>.md 且 stdout 同内容" || fail "落盘缺失或 stdout 不一致"
basename "$RPT_FILE" 2>/dev/null | grep -qE '^report-[0-9]{4}-W[0-9]{2}\.md$' && ok "文件名 ISO 周格式" || fail "文件名非 ISO 周格式"
printf '{"ts":"2026-10-24T10:00:00+08:00","results":[{"name":"quota","pass":true},{"name":"wave","pass":false}]}' > "$RPT_S/2026-10-24T100000.json"
RPT_OUT2=$(RPT_RUN)
echo "$RPT_OUT2" | grep -qF 'last_run: 2026-10-24T10:00:00+08:00' && echo "$RPT_OUT2" | grep -qF 'pass 1/2' && ok "drill JSON 在场→last_run+pass 比例" || fail "drill JSON 在场未正确呈现"
printf -- '- seq:14 | ts:garbage-ts | actor:x@y | event:dispatched | idem:rpt14 | task:gt-r006\n' >> "$RPT_M"
printf -- '- seq:15 | ts:2026-10-20T10:00:00 | actor:x@y | event:dispatched | idem:rpt15 | task:gt-r007\n' >> "$RPT_M"
printf -- '- seq:16 | ts:2026-10-20T10:05:00+08:00 | actor:x@y | event:merged | idem:rpt16 | task:gt-r007\n' >> "$RPT_M"
printf -- '- seq:17 | ts:2026-10-20T10:30:00 | actor:x@y | event:merged | idem:rpt17 | task:gt-r006\n' >> "$RPT_M"
printf '{"ts":"forge\\n### forged","results":[]}' > "$RPT_S/2026-10-24T110000.json"
RPT_OUT4=$(RPT_RUN) && ok "终闸B1：坏 ts 行与 naive/aware 混存不崩（降级跳过）" || fail "坏 ts 致崩溃"
echo "$RPT_OUT4" | grep -qF '| spawn→merged 中位墙钟 | 2400s (n=4) |' && ok "坏数据跳过不扭曲四数字（仍 2400s/n=4）" || fail "坏行处理扭曲度量"
[ "$(echo "$RPT_OUT4" | grep -c 'last_run:')" = 1 ] && ! echo "$RPT_OUT4" | grep -q '^### forged' && ok "终闸C2：drill 字段消毒（markdown 结构注入被剥离）" || fail "drill 字段未消毒"
AGORA_HOME="$RPT_H" AGORA_DRILL_STATE="$RPT_H" bash "$PKG/scripts/runtime/report.sh" >/dev/null 2>&1; [ $? -eq 2 ] && ok "终闸C3：AH==DS 同路径拒跑（只读不变量守卫）" || fail "AH==DS 未拒跑"
AGORA_HOME="$RPT_H" AGORA_DRILL_STATE="$RPT_H/state" bash "$PKG/scripts/runtime/report.sh" >/dev/null 2>&1; [ $? -eq 2 ] && ok "终闸C3绕过收口：DS 为 AH 子路径拒跑" || fail "DS⊂AH 未拒跑（报告可落账本仓）"
AGORA_HOME="$RPT_H/log" AGORA_DRILL_STATE="$RPT_H" bash "$PKG/scripts/runtime/report.sh" >/dev/null 2>&1; [ $? -eq 2 ] && ok "终闸C3绕过收口：AH 为 DS 子路径拒跑" || fail "AH⊂DS 未拒跑（报告可落账本仓）"
RPT_E="$T/rpt-empty-agora"; RPT_ES="$T/rpt-empty-state"; mkdir -p "$RPT_E" "$RPT_ES"
RPT_OUT3=$(AGORA_HOME="$RPT_E" AGORA_DRILL_STATE="$RPT_ES" bash "$PKG/scripts/runtime/report.sh")
echo "$RPT_OUT3" | grep -qF '| spawn→merged 中位墙钟 | N/A' && echo "$RPT_OUT3" | grep -qF '| reopened 数 | N/A' && echo "$RPT_OUT3" | grep -qF '| diagnosed 数 | N/A' && echo "$RPT_OUT3" | grep -qF '| dispatcher 干预数 | N/A' && echo "$RPT_OUT3" | grep -qF 'N=N/A' && ok "账本缺席→四数字与 N 全 N/A" || fail "账本缺席未全 N/A"
echo "$RPT_OUT3" | grep -qF '2400s' && fail "账本缺席仍出现具体数值" || ok "账本缺席无具体数值泄漏"
rm -rf "$RPT_H" "$RPT_S" "$RPT_E" "$RPT_ES" "$T"/rpt-before "$T"/rpt-after

echo
echo "===== T2 扰动演练 drill.sh（四场景 fake runtime 逻辑断言，gt-40cc 后继） ====="
# 独立论坛夹具：drill 实体/演练仓由 drill 自举；fakerun 挂睡保活（kill/restart 需活 .live 锚点）
DH=$(mktemp -d); DAH="$DH/agora"; DSTATE="$DH/state"; DFAKE="$DH/fake"; mkdir -p "$DFAKE"
AGORA_HOME="$DAH" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" >/dev/null 2>&1
cat > "$DFAKE/fakerun.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) exit 0 ;;
  run) shift; { printf 'ARGS:%s\n' "$*"; printf 'OCC:%s\n' "${OPENCODE_CONFIG_CONTENT:-none}"; } >> "${FAKE_RUN_LOG:?}" 2>/dev/null; sleep "${FAKE_RUN_SLEEP:-60}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$DFAKE/fakerun.sh"
cat > "$DFAKE/restart-hook.sh" <<'EOF'
#!/usr/bin/env bash
{
  echo "hook_sid=$(ps -o sid= -p $$ | tr -d ' ')"
  echo "hook_mypid=${AGORA_DRILL_MY_PID:-none}"
} > "${RESTART_HOOK_OUT:?}"
EOF
chmod +x "$DFAKE/restart-hook.sh"
DDRILL() { AGORA_HOME="$DAH" AGORA_DRILL_STATE="$DSTATE" AGORA_RUNTIME="$DFAKE/fakerun.sh" \
  AGORA_DRILL_RESTART_CMD="$DFAKE/restart-hook.sh" AGORA_VERIFY_WIN=1 AGORA_DRILL_HEALTH_WAIT=5 \
  AGORA_DRILL_CLAIM_WAIT=0 FAKE_RUN_SLEEP=60 AGORA_LOCK_WAIT=30 RESTART_HOOK_OUT="$DH/restart-hook.log" \
  FAKE_RUN_LOG="$DH/fakerun.log" \
  bash "$PKG/scripts/runtime/drill.sh" "$@"; }
DLEV() { cat "$DAH"/log/*/*.md "$DAH"/log/*/.*.md 2>/dev/null | grep -E "(^|[|] )task:$1( |$)" | grep "event:$2"; }   # gt-40cc：点分片伴生
DSchema() { python3 - "$1" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
assert set(r.keys()) >= {"ts", "scenario", "results"}, r
assert isinstance(r["scenario"], list) and r["scenario"], r
assert r["results"], r   # 空结果集＝报告序列化断（防 all() 空集真值化漏检）
for x in r["results"]:
    assert set(x) == {"name", "pass", "detail"} and isinstance(x["pass"], bool), x
if "skipped" in r: assert isinstance(r["skipped"], str), r
PYEOF
}
DDRILL --scenario bogus >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "drill 非法场景 rc2" || fail "drill 非法场景 rc 非 2"
# ① 忙碌让行：在飞波次在场 → rc2 零扰动（不建仓不举实体，报告 skipped）
DBT=$(TITLE="drill busy 种子" VERIFY="true" PROJECT_DIR="$PROJ" AGORA_HOME="$DAH" bash "$PKG/scripts/task-create.sh")
DBT=$(echo "$DBT" | sed -n 's/.*"task":"\(gt-[0-9a-f]*\)".*/\1/p')
AGORA_HOME="$DAH" bash "$PKG/scripts/post.sh" --actor seed@proj --project proj --event dispatched \
  --task "$DBT" --target "$PROJ" --child seed --run "raw/dispatches/d-drillbusy.log" >/dev/null
DOUT=$(DDRILL --scenario quota 2>&1); DRC=$?
[[ $DRC -eq 2 ]] && ok "drill 忙碌让行 rc2" || fail "drill 忙碌让行 rc2（got $DRC）"
[ ! -e "$DSTATE/agora-drill" ] && [ ! -e "$DAH/wiki/entities/drill.md" ] \
  && ok "忙碌让行零扰动（未建仓未举实体）" || fail "忙碌让行扰动环境"
DR=$(ls -t "$DSTATE"/*.json 2>/dev/null | head -1)
[ -n "$DR" ] && python3 - "$DR" <<'PYEOF' && ok "忙碌报告 skipped:busy" || fail "忙碌报告 skipped 缺失"
import json, sys
r = json.load(open(sys.argv[1]))
assert r.get("skipped", "").startswith("busy"), r
PYEOF
AGORA_HOME="$DAH" bash "$PKG/scripts/post.sh" --actor seed@proj --project proj --event cancelled \
  --task "$DBT" --reason "drill 清场" >/dev/null
# ② quota：打满 fail-closed 零残留 → 复通（报告 schema 顺带首验）
DDRILL --scenario quota >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "quota 场景 rc0" || fail "quota 场景 rc 非 0"
DR=$(ls -t "$DSTATE"/*.json | head -1)
DSchema "$DR" && ok "quota 报告 schema" || fail "quota 报告 schema 异常"
python3 - "$DR" <<'PYEOF' && ok "quota 场景断言全过" || fail "quota 场景断言有败"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["scenario"] == ["quota"], r
assert r["results"] and all(x["pass"] for x in r["results"]), r["results"]
PYEOF
DQID=$(grep -o 'gt-[0-9a-f]*' "$DR" | head -1)
[ "$(DLEV "$DQID" dispatched | grep -c event:dispatched)" -eq 1 ] \
  && ok "quota fail-closed 零账本残留（2 尝试 1 落账）" || fail "quota 残留（$(DLEV "$DQID" dispatched | grep -c event:dispatched) 派）"
DLEV "$DQID" cancelled | grep -q event:cancelled && ok "drill EXIT 清场 cancel 落账" || fail "drill 清场缺失（$DQID）"
# ③ kill：杀子会话 → 滞留诊断 → reopened → 重派 → 新会话
DDRILL --scenario kill >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "kill 场景 rc0" || fail "kill 场景 rc 非 0"
DR=$(ls -t "$DSTATE"/*.json | head -1); DKID=$(grep -o 'gt-[0-9a-f]*' "$DR" | head -1)
[ "$(DLEV "$DKID" dispatched | grep -c event:dispatched)" -eq 2 ] && ok "kill 闭环：初派＋重派 2 派" || fail "kill 派次（$(DLEV "$DKID" dispatched | grep -c event:dispatched)）"
DLEV "$DKID" diagnosed | grep -q "滞留" && ok "kill 闭环：看门狗滞留诊断" || fail "kill 无滞留诊断"
DLEV "$DKID" reopened | grep -q event:reopened && ok "kill 闭环：reopened 回池" || fail "kill 无 reopened"
[ "$(DLEV "$DKID" claimed | grep -c event:claimed)" -eq 2 ] && ok "kill 闭环：新会话认领" || fail "kill 认领（$(DLEV "$DKID" claimed | grep -c event:claimed)）"
# ④ restart：setsid 脱附＋自身 PID 传递＋health 回魂＋看门狗窗内事实锚（gt-f8ed：CRIT 滞留诊断窗内按设计不可达）
DDRILL --scenario restart >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "restart 场景 rc0" || fail "restart 场景 rc 非 0"
grep -q "hook_mypid=[0-9]" "$DH/restart-hook.log" && ok "restart 自身 PID 传递排除集" || fail "restart 钩子未收到排除 PID"
HSID=$(sed -n 's/hook_sid=//p' "$DH/restart-hook.log"); DSID=$(ps -o sid= -p $$ | tr -d ' ')
[ -n "$HSID" ] && [ "$HSID" != "$DSID" ] && ok "restart 钩子运行于脱离会话" || fail "restart 脱附（hook_sid=$HSID drill_sid=$DSID）"
DR=$(ls -t "$DSTATE"/*.json | head -1); DRID=$(grep -o 'gt-[0-9a-f]*' "$DR" | head -1)
python3 - "$DR" <<'PYEOF' && ok "restart 看门狗接管：poll 轮次＋活性时钟重建（窗内事实锚）" || fail "restart 窗内事实锚缺失（gt-f8ed 红绿对）"
import json, sys
r = json.load(open(sys.argv[1]))
names = {x["name"] for x in r["results"] if x["pass"]}
assert "restart 后 poll 轮次正常运转" in names, r["results"]
assert "restart 任务活性时钟重建" in names, r["results"]
PYEOF
# ⑤ wave：同窗 3 并发——账本完整、无孤儿、会话互异、无双认领（冲突派生兜底）
DDRILL --scenario wave >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "wave 场景 rc0" || fail "wave 场景 rc 非 0"
DR=$(ls -t "$DSTATE"/*.json | head -1); DWID=$(grep -o 'gt-[0-9a-f]*' "$DR" | head -1)
[ "$(DLEV "$DWID" dispatched | grep -c event:dispatched)" -eq 3 ] && ok "wave 3 并发落账完整" || fail "wave 派次（$(DLEV "$DWID" dispatched | grep -c event:dispatched)）"
WMISS=0; WRUNS=$(DLEV "$DWID" dispatched | sed -n 's/.*| run:\([^ |]*\).*/\1/p' | sort -u)
[ "$(printf '%s\n' "$WRUNS" | grep -c .)" -eq 3 ] || WMISS=1
for WR in $WRUNS; do [ -f "$DAH/$WR" ] || WMISS=1; done
[ "$WMISS" -eq 0 ] && ok "wave run log 齐全（无孤儿）" || fail "wave 孤儿/缺 log（$WRUNS）"
[ "$(DLEV "$DWID" claimed | grep -c event:claimed)" -eq 0 ] && ok "wave 桩子会话零认领（无双认领基线）" || fail "wave 意外认领"
DC1=$(AGORA_HOME="$DAH" bash "$PKG/scripts/post.sh" --actor wchild1@agora-drill --project agora-drill --event claimed --task "$DWID" 2>&1)
echo "$DC1" | grep -q claim_conflict && fail "wave 首认领误报冲突" || ok "wave 首认领无冲突"
DC2=$(AGORA_HOME="$DAH" bash "$PKG/scripts/post.sh" --actor wchild2@agora-drill --project agora-drill --event claimed --task "$DWID" 2>&1)
echo "$DC2" | grep -q "claim_conflict:wchild1@agora-drill" && ok "wave 双认领冲突派生" || fail "wave 双认领未派生冲突（$DC2）"
# ⑥ --scenario all 退出码合同＋全报告 schema
DDRILL --scenario all >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "all 场景 rc0" || fail "all 场景 rc 非 0"
for DRF in "$DSTATE"/*.json; do DSchema "$DRF" || fail "报告 schema（$DRF）"; done
DR=$(ls -t "$DSTATE"/*.json | head -1)
python3 - "$DR" <<'PYEOF' && ok "all 报告含四场景全过" || fail "all 报告场景/结果异常"
import json, sys
r = json.load(open(sys.argv[1]))
assert sorted(r["scenario"]) == ["kill", "quota", "restart", "wave"], r["scenario"]
assert r["results"] and all(x["pass"] for x in r["results"]), r["results"]
PYEOF
# ⑦ 场景分域隔离（gt-f8ed 根因2 红绿对）：每场景独立实体页＋fixture 仓＋wave 3 派全落在 wave 域——
# 共享 actor/仓时 kill 场景活子会话在场降级 quota 复通与 wave（真跑 171553 mode=notified 实证）
ISO=0
for S in restart kill quota wave; do
  [ -f "$DAH/wiki/entities/drill-$S.md" ] || ISO=1
  [ -d "$DSTATE/agora-drill-$S" ] || ISO=1
done
[ "$(DLEV "$DWID" dispatched | grep -c 'actor:drill-wave@')" -eq 3 ] || ISO=1
[ "$ISO" -eq 0 ] && ok "场景分域隔离（独立 actor/仓/实体页，wave 3 派全在 wave 域）" || fail "场景未隔离（gt-f8ed 根因2）"
# ⑧ --standalone 隔离（gt-7cd9 根因①）：spawn 面子会话必经包装注入 --standalone（私有 server＝
# 独立 env＋独立 MCP）＋OPENCODE_CONFIG_CONTENT 沙箱覆写（/proc 实证 config pin 压进程 env，纯
# --standalone 不够）——漏注入即 spawn 面全数错绑主广场（anon@proj 污染形态）
SA=0
grep -q "^ARGS:.*--standalone" "$DH/fakerun.log" 2>/dev/null || SA=1
grep "^OCC:" "$DH/fakerun.log" 2>/dev/null | grep -qF "$DAH" || SA=1
[ "$SA" -eq 0 ] && ok "spawn 面 --standalone＋OC_CONTENT 沙箱覆写（gt-7cd9）" || fail "standalone 隔离注入缺失（gt-7cd9 根因①）"
rm -rf "$DH"

echo
echo "===== AGORA_HOME 缺省治理（gt-ca34：裸调用 fail-fast） ====="
# 静默缺省致静默错路径（~/agora→~/plaza 改名两层遗漏实证）：15 脚本删缺省改 :? 报错——
# env 未设必非零退出且 stderr 指名 AGORA_HOME，禁再读任何隐式路径。
# HOME 同步沙箱＋timeout 包裹：红阶段（guard 未加）init.sh 不得污真 HOME，notify 守护不得挂死套件
mkdir -p "$T/barehome"
BAF=0
for BF in attach cancel dispatch doctor history init install-hooks merge notify-opencode pending-sessions post redispatch sync task-create wiki-write; do
  env -u AGORA_HOME HOME="$T/barehome" timeout 10 bash "$PKG/scripts/$BF.sh" >/dev/null 2>&1 && BAF=1
  env -u AGORA_HOME HOME="$T/barehome" timeout 10 bash "$PKG/scripts/$BF.sh" 2>&1 | grep -q AGORA_HOME || BAF=1
done
env -u AGORA_HOME HOME="$T/barehome" timeout 10 bash "$PKG/scripts/runtime/drill.sh" >/dev/null 2>&1 && BAF=1
env -u AGORA_HOME HOME="$T/barehome" timeout 10 bash "$PKG/scripts/runtime/drill.sh" 2>&1 | grep -q AGORA_HOME || BAF=1
[ "$BAF" -eq 0 ] && ok "15 脚本裸调用 fail-fast（env 未设非零＋stderr 含 AGORA_HOME）" || fail "裸调用未 fail-fast（gt-ca34 缺省残留）"

echo
echo "===== 结果: $PASS 通过, $FAIL 失败 ====="

wait_live_clear || true   # gt-2153：rm 夹具前等派发子会话退场（清空或超时再删）
rm -rf "$T"
[ "$FAIL" -eq 0 ]
