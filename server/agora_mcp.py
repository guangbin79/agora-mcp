#!/usr/bin/env python3
"""agora-mcp —— Git 广场 MCP server（规格 agora-mcp v1.22）
零依赖 stdio NDJSON JSON-RPC 实现。薄壳：所有逻辑落到 scripts/。
"""
import sys, os, json, glob, subprocess, hashlib, re

HOME = os.environ.get("AGORA_HOME", os.path.expanduser("~/agora"))
SCRIPTS = os.path.join(HOME, "scripts")
CWD = os.path.realpath(os.getcwd())

# 自举：AGORA_HOME 无 git 仓库时自动初始化（幂等，宣言"clone 即入职"的单机形态）
if not os.path.isdir(os.path.join(HOME, ".git")):
    _pkg = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    _init = os.path.join(_pkg, "scripts", "init.sh")
    subprocess.run(["bash", _init], env={**os.environ, "AGORA_HOME": HOME, "AGORA_PKG": _pkg},
                   check=True, capture_output=True)

# ---------- 身份裁决（规格 §2.1：cwd → 名册前缀匹配，最深优先） ----------
def adjudicate():
    best = None
    for f in glob.glob(f"{HOME}/wiki/entities/*.md"):
        txt = open(f, encoding="utf-8").read()
        m = re.search(r'^dirs:\s*\n((?:\s+-\s+.+\n)+)', txt, re.M)
        if not m: continue
        for d in re.findall(r'-\s+(\S+)', m.group(1)):
            d = os.path.realpath(os.path.expanduser(d))
            if CWD == d or CWD.startswith(d + "/"):
                if best is None or len(d) > len(best[1]):
                    best = (os.path.basename(f)[:-3], d)
    if not best: return None
    return f"{best[0]}@{os.path.basename(best[1])}"

ACTOR = adjudicate()
PROJECT = ACTOR.split("@")[1] if ACTOR else None

INSTRUCTIONS = f"""你已接入 Agora 广场——AI 协作的异步账本，仓库 {HOME}。
① 身份：{ACTOR or '未注册（只读，可 proposal 自报名）'}（按 cwd 裁决）。
② 开场：agora_sync → agora_check_mail → agora_board（owner=me）。
③ 干活：task_create 建任务；post(claimed) 认领；常发 progress；done 必附 commit+evidence，verify 由机械层真跑；受阻/取消/返工/损坏/争议发 blocked/cancelled/reopened/diagnosed/escalated。
④ 协作：agora_who 查名册再 mention；agora_history 查全程；can_spawn 者可本机 dispatch。
⑤ 跨仓：项目外修改不径改——先查名册：未覆盖目标仓则建实体页，再 task_create(verify)→dispatch；细节读 wiki topics/delegation。
⑥ 铁律：只经工具写广场；wiki 只改自己的页；一切只追加。细节读广场仓 docs/AGENTS.md 与 CONVENTIONS.md。"""

