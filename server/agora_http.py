#!/usr/bin/env python3
"""agora-http —— 广场只读 HTTP 窗口 + 内置 Web 浏览页（版本见仓库根 VERSION）

零依赖（stdlib http.server）。只读闭合：只提供 GET，写入仍唯一走 MCP/scripts（宣言铁律）。
安全模型：默认绑 127.0.0.1，本机即信任边界；设 AGORA_HTTP_HOST=0.0.0.0 暴露到局域网
= 该局域网所有人可读广场（无写面，风险仅为信息暴露）。

用法：AGORA_HOME=~/agora python3 server/agora_http.py
环境：AGORA_HTTP_HOST（默认 127.0.0.1） AGORA_HTTP_PORT（默认 0 = 随机分配；固定端口如 8471 可显式指定）
随机端口发现：启动后实际端口写入 $AGORA_HOME/.git/httpd.json（仓库本地，不进 git），
agent 可经 MCP 工具 agora_who 的 http 字段查询（含死进程活体验证）。
"""
import os, re, glob, json, atexit, time, signal, sys
_PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_PKG, "scripts"))
import agora_lib as lib   # 账本/实体页共享解析（与机械层同源）
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOME = os.environ.get("AGORA_HOME", os.path.expanduser("~/agora"))
SCRIPTS = os.environ.get("AGORA_SCRIPTS") or os.path.join(_PKG, "scripts")   # 单源：产品仓 scripts（gt-f6e4；env 覆盖口）
HOST = os.environ.get("AGORA_HTTP_HOST", "127.0.0.1")
PORT = int(os.environ.get("AGORA_HTTP_PORT", "0"))
RUNTIME_FILE = os.path.join(HOME, ".git", "httpd.json")



def read(p):
    try: return open(p, encoding="utf-8").read()
    except Exception: return ""

def all_events(task=None):
    out = []
    for shard, i, e in lib.iter_events(HOME):
        if task and e.get("task") != task: continue
        e.pop("seen", None)  # 与既有 API 形状一致：不外泄 seen
        e["ref"] = f"{shard}:{i}"
        out.append(e)
    return out


def api(path, q):
    lib.soft_sync(SCRIPTS, HOME, timeout=10)
    if path == "/api/board":
        lib.rederive(SCRIPTS, HOME)
        vs = list(lib.BOARD_CORE_VIEWS)
        vs += [v for v in lib.BOARD_OPTIONAL_VIEWS if os.path.exists(f"{HOME}/board/{v}.md")]
        return {"views": {v: read(f"{HOME}/board/{v}.md") for v in vs}}
    if path == "/api/tasks":
        tasks = []
        for f in sorted(glob.glob(f"{HOME}/wiki/tasks/*.md")):
            fm, _ = lib.parse_frontmatter(read(f))
            if fm.get("id"): tasks.append(fm)
        return {"tasks": tasks}
    if path == "/api/task":
        tid = (q.get("id") or [""])[0]
        if not re.match(r'^gt-[0-9a-f]{4,}$', tid):
            return None, ("INVALID_ID", "需要 id=gt-xxxx")
        page = read(f"{HOME}/wiki/tasks/{tid}.md")
        if not page: return None, ("NOT_FOUND", f"无任务页 {tid}")
        return {"id": tid, "page": page, "events": all_events(task=tid)}
    if path == "/api/events":
        try: limit = max(1, min(500, int((q.get("limit") or ["100"])[0])))
        except ValueError: limit = 100
        evs = all_events()
        return {"count": len(evs), "events": evs[-limit:]}
    if path == "/api/entities":
        roster = []
        for f in sorted(glob.glob(f"{HOME}/wiki/entities/*.md")):
            name = os.path.basename(f)[:-3]
            if not lib.valid_entity_name(name): continue   # 畸形实体名不入名册
            txt = read(f)
            fm, _ = lib.parse_frontmatter(txt)
            dirs = lib.entity_dirs(txt)
            roster.append({"name": name,
                           "dirs": dirs,
                           "can_spawn": fm.get("can_spawn") == "true",
                           "role": fm.get("role", "worker"),
                           "active": fm.get("active", "true")})
        return {"roster": roster}
    if path == "/api/inbox":
        name = (q.get("name") or [""])[0]
        if not re.match(r'^[\w.-]+$', name) or name in (".", ".."):
            return None, ("INVALID_NAME", "需要 name=<实体名>")
        items = []
        for f in sorted(glob.glob(f"{HOME}/inbox/{name}/*.md")):
            m = re.match(r'- from:(\S+) \| ts:(\S+) \| ref:(\S+) \| summary:(.*)',
                         read(f).strip())
            if m: items.append({"from": m.group(1), "ts": m.group(2),
                                "ref": m.group(3), "summary": m.group(4)})
        return {"name": name, "count": len(items), "items": items}
    if path == "/api/wiki":
        p = (q.get("path") or [""])[0]
        if not p or ".." in p or p.startswith("/"):
            return None, ("INVALID_PATH", "path 必须在 wiki/ 内")
        fp = f"{HOME}/wiki/{p}"
        if not os.path.isfile(fp): return None, ("NOT_FOUND", p)
        return {"path": p, "content": read(fp)}
    return None, ("NOT_FOUND", path)

