#!/usr/bin/env python3
"""agora_mcp —— Git 广场 MCP server（版本见仓库根 VERSION；规格 docs/Agora接口规格-v1.md）
零依赖 stdio NDJSON JSON-RPC 实现。薄壳：所有逻辑落到 scripts/。
"""
import sys, os, json, glob, subprocess, re
_PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_PKG, "scripts"))
import agora_lib as lib   # 账本/实体页共享解析（scripts/ 自举同源）

try:
    VERSION = open(os.path.join(_PKG, "VERSION"), encoding="utf-8").read().strip()
except Exception:
    VERSION = "agora-mcp dev"

HOME = os.environ.get("AGORA_HOME", os.path.expanduser("~/agora"))
SCRIPTS = os.path.join(HOME, "scripts")
CWD = os.path.realpath(os.getcwd())

# 自举：AGORA_HOME 无 git 仓库时自动初始化（幂等，宣言"clone 即入职"的单机形态）
if not os.path.isdir(os.path.join(HOME, ".git")):
    _init = os.path.join(_PKG, "scripts", "init.sh")
    subprocess.run(["bash", _init], env={**os.environ, "AGORA_HOME": HOME, "AGORA_PKG": _PKG},
                   check=True, capture_output=True)

# ---------- 身份裁决（规格 §2.1：cwd → 名册前缀匹配，最深优先） ----------
def _auto_register():
    """cwd 无实体覆盖时机械自注册（2026-10-20 裁定：注册去人工闸）——以目录 basename
    建实体页（can_spawn 放开；dispatch 深度/配额保险丝照常兜底）。O_CREAT|O_EXCL 原子
    建页：同名页已存在（人工建的他义实体）即让位回匿名。$HOME 本身不自动注册（防家目录
    级广覆盖实体）。worktree cwd 亦不注册（应归属主 repo 实体；主 repo 未注册则保持匿名，
    gt-ac14）。任何失败静默回退匿名，绝不阻塞 MCP 启动。"""
    if lib.main_repo_of(CWD): return None
    name = os.path.basename(CWD.rstrip("/"))
    if not name or CWD == os.path.realpath(os.path.expanduser("~")):
        return False
    if not lib.valid_entity_name(name):
        return False
    page = os.path.join(HOME, "wiki", "entities", f"{name}.md")
    content = (
        "---\n"
        f"owner: {name}\n"
        "dirs:\n"
        f"  - {CWD}\n"
        "can_spawn: true\n"
        "role: worker\n"
        "active: true\n"
        "---\n\n"
        "自动注册（2026-10-20 裁定：注册去人工闸）——adjudicate() 首见未覆盖 cwd 机械建页，\n"
        "dispatch 深度/配额保险丝照常约束；同名实体被人工抢占时本页让位（O_EXCL 不覆盖）。\n"
    )
    try:
        fd = os.open(page, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except OSError:
        return False
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(content)
    rel = f"wiki/entities/{name}.md"
    env = {**os.environ, "AGORA_MECHANICAL": "1"}
    subprocess.run(["git", "-C", HOME, "add", rel], env=env, capture_output=True)
    subprocess.run(["git", "-C", HOME, "-c", f"user.name={name}", "-c",
                    f"user.email={name}@local", "commit", "-qm",
                    f"entity: auto-register {name} (cwd={CWD})"], env=env, capture_output=True)
    return True

def adjudicate():
    r = lib.resolve_entity(HOME, CWD)
    if not r:
        if _auto_register():   # 仅本调用原子建页成功才授身份；O_EXCL 失败＝同名他义页已在 → 保持匿名
            name = os.path.basename(CWD.rstrip("/"))
            return f"{name}@{name}"
        return None
    return f"{r[0]}@{os.path.basename(r[1])}"   # @后缀=命中 dirs 目录名（原语义）；worktree cwd 归一主实体不误注册

ACTOR = adjudicate()
PROJECT = ACTOR.split("@")[1] if ACTOR else None

def dispatched_child_actor():
    """gt-eefd：dispatch 派生子会话的会话上下文身份。dispatch.sh spawn 时经 env 注入
    AGORA_LIVEF（raw/dispatches/<DID>.log.live）与 AGORA_PDIR（派发目标目录），子会话的
    MCP server 继承同一 env——据此反查 dispatched 记录取 child_actor，不依赖调用方自觉
    显式传 actor（共享 MCP 进程级 ACTOR 归 dispatcher，gt-49fb）。按 run id 反查而非按
    task：同任务多派（gt-b12d 实证）各 run 天然不歧义。非派生子会话返回 None，走进程级
    ACTOR。读失败/记录残缺一律退化（pdir 现裁决或 None），绝不拖垮 server。"""
    try:
        livef, pdir = os.environ.get("AGORA_LIVEF"), os.environ.get("AGORA_PDIR")
        if not (livef or pdir):
            return None
        run = os.path.basename(livef or "")   # 实形状 <DID>.log.live——后缀逐层剥
        for suf in (".live", ".log"):
            if run.endswith(suf):
                run = run[:-len(suf)]
        if run:
            for _, _, e in lib.iter_events(HOME):
                if e.get("event") == "dispatched" and os.path.basename(e.get("run", "")) == f"{run}.log":
                    r = lib.resolve_entity(HOME, e.get("target") or pdir or "")
                    if e.get("child") and lib.valid_entity_name(e["child"]) and r:
                        return f"{e['child']}@{os.path.basename(r[2])}"
                    break   # 记录在但 child 非法/残缺 → 退按目标目录现裁决
        r = lib.resolve_entity(HOME, pdir or "")   # 记录缺失（清理/跨日）兜底：与 dispatch.sh 同口径
        return f"{r[0]}@{os.path.basename(r[2])}" if r else None
    except Exception:
        return None   # 账本坏字节/并发替换等读失败：退进程级 ACTOR，不拖垮 server

INSTRUCTIONS = f"""你已接入 Agora 广场——AI 协作的异步账本，仓库 {HOME}。
① 身份：{ACTOR or '未注册（只读，可 proposal 自报名）'}（按 cwd 裁决）。
② 开场：agora_sync → agora_check_mail → agora_board（owner=me）。
③ 干活：task_create 建任务；post(claimed) 认领；常发 progress；派生先 post(plan) 待 ack；done 必附 commit+evidence，verify 机械层真跑；受阻/取消/返工发 blocked/cancelled/reopened/diagnosed/escalated。
④ 协作：agora_who 查名册再 mention；agora_history 查全程；can_spawn 者可本机 dispatch。
⑤ 跨仓：项目外修改不径改——先查名册：未覆盖目标仓则建实体页，再 task_create(verify)→dispatch；细节读 topics/delegation。
⑥ 铁律：只经工具写广场；wiki 只改自己的页；一切只追加。细节读广场仓 docs/AGENTS.md 与 CONVENTIONS.md。"""

# ---------- 工具 schema（schema 即文档） ----------
BOARD_VIEWS = lib.BOARD_VIEWS   # schema 枚举与服务端白名单单点口径（agora_lib.BOARD_VIEWS）
T = {"type": "object", "additionalProperties": False}
TOOLS = [
 {"name": "agora_post", "description": "发事件（写日志唯一入口）。done 必带 commit+evidence 且机械层会真实执行 verify；claimed 撞车仍落账，仅在 derived 中标注 claim_conflict:<先认领者>；plan 落实施计划（body 必填，挂 task 时自动 @任务页 dispatcher，dispatcher ack 或 30min 超时自放行）；dispatched 请改用 agora_dispatch。",
  "inputSchema": {**T, "properties": {
    "event": {"type": "string", "enum": ["claimed","done","blocked","diagnosed","escalated","retired","proposal","ack","progress","cancelled","reopened","attached","plan"]},
    "task": {"type": "string", "description": "gt-xxxx，任务类事件必填"},
    "commit": {"type": "string"}, "evidence": {"type": "string"},
    "conclusion": {"type": "string"}, "reason": {"type": "string"},
    "body": {"type": "string"}, "mention": {"type": "array", "items": {"type": "string"}},
    "idem": {"type": "string", "description": "可选；缺省按内容派生，重试天然去重"},
    "actor": {"type": "string", "description": "可选；显式声明落账身份。dispatch 派生的子会话 MUST 传 dispatch 记录给定的 child_actor（共享 MCP 进程级 ACTOR 归 dispatcher，gt-49fb）；漏传时 server 按 dispatch env（AGORA_LIVEF/AGORA_PDIR）反查 child_actor 兜底（gt-eefd）"}},
   "required": ["event"]}},
 {"name": "agora_check_mail", "description": "查收件箱（拉模式；读前自动与远端尽力同步，多机场景默认见新）。",
  "inputSchema": {**T, "properties": {"since": {"type": "string", "description": "水位指针，只返回其后新邮件"}}}},
 {"name": "agora_board", "description": "看板快照（含 parent 计划进度聚合 N/M 完成；读前自动与远端尽力同步）。owner 参数按认领者过滤任务行，owner=me 即服务端裁决的当前身份（个人任务队列）；view 可选列视图（如 waiting）。",
  "inputSchema": {**T, "properties": {
   "view": {"type": "string", "enum": list(BOARD_VIEWS)},
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
 {"name": "agora_dispatch", "description": "跨仓委托的标准路径：派生一次性工作会话——仅本机：只拉起本机 sessions.map 登记的 session，跨机派活请改用 agora_task_create + mention（异步）。需名册 can_spawn 权限；有深度/配额保险丝；目标有活会话时降级为通知。project 可为 git worktree 路径——机械层归一到主 repo 匹配名册实体，dispatched 的 project 字段取主 repo 名；worktree 生命周期（建/清/合并）归调用者。",
  "inputSchema": {**T, "properties": {
    "project": {"type": "string", "description": "目标项目目录"},
    "task": {"type": "string"}, "prompt": {"type": "string"},
    "dispatcher_task": {"type": "string", "description": "可选 gt-xxxx：派发时会话正在做的任务（链深度登记面；缺省时机械层按 actor 最近 claimed 无终态任务推导）"}},
   "required": ["project","task"]}},
 {"name": "agora_task_create", "description": "结构化创建任务页（自动分配 gt-xxxx，frontmatter 由机械层生成，禁止手写任务页）。verify 与 project_dir 必须同时提供；deps/parent 引用必须已存在。命中防呆时 stdout JSON 带 warnings 键（project_dir 为 worktree 形态未带 wt／title<8 字；仅告警不阻断）。",
  "inputSchema": {**T, "properties": {
    "title": {"type": "string"}, "body": {"type": "string"},
    "verify": {"type": "string", "description": "完成判据命令，done 时机械层真跑"},
    "project_dir": {"type": "string", "description": "verify 执行目录"},
    "deps": {"type": "array", "items": {"type": "string"}},
    "parent": {"type": "string", "description": "父任务 gt-xxxx；被引用即成为计划根，看板自动聚合进度"},
    "idem": {"type": "string", "description": "可选幂等键；同 key 重复创建原样返回既有任务（重试不建新页）"},
    "wt": {"type": "boolean", "description": "可选 true＝agora 预建专用 worktree（需 verify；frontmatter 记 wt/wt_dir/wt_host，子会话在该树开发）"}},
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
 {"name": "agora_cancel", "description": "取消任务：post cancelled（body 附树状态 wt:/tree:），树交 poll GC 自动清理。task 省略＝自动取当前 actor 最近无终态的已派任务（dispatched∩无终态口径，与 dispatch.sh 配额口径同款），多活跃时返回 candidates 列表；当前终态 merged/cancelled 拒。不做进程 kill（kill 能力归 C 二期）。",
  "inputSchema": {**T, "properties": {
    "task": {"type": "string", "description": "gt-xxxx；省略＝自动推导最近无终态已派任务"},
    "reason": {"type": "string"}}}},
 {"name": "agora_redispatch", "description": "一键回池重派：尾态 escalated 或 done-unmerged 先 post reopened 再 dispatch 合一（零补充 prompt＝标准 BOOT，任务页 title/verify 由子会话读页获得）。task 省略＝自动取当前 actor 最近可回池任务（多活跃回 candidates）；当前终态 merged/cancelled 与在飞拒。",
  "inputSchema": {**T, "properties": {
    "task": {"type": "string", "description": "gt-xxxx；省略＝自动推导最近可回池任务"}}}},
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

def call(name, a):
    global ACTOR, PROJECT
    # 身份裁决去冻结化：名册可变（实体页随时创建/补 dirs），启动期冻结会在长寿命
    # server 下过期（2026-10-20 gt-9f24 实证：共享 server 08:39 启动早于 10:14 实体页
    # → 匿名终身，派生会话被迫直调机械层）。每次工具调用重裁决，glob 数个小文件成本可忽略。
    ACTOR = adjudicate()
    PROJECT = ACTOR.split("@")[1] if ACTOR else None
    if name == "agora_post":
        if not ACTOR and a.get("event") != "proposal": return None, need_actor()
        child = None if a.get("actor") else dispatched_child_actor()   # gt-eefd：显式 actor 恒优先
        actor = a.get("actor") or child or ACTOR or f"anon@{os.path.basename(CWD)}"
        project = child.rsplit("@", 1)[1] if child else (PROJECT or os.path.basename(lib.main_repo_of(CWD) or CWD))   # 分片随 child 归一，事件行 actor/shard 自洽
        args = ["--actor", actor, "--project", project, "--event", a["event"]]
        for k in ("task","commit","evidence","conclusion","reason","body","idem"):
            if a.get(k): args += [f"--{k}", a[k]]
        if a.get("mention"): args += ["--mention", ",".join(a["mention"])]
        return run_script("post.sh", args)
    if name == "agora_check_mail":
        if not ACTOR: return {"unread": [], "count": 0, "note": "未注册身份无收件箱"}, None
        lib.soft_sync(SCRIPTS, HOME)
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
        v = a.get("view", "all")
        if v not in BOARD_VIEWS:   # 服务端白名单：防越枚举 view 的路径穿越读（任意 .md）
            return None, {"code": "VALIDATION_FAILED", "message": f"bad view: {v}"}
        lib.soft_sync(SCRIPTS, HOME)
        if v == "all":
            views = list(lib.BOARD_CORE_VIEWS)
            # 条件落盘视图：文件在才聚合（agent 侧可见性补全）
            views += [x for x in lib.BOARD_OPTIONAL_VIEWS if os.path.exists(f"{HOME}/board/{x}.md")]
        else:
            views = [v]
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
        if a.get("dispatcher_task"): args += ["--dispatcher-task", a["dispatcher_task"]]
        return run_script("dispatch.sh", args)
    if name == "agora_task_create":
        if not ACTOR: return None, need_actor()
        env = {"TITLE": a["title"]}
        if a.get("body"): env["BODY"] = a["body"]
        if a.get("verify"): env["VERIFY"] = a["verify"]
        if a.get("project_dir"): env["PROJECT_DIR"] = a["project_dir"]
        if a.get("deps"): env["DEPS"] = ",".join(a["deps"])
        if a.get("parent"): env["PARENT"] = a["parent"]
        if a.get("idem"): env["IDEM"] = a["idem"]
        if a.get("wt"): env["WT"] = "1"
        return run_script("task-create.sh", [], extra_env=env)
    if name == "agora_history":
        lib.soft_sync(SCRIPTS, HOME)
        return run_script("history.sh", [], extra_env={"TASK": a["task"]})
    if name == "agora_sync":
        return run_script("sync.sh", ["pre"])
    if name == "agora_who":
        lib.soft_sync(SCRIPTS, HOME)
        roster = []
        cw = lib.main_repo_of(CWD) or CWD   # worktree cwd 归一主 repo（gt-ac14）；hoist 出实体循环
        for f in sorted(glob.glob(f"{HOME}/wiki/entities/*.md")):
            if not lib.valid_entity_name(os.path.basename(f)[:-3]): continue   # 畸形实体名不入名册
            txt = open(f, encoding="utf-8").read()
            dirs = lib.entity_dirs(txt)
            rm = re.search(r'^role:\s*(\S+)', txt, re.M)
            here = False
            for d in dirs:
                if lib.covers(CWD, d) or lib.covers(cw, d): here = True   # 直判优先、归一兜底——对齐 resolve_entity 两段口径
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
    if name == "agora_cancel":
        if not ACTOR: return None, need_actor()
        args = ["--actor", ACTOR]
        if a.get("task"): args += ["--task", a["task"]]
        if a.get("reason"): args += ["--reason", a["reason"]]
        return run_script("cancel.sh", args)
    if name == "agora_redispatch":
        if not ACTOR: return None, need_actor()
        args = ["--actor", ACTOR]
        if a.get("task"): args += ["--task", a["task"]]
        return run_script("redispatch.sh", args)
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
                    "serverInfo": {"name": "agora-mcp", "version": VERSION},
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