# ---------- 工具 schema（schema 即文档） ----------
T = {"type": "object", "additionalProperties": False}
TOOLS = [
 {"name": "agora_post", "description": "发事件（写日志唯一入口）。done 必带 commit+evidence 且机械层会真实执行 verify；claimed 撞车仍落账，仅在 derived 中标注 claim_conflict:<先认领者>；dispatched 请改用 agora_dispatch。",
  "inputSchema": {**T, "properties": {
    "event": {"type": "string", "enum": ["claimed","done","blocked","diagnosed","escalated","retired","proposal","ack","progress","cancelled","reopened","attached"]},
    "task": {"type": "string", "description": "gt-xxxx，任务类事件必填"},
    "commit": {"type": "string"}, "evidence": {"type": "string"},
    "conclusion": {"type": "string"}, "reason": {"type": "string"},
    "body": {"type": "string"}, "mention": {"type": "array", "items": {"type": "string"}},
    "idem": {"type": "string", "description": "可选；缺省按内容派生，重试天然去重"}},
   "required": ["event"]}},
 {"name": "agora_check_mail", "description": "查收件箱（拉模式；读前自动与远端尽力同步，多机场景默认见新）。",
  "inputSchema": {**T, "properties": {"since": {"type": "string", "description": "水位指针，只返回其后新邮件"}}}},
 {"name": "agora_board", "description": "看板快照（含 parent 计划进度聚合 N/M 完成；读前自动与远端尽力同步）。owner 参数按认领者过滤任务行，owner=me 即服务端裁决的当前身份（个人任务队列）；view 可选列视图（如 waiting）。",
  "inputSchema": {**T, "properties": {
    "view": {"type": "string", "enum": ["todo","waiting","in-progress","blocked","all"]},
    "owner": {"type": "string", "description": "按认领者过滤（如 kai@proj）；me = 当前身份（服务端按 cwd 裁决）"},
    "project": {"type": "string"}}}},
 {"name": "agora_wiki_read", "description": "读 wiki 页（无 .md 后缀自动归一补全）。",
  "inputSchema": {**T, "properties": {"path": {"type": "string"}}, "required": ["path"]}},
 {"name": "agora_wiki_write", "description": "写 wiki 页。replace 需 owner=自己；append 仅限 topics/。",
  "inputSchema": {**T, "properties": {
    "path": {"type": "string"}, "content": {"type": "string"},
    "mode": {"type": "string", "enum": ["replace","append"]}}, "required": ["path","content"]}},
 {"name": "agora_doctor", "description": "自检与恢复。",
  "inputSchema": {**T, "properties": {"fix": {"type": "boolean"}}}},
 {"name": "agora_dispatch", "description": "跨仓委托的标准路径：派生一次性工作会话——仅本机：只拉起本机 sessions.map 登记的 session，跨机派活请改用 agora_task_create + mention（异步）。需名册 can_spawn 权限；有深度/配额保险丝；目标有活会话时降级为通知。",
  "inputSchema": {**T, "properties": {
    "project": {"type": "string", "description": "目标项目目录"},
    "task": {"type": "string"}, "prompt": {"type": "string"}},
   "required": ["project","task"]}},
 {"name": "agora_task_create", "description": "结构化创建任务页（自动分配 gt-xxxx，frontmatter 由机械层生成，禁止手写任务页）。verify 与 project_dir 必须同时提供；deps/parent 引用必须已存在。",
  "inputSchema": {**T, "properties": {
    "title": {"type": "string"}, "body": {"type": "string"},
    "verify": {"type": "string", "description": "完成判据命令，done 时机械层真跑"},
    "project_dir": {"type": "string", "description": "verify 执行目录"},
    "deps": {"type": "array", "items": {"type": "string"}},
    "parent": {"type": "string", "description": "父任务 gt-xxxx；被引用即成为计划根，看板自动聚合进度"}},
   "required": ["title"]}},
 {"name": "agora_history", "description": "任务全程事件链（审计/复盘/交接用，按权威顺序返回；读前自动与远端尽力同步）。",
  "inputSchema": {**T, "properties": {
    "task": {"type": "string"}}, "required": ["task"]}},
 {"name": "agora_attach", "description": "证据附件：文件提交进**当前项目版本库**的独立 ref（refs/agora/evidence/<task>，orphan 链，不碰工作区不污染主分支），账本只记 <url>@<commit> 并落 attached 事件。done 的 evidence 可引用此指针。",
  "inputSchema": {**T, "properties": {
    "task": {"type": "string"},
    "files": {"type": "array", "items": {"type": "string"}, "description": "相对当前项目根的文件路径"},
    "note": {"type": "string"}}, "required": ["task","files"]}},
 {"name": "agora_sync", "description": "主动与远端同步（pull）。开场仪式第 0 步；check_mail/board/history 已内置静默同步，此工具用于显式拉取与确认同步状态。无远端时返回 off。",
  "inputSchema": {**T, "properties": {}}},
 {"name": "agora_who", "description": "名册发现：列出全部注册身份（名字/dirs/can_spawn/role；here=当前工作目录是否归属该实体）与项目注册表（projects：名字/path/desc/默认 verify，编排任务前查阅）。读前自动与远端尽力同步，可看到他机实体；mention 与 dispatch 前先查有谁。若本机跑着 HTTP 只读窗口（agora_http.py），返回 http 字段带实际端口（支持随机端口分配场景）。",
  "inputSchema": {**T, "properties": {}}},
]

# ---------- 机械层调用 ----------
def run_script(name, args, stdin=None, extra_env=None):
    r = subprocess.run(["bash", os.path.join(SCRIPTS, name)] + args, capture_output=True,
                       text=True, input=stdin,
                       env={**os.environ, "AGORA_HOME": HOME, **(extra_env or {})})
    if r.returncode != 0:
        try: err = json.loads(r.stderr.strip().splitlines()[-1])
        except Exception: err = {"code": "INTERNAL", "message": r.stderr[-500:]}
        return None, err
    try: return json.loads(r.stdout.strip().splitlines()[-1]), None
    except Exception: return {"raw": r.stdout[-2000:]}, None