INDEX_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agora 广场</title>
<style>
:root{--ink:#1e293b;--mut:#64748b;--line:#e2e8f0;--bg:#f6f7f9;--acc:#2563eb;--ok:#16a34a;--warn:#d97706;--bad:#dc2626}
*{box-sizing:border-box;margin:0}
body{font:14px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;background:var(--bg);color:var(--ink)}
header{background:#0f172a;color:#fff;padding:14px 24px;display:flex;align-items:baseline;gap:16px;flex-wrap:wrap}
header h1{font-size:18px;font-weight:600}
header .sub{color:#94a3b8;font-size:12px}
nav{display:flex;gap:6px;margin-left:auto;flex-wrap:wrap}
nav button{background:transparent;border:1px solid #334155;color:#cbd5e1;border-radius:6px;padding:5px 14px;cursor:pointer;font-size:13px}
nav button.on{background:var(--acc);border-color:var(--acc);color:#fff}
main{max-width:1000px;margin:20px auto;padding:0 16px}
.card{background:#fff;border:1px solid var(--line);border-radius:10px;padding:16px 20px;margin-bottom:14px}
.card h2{font-size:15px;margin-bottom:10px;display:flex;align-items:center;gap:8px}
.badge{font-size:11px;padding:1px 8px;border-radius:10px;background:#e2e8f0;color:var(--mut)}
.badge.done{background:#dcfce7;color:var(--ok)}.badge.prog{background:#dbeafe;color:var(--acc)}
.badge.block{background:#fee2e2;color:var(--bad)}.badge.cancel{background:#f1f5f9;color:var(--mut)}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--mut);font-weight:500;font-size:12px}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px}
a{color:var(--acc);text-decoration:none}
.md h1,.md h2,.md h3{margin:12px 0 6px;font-size:15px}
.md ul{padding-left:20px}.md p{margin:6px 0}
.md code{background:#f1f5f9;padding:1px 5px;border-radius:4px;font-size:12.5px}
.md pre{background:#f8fafc;border:1px solid var(--line);border-radius:8px;padding:10px;overflow:auto;font-size:12.5px}
.md hr{border:none;border-top:1px solid var(--line);margin:10px 0}
.md blockquote{border-left:3px solid var(--line);padding-left:12px;color:var(--mut)}
#status{font-size:12px;color:var(--mut);text-align:right;padding:6px 2px}
.empty{color:var(--mut);font-size:13px;padding:8px 0}
input,select{border:1px solid var(--line);border-radius:6px;padding:5px 10px;font-size:13px;margin-right:8px}
.ev{border-left:3px solid var(--line);padding:4px 12px;margin:6px 0;font-size:13px}
.ev .t{color:var(--mut);font-size:12px}
.ev.claimed{border-color:var(--acc)}.ev.done{border-color:var(--ok)}
.ev.blocked,.ev.escalated{border-color:var(--bad)}.ev.cancelled{border-color:var(--mut)}
</style>
</head>
<body>
<header>
  <h1>🏛 Agora 广场</h1><span class="sub" id="home"></span>
  <nav id="tabs"></nav>
</header>
<main><div id="status"></div><div id="view"></div></main>
<script>
const TABS=[["board","看板"],["tasks","任务"],["events","事件流"],["entities","名册"],["wiki","Wiki"]];
let cur="board", timer=null;
const $=s=>document.querySelector(s);
const esc=s=>s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
function md(src){
  let s=esc(src);
  s=s.replace(/&lt;!--[\s\S]*?--&gt;/g,"");  // 剥离派生标记注释
  s=s.replace(/```([\s\S]*?)```/g,(m,c)=>"<pre>"+c+"</pre>");
  s=s.split("\n").map(l=>{
    if(l.startsWith("### "))return"<h3>"+inline(l.slice(4))+"</h3>";
    if(l.startsWith("## "))return"<h2>"+inline(l.slice(3))+"</h2>";
    if(l.startsWith("# "))return"<h1>"+inline(l.slice(2))+"</h1>";
    if(l.startsWith("- "))return"<ul><li>"+inline(l.slice(2))+"</li></ul>";
    if(l.trim()==="---")return"<hr>";
    if(l.startsWith("> "))return"<blockquote>"+inline(l.slice(2))+"</blockquote>";
    return l.trim()?"<p>"+inline(l)+"</p>":"";
  }).join("\n");
  return s.replace(/<\/ul>\n<ul>/g,"");
}
function inline(s){
  return s.replace(/\*\*([^*]+)\*\*/g,"<b>$1</b>").replace(/`([^`]+)`/g,"<code>$1</code>");
}
async function api(p){const r=await fetch(p);if(!r.ok)throw new Error((await r.json()).message||r.status);return r.json();}
function renderTabs(){
  $("#tabs").innerHTML=TABS.map(([k,n])=>`<button class="${k===cur?'on':''}" onclick="go('${k}')">${n}</button>`).join("");
}
function go(t){cur=t;renderTabs();load();if(timer)clearInterval(timer);if(t==="board"||t==="events")timer=setInterval(load,15000);}
function stamp(){$("#status").textContent="更新于 "+new Date().toLocaleTimeString()+"（每 15s 自动刷新）";}
async function load(){
  try{
    if(cur==="board")return loadBoard();
    if(cur==="tasks")return loadTasks();
    if(cur==="events")return loadEvents();
    if(cur==="entities")return loadEntities();
    if(cur==="wiki")return loadWiki();
  }catch(e){$("#view").innerHTML=`<div class="card empty">加载失败：${esc(e.message)}</div>`;}
}
async function loadBoard(){
  const d=await api("/api/board");
  const names={todo:"Todo（ready）","in-progress":"进行中",blocked:"受阻",conflicts:"冲突（claim_conflict）",cancelled:"已取消"};
  const count=v=>(v.match(/^- .+/gm)||[]).filter(l=>!l.includes("（空）")&&!l.startsWith("- **")).length;
  const stripH1=v=>v.replace(/^<!--[\s\S]*?-->\s*/,"").replace(/^# [^\n]*\n/,"");  // 卡片已有标题，去掉 md 自带 H1
  $("#view").innerHTML=Object.entries(d.views).map(([k,v])=>
    `<div class="card"><h2>${names[k]}<span class="badge">${count(v)}</span></h2><div class="md">${md(stripH1(v))}</div></div>`).join("");
  stamp();
}
async function loadTasks(){
  const d=await api("/api/tasks");
  if(!d.tasks.length){$("#view").innerHTML='<div class="card empty">尚无任务</div>';return stamp();}
  $("#view").innerHTML=d.tasks.map(t=>{
    const det=[t.parent&&("计划: "+t.parent),t.verify&&("verify: "+t.verify),(t.deps||[]).length&&("deps: "+t.deps.join(", "))].filter(Boolean).join(" · ");
    return `<div class="card"><h2><a href="#" onclick="taskDetail('${t.id}');return false" class="mono">${t.id}</a> ${esc(t.title||"")}
      <span class="badge">${esc(t.status||"")}</span></h2>
      ${det?`<div class="empty mono">${esc(det)}</div>`:""}
      <div id="d-${t.id}"></div></div>`;}).join("");
  stamp();
}
async function taskDetail(id){
  const el=$("#d-"+id); if(el.dataset.open){el.innerHTML="";delete el.dataset.open;return;}
  const d=await api("/api/task?id="+id); el.dataset.open="1";
  el.innerHTML=`<div class="md">${md(d.page)}</div><h2 style="margin-top:10px">事件链（${d.events.length}）</h2>`+
    (d.events.map(evHTML).join("")||'<div class="empty">无事件</div>');
}
function evHTML(e){
  const extra=Object.entries(e).filter(([k])=>!["ref","seq","ts","actor","event","idem","seen","task"].includes(k)&&e[k])
    .map(([k,v])=>`<span class="mono" style="color:var(--mut)">${esc(k)}:${esc(String(v))}</span>`).join(" · ");
  return `<div class="ev ${e.event}"><b>${esc(e.event)}</b> ${e.task?`<a href="#" class="mono" onclick="go('tasks');return false">${esc(e.task)}</a>`:""} <span class="mono">${esc(e.actor)}</span>
    <div class="t">${esc(e.ts)} · ${esc(e.ref)}</div>${extra?`<div>${extra}</div>`:""}</div>`;
}
async function loadEvents(){
  const d=await api("/api/events?limit=100");
  $("#view").innerHTML=`<div class="card"><h2>事件流<span class="badge">${d.count} 总计</span></h2>`+
    (d.events.slice().reverse().map(evHTML).join("")||'<div class="empty">无事件</div>')+"</div>";
  stamp();
}
async function loadEntities(){
  const d=await api("/api/entities");
  $("#view").innerHTML=`<div class="card"><h2>名册<span class="badge">${d.roster.length}</span></h2><table>
    <tr><th>名字</th><th>角色</th><th>can_spawn</th><th>目录</th><th>收件箱</th></tr>`+
    d.roster.map(e=>`<tr><td class="mono"><b>${esc(e.name)}</b></td><td>${esc(e.role)}</td>
      <td>${e.can_spawn?"✅":"—"}</td><td class="mono">${e.dirs.map(esc).join("<br>")}</td>
      <td><a href="#" onclick="inbox('${e.name}');return false">查看</a><span id="ib-${e.name}"></span></td></tr>`).join("")+"</table></div>";
  stamp();
}
async function inbox(name){
  const d=await api("/api/inbox?name="+name);
  $("#ib-"+name).innerHTML=`（${d.count}）`+(d.count?("<br>"+d.items.map(i=>`<span class="mono" style="font-size:12px">${esc(i.ts)} ${esc(i.from)}: ${esc(i.summary)}</span>`).join("<br>")):"");
}
async function loadWiki(){
  $("#view").innerHTML=`<div class="card"><h2>Wiki 浏览</h2>
    <input id="wp" value="CONVENTIONS.md" style="width:300px"><button onclick="wikiGo()" style="border:1px solid var(--line);border-radius:6px;padding:5px 12px;cursor:pointer">打开</button>
    <div class="empty">常用：CONVENTIONS.md · AGENTS.md · decisions/ · topics/ · entities/&lt;名字&gt;.md · tasks/&lt;gt-xxxx&gt;.md</div>
    <div id="wbody"></div></div>`;
  wikiGo();
}
async function wikiGo(){
  try{const d=await api("/api/wiki?path="+encodeURIComponent($("#wp").value));
    $("#wbody").innerHTML=`<div class="md">${md(d.content)}</div>`;
  }catch(e){$("#wbody").innerHTML=`<div class="empty">${esc(e.message)}</div>`;}
}
fetch("/api/entities").then(()=>{$("#home").textContent="只读窗口 · 每 15s 自动刷新";}).catch(()=>{});
renderTabs();go("board");
</script>
</body>
</html>
"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send_json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            body = INDEX_HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if u.path.startswith("/api/"):
            r = api(u.path, parse_qs(u.query))
            if isinstance(r, tuple):  # (None, (code, msg)) —— 参数/资源错误
                self.send_json({"error": r[1][0], "message": r[1][1]}, 400)
            elif r is None:
                self.send_json({"error": "NOT_FOUND"}, 404)
            else:
                self.send_json(r)
            return
        self.send_json({"error": "NOT_FOUND"}, 404)

if __name__ == "__main__":
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    actual = srv.server_address[1]  # PORT=0 时由操作系统分配的空闲端口
    url = f"http://{HOST}:{actual}/"
    try:
        with open(RUNTIME_FILE, "w") as f:  # .git/ 内 = 仓库本地，绝不进同步
            json.dump({"url": url, "host": HOST, "port": actual,
                       "pid": os.getpid(), "started": time.strftime("%Y-%m-%dT%H:%M:%S")}, f)
        def _cleanup(*_):
            try: os.remove(RUNTIME_FILE)
            except Exception: pass
            os._exit(0)
        atexit.register(lambda: os.path.exists(RUNTIME_FILE) and os.remove(RUNTIME_FILE))
        signal.signal(signal.SIGTERM, _cleanup)  # kill/systemd stop 也要清运行文件
        signal.signal(signal.SIGINT, _cleanup)
    except Exception:
        pass
    print(f"agora-http 只读窗口：{url}  (AGORA_HOME={HOME})")
    srv.serve_forever()