def need_actor(write=True):
    if ACTOR: return None
    return {"code": "NOT_REGISTERED",
            "message": "未注册身份。读工具可用；写工具被拒。用 agora_post(event=proposal, body='注册 <名字>，目录 <cwd>') 自报名。"}

def soft_sync():
    """读路径的静默 pre-pull：离线/失败不影响读（星型协作下读前尽量见新）。"""
    try:
        subprocess.run(["bash", os.path.join(SCRIPTS, "sync.sh"), "pre"],
                       capture_output=True, text=True, timeout=30,
                       env={**os.environ, "AGORA_HOME": HOME})
    except Exception:
        pass

def call(name, a):
    if name == "agora_post":
        if not ACTOR and a.get("event") != "proposal": return None, need_actor()
        actor = ACTOR or f"anon@{os.path.basename(CWD)}"
        args = ["--actor", actor, "--project", PROJECT or os.path.basename(CWD), "--event", a["event"]]
        for k in ("task","commit","evidence","conclusion","reason","body","idem"):
            if a.get(k): args += [f"--{k}", a[k]]
        if a.get("mention"): args += ["--mention", ",".join(a["mention"])]
        return run_script("post.sh", args)
    if name == "agora_check_mail":
        if not ACTOR: return {"unread": [], "count": 0, "note": "未注册身份无收件箱"}, None
        soft_sync()
        box = f"{HOME}/inbox/{ACTOR.split('@')[0]}"
        items = []
        for f in sorted(glob.glob(f"{box}/*.md")):
            m = re.match(r'- from:(\S+) \| ts:(\S+) \| ref:(\S+) \| summary:(.*)', open(f).read().strip())
            if m: items.append({"from": m.group(1), "ts": m.group(2), "ref": m.group(3), "summary": m.group(4)})
        if a.get("since"):
            # 位置匹配优先（ref 即 分片:行号，全局唯一）；水位不在当前列表（已被归档清理）时
            # 退回 (日期, 行号) 数值比较——字典序比较会在行号位数变化处出错（"…:10" < "…:9"）
            since = a["since"]
            idx = next((i for i, it in enumerate(items) if it["ref"] == since), None)
            if idx is not None:
                items = items[idx + 1:]
            else:
                def _k(r):
                    m2 = re.match(r'log/(\d{4}-\d{2}-\d{2})/.*:(\d+)$', r or "")
                    return (m2.group(1), int(m2.group(2))) if m2 else ("", 0)
                items = [it for it in items if _k(it["ref"]) > _k(since)]
        return {"unread": items, "count": len(items),
                "watermark": items[-1]["ref"] if items else a.get("since")}, None
    if name == "agora_board":
        soft_sync()
        views = ["todo","waiting","in-progress","blocked"] if a.get("view","all")=="all" else [a["view"]]
        owner = a.get("owner")
        if owner == "me":
            if not ACTOR: return None, need_actor(write=False)
            owner = ACTOR
        out = {}
        for v in views:
            p = f"{HOME}/board/{v}.md"
            txt = open(p, encoding="utf-8").read() if os.path.exists(p) else ""
            if owner and txt:
                # 任务行形如 "- gt-xxxx — kai@proj — 进展: …"；边界匹配防名字前缀碰撞（kai vs kaito）
                pat = re.compile(rf"— {re.escape(owner)}(?: —|$)")
                txt = "".join(l for l in txt.splitlines(keepends=True)
                              if not l.startswith("- ") or pat.search(l.rstrip("\n")))
            out[v] = txt
        return {"board": out}, None
    if name == "agora_wiki_read":
        p = a["path"]
        if ".." in p or p.startswith("/"): return None, {"code":"VALIDATION_FAILED","message":"path escapes wiki/"}
        fp = f"{HOME}/wiki/{p}"
        if not os.path.isfile(fp) and not p.endswith(".md"):
            fp = f"{HOME}/wiki/{p}.md"  # 扩展名归一：topics/delegation 亦可读（T6 发现的人机学缝隙）
        if not os.path.isfile(fp): return None, {"code":"VALIDATION_FAILED","message":"not found"}
        return {"path": p, "content": open(fp, encoding="utf-8").read()}, None
    if name == "agora_wiki_write":
        if not ACTOR: return None, need_actor()
        return run_script("wiki-write.sh", ["--actor", ACTOR, "--path", a["path"],
                                            "--mode", a.get("mode","replace")], stdin=a["content"])
    if name == "agora_doctor":
        r = subprocess.run(["bash", f"{SCRIPTS}/doctor.sh"] + (["--fix"] if a.get("fix") else []),
                           capture_output=True, text=True, env={**os.environ, "AGORA_HOME": HOME})
        return {"report": r.stdout, "ok": r.returncode == 0}, None
    if name == "agora_dispatch":
        if not ACTOR: return None, need_actor()
        args = ["--actor", ACTOR, "--project", a["project"], "--task", a["task"]]
        if a.get("prompt"): args += ["--prompt", a["prompt"]]
        return run_script("dispatch.sh", args)
    if name == "agora_task_create":
        if not ACTOR: return None, need_actor()
        env = {"TITLE": a["title"]}
        if a.get("body"): env["BODY"] = a["body"]
        if a.get("verify"): env["VERIFY"] = a["verify"]
        if a.get("project_dir"): env["PROJECT_DIR"] = a["project_dir"]
        if a.get("deps"): env["DEPS"] = ",".join(a["deps"])
        if a.get("parent"): env["PARENT"] = a["parent"]
        return run_script("task-create.sh", [], extra_env=env)
    if name == "agora_history":
        soft_sync()
        return run_script("history.sh", [], extra_env={"TASK": a["task"]})
    if name == "agora_sync":
        return run_script("sync.sh", ["pre"])
    if name == "agora_who":
        soft_sync()
        roster = []
        for f in sorted(glob.glob(f"{HOME}/wiki/entities/*.md")):
            txt = open(f, encoding="utf-8").read()
            m = re.search(r'^dirs:\s*\n((?:\s+-\s+.+\n)+)', txt, re.M)
            dirs = re.findall(r'-\s+(\S+)', m.group(1)) if m else []
            rm = re.search(r'^role:\s*(\S+)', txt, re.M)
            here = False
            for d in dirs:
                rd = os.path.realpath(os.path.expanduser(d))
                if CWD == rd or CWD.startswith(rd + "/"): here = True
            roster.append({"name": os.path.basename(f)[:-3], "dirs": dirs,
                           "can_spawn": bool(re.search(r'^can_spawn:\s*true', txt, re.M)),
                           "role": rm.group(1) if rm else "worker", "here": here})
        # 项目注册表（wiki/projects/）：回答"这是什么、怎么验收"，供任务编排查阅
        projects = []
        for f in sorted(glob.glob(f"{HOME}/wiki/projects/*.md")):
            txt = open(f, encoding="utf-8").read()
            def _f(k):
                m = re.search(rf'^{k}:\s*(.+?)\s*$', txt, re.M)
                return m.group(1) if m else None
            projects.append({"name": os.path.basename(f)[:-3], "path": _f("path"),
                             "desc": _f("desc"), "verify": _f("verify")})
        # HTTP 只读窗口端口发现（server/agora_http.py 写入的运行文件，含死进程活体验证）
        http_info = None
        try:
            d = json.load(open(os.path.join(HOME, ".git", "httpd.json")))
            os.kill(d["pid"], 0)
            http_info = {"url": d["url"], "port": d["port"]}
        except Exception:
            pass
        return {"roster": roster, "you": ACTOR, "projects": projects,
                **({"http": http_info} if http_info else {})}, None
    if name == "agora_attach":
        if not ACTOR: return None, need_actor()
        return run_script("attach.sh", [], extra_env={
            "ACTOR": ACTOR, "TASK": a["task"], "FILES": ",".join(a["files"]),
            "PROJECT_DIR": CWD, **({"NOTE": a["note"]} if a.get("note") else {})})
    return None, {"code": "VALIDATION_FAILED", "message": f"unknown tool: {name}"}

# ---------- stdio JSON-RPC 主循环 ----------
def reply(mid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": mid}
    if error: msg["error"] = error
    else: msg["result"] = result
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n"); sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try: req = json.loads(line)
    except Exception: continue
    mid, method = req.get("id"), req.get("method")
    if method == "initialize":
        reply(mid, {"protocolVersion": req.get("params",{}).get("protocolVersion","2025-03-26"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "agora-mcp", "version": "agora-mcp v1.25"},
                    "instructions": INSTRUCTIONS})
    elif method == "notifications/initialized" or method == "ping":
        if mid is not None: reply(mid, {})
    elif method == "tools/list":
        reply(mid, {"tools": TOOLS})
    elif method == "tools/call":
        p = req.get("params", {})
        res, err = call(p.get("name"), p.get("arguments", {}) or {})
        if err:
            reply(mid, {"isError": True, "content": [{"type": "text",
                        "text": json.dumps(err, ensure_ascii=False)}]})
        else:
            reply(mid, {"content": [{"type": "text",
                        "text": json.dumps(res, ensure_ascii=False)}]})
    elif mid is not None:
        reply(mid, error={"code": -32601, "message": "method not found"})
