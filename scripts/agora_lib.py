#!/usr/bin/env python3
"""agora_lib —— 账本行格式与共享解析的唯一真源（版本见仓库根 VERSION）

契约：log/ 事件行、实体页 dirs 块、frontmatter 的解析只在此处定义一份；
derive-board / history / doctor / dispatch / poll 的 heredoc 与
agora_mcp / agora_http（发行包侧）共同引用。init.sh 把本文件随 scripts/*.sh
一并自举复制进广场仓，两份拷贝字节一致。
改这里 = 改账本契约，必须同步 docs/Agora接口规格-v1.md。
"""
import os, re, glob, subprocess

# 账本行（规格 §3）：- seq:N | ts:... | actor:... | event:... | idem:... | seen:... | k:v ...
LINE_RE = re.compile(r'^- seq:(\d+) \| ts:(\S+) \| actor:(\S+) \| event:(\w+) \| idem:(\S+) \| seen:(\S+)(.*)$')
KV_RE = re.compile(r'(\w+):((?:[^|]|\|(?!\s*\w+:))*?)(?=\s*\|\s*\w+:|$)')

# 看板视图契约（规格 §4.3）：全枚举/白名单、常驻列、条件列——双 server 单点口径
BOARD_VIEWS = ("todo", "waiting", "in-progress", "blocked", "conflicts", "cancelled", "all")
BOARD_CORE_VIEWS = ("todo", "waiting", "in-progress", "blocked")
BOARD_OPTIONAL_VIEWS = ("conflicts", "cancelled")


def kv(rest):
    """尾部 k:v 串 → dict（strip、去空值）。"""
    return {k: v.strip() for k, v in KV_RE.findall(rest) if v.strip()}


def parse_event(line):
    """账本行 → dict（seq 为 int，含全部尾字段；非事件行 → None）。"""
    m = LINE_RE.match(line.strip() if isinstance(line, str) else line)
    if not m:
        return None
    d = kv(m.group(7))
    d.update(seq=int(m.group(1)), ts=m.group(2), actor=m.group(3),
             event=m.group(4), idem=m.group(5), seen=m.group(6))
    return d


def parse_frontmatter(txt):
    """---\\n...---\\n 头 → (fm dict, body)。列表值 [a, b] 自动转 list。"""
    m = re.match(r'^---\n(.*?)\n---\n?', txt, re.S)
    fm, body = {}, txt
    if m:
        body = txt[m.end():]
        for line in m.group(1).splitlines():
            km = re.match(r'^(\w+):\s*(.*)$', line)
            if not km:
                continue
            k, v = km.group(1), km.group(2).strip()
            if v.startswith("[") and v.endswith("]"):
                v = [x.strip() for x in v[1:-1].split(",") if x.strip()]
            fm[k] = v
    return fm, body.strip()


def entity_dirs(txt):
    """实体页 dirs: 块 → 目录原值列表（严格块语义，全仓唯一口径）。"""
    m = re.search(r'^dirs:\s*\n((?:\s+-\s+.+\n)+)', txt, re.M)
    return re.findall(r'-\s+(\S+)', m.group(1)) if m else []


def main_repo_of(p):
    """路径所在 worktree 的主 repo；非 worktree（普通 repo、无 .git、畸形 gitdir）→ None。
    自 p 逐级向上找最近 .git：目录=普通 repo 即停（p 自身即实体路径，无需归一）；
    文件且 gitdir 指向 <main>/.git/worktrees/<name> 且主 repo .git 目录在场 → 主 repo（防捏造/逃逸，gt-ac14）。"""
    p = os.path.realpath(p)
    while True:
        g = os.path.join(p, ".git")
        if os.path.isdir(g): return None
        if os.path.isfile(g):
            try: line = open(g, encoding="utf-8", errors="replace").read().strip()
            except OSError: return None
            if line.startswith("gitdir:"):
                dd = os.path.dirname(os.path.realpath(os.path.join(p, line[7:].strip())))  # <main>/.git/worktrees
                if os.path.basename(dd) == "worktrees" and os.path.basename(os.path.dirname(dd)) == ".git":
                    mr = os.path.dirname(os.path.dirname(dd))
                    if os.path.isdir(os.path.join(mr, ".git")): return mr
            return None
        up = os.path.dirname(p)
        if up == p: return None
        p = up


def covers(path, d):
    """实体 dirs 项 d 是否覆盖 path（前缀语义，两路径均归一）。"""
    rd = os.path.realpath(os.path.expanduser(d))
    return path == rd or path.startswith(rd + "/")


def resolve_entity(home, path):
    """路径 → 实体 (name, matched_dir, projroot)；无命中 → None。
    前缀最深优先；worktree 路径归一到主 repo 再匹配（projroot=主 repo），adjudicate/who/dispatch 唯一口径。"""
    target = os.path.realpath(path)

    def match(root):
        best = None
        for f in glob.glob(f"{home}/wiki/entities/*.md"):
            if not valid_entity_name(os.path.basename(f)[:-3]): continue   # 畸形实体名不参与解析
            txt = open(f, encoding="utf-8").read()
            for d in entity_dirs(txt):
                d = os.path.realpath(os.path.expanduser(d))
                if covers(root, d) and (best is None or len(d) > len(best[1])):
                    best = (os.path.basename(f)[:-3], d)
        return best

    hit, projroot = match(target), target
    if hit is None:
        mr = main_repo_of(target)
        if mr is not None:
            hit = match(mr)
            if hit is not None: projroot = mr
    return (hit[0], hit[1], projroot) if hit else None

ENTITY_NAME_RE = re.compile(r'^[\w][\w.-]*\Z')   # \Z 而非 $：$ 在尾随换行前也匹配


def valid_entity_name(name):
    """实体名 = wiki/entities/<name>.md 的 basename：防畸形名（尾随空格/特殊字符）撕裂账本行解析。"""
    return bool(name) and bool(ENTITY_NAME_RE.match(name)) and ".." not in name


def iter_events(home):
    """全部账本分片（含点前缀分片如 .dotfiles.md）→ (shard 相对路径, 行号, 事件 dict)，按权威序逐条产出。"""
    for f in sorted(glob.glob(os.path.join(home, "log", "*", "*.md"))
                    + glob.glob(os.path.join(home, "log", "*", ".*.md"))):
        shard = os.path.relpath(f, home)
        with open(f, encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                d = parse_event(line)
                if d:
                    yield shard, i, d


def scan_tasks(home):
    """task -> {"dispatched":[(actor,run,dispatcher_task,session)...], "has":set(events), "last":event, "inflight":bool}。
    账本推导唯一口径（重派/孤儿/GC/豁免/drill 忙碌守卫共用）；last/done_open/inflight 按 ts 序重放（跨分片文件序≠时间序）。
    自 poll.sh 提取（gt-ef4c T2）：drill 复用同一在飞口径，禁另立解析第二真源。"""
    tasks = {}
    for f in sorted((glob.glob(f"{home}/log/*/*.md") + glob.glob(f"{home}/log/*/.*.md"))):
        with open(f, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                e = parse_event(line)
                if not e: continue
                t = e.get("task") or ""
                if not re.fullmatch(r"gt-[0-9a-f]+", t): continue
                d = tasks.setdefault(t, {"dispatched": [], "has": set(), "last": None, "done_open": False, "terminal": False, "inflight": False, "last_actor": "", "last_terminal": None, "_rows": [], "post_disp": None})
                d["_rows"].append((e.get("ts", ""), e["event"], e.get("actor", "")))
                d["has"].add(e["event"])
                d["last_actor"] = e.get("actor", "")
                if e["event"] == "dispatched":
                    d["dispatched"].append((e.get("actor", ""), e.get("run", ""), e.get("dispatcher_task", ""), e.get("session", "")))
    for d in tasks.values():
        # gt-caf3/gt-db15：跨分片文件序≠时间序，状态机统一按 ts 序；gt-40cc①：同秒平局仅对
        # 「真闭铃」merged/cancelled 升阶（2）——跨分片同秒时闭铃压过 done/dispached 的扫描序，
        # 防已取消任务被孤儿档复活重派、被误燃 done-unmerged 梯子。done/reopened/dispatched 同为
        # 0 阶：同片按追加序（＝真因果序）——守卫六 done→reopened 同秒须 reopened 收 done_open、
        # redispatch 流 reopened→dispatched 同秒须 dispatched 压尾（终闸 ocr high），升阶任一即瞎
        _RANK = {"merged": 2, "cancelled": 2}
        rows = sorted(d["_rows"], key=lambda r: (r[0], _RANK.get(r[1], 0)))
        d["last"] = rows[-1][1] if rows else None  # B-M3：last 按 ts 序取尾行——与 done_open 重放同口径（同 ts 平局一致）
        for _ts, ev, _ac in rows:  # gt-db15：done_open 同按 ts 序重放——同日多分片文件名字典序≠时间序
            if ev == "done": d["done_open"] = True          # done 未闭：merged/cancelled/reopened 才清
            elif ev in ("merged", "cancelled", "reopened"): d["done_open"] = False
            if ev in ("merged", "cancelled"): d["terminal"] = True; d["last_terminal"] = ev   # gt-99af：当前终态（mention 核查棒）；gt-b5e9：记明哪一种（GC 窄域判别）
            elif ev == "reopened": d["terminal"] = False     # 返工/恢复重开 → 回到可拾取
            # gt-ae6f 守卫二在飞口径：只计末次 reopened 之后（且未被终态闭合）的 dispatched——
            # reopened 返工清空在飞（历史 dispatched 不永久压制回池任务），merged/cancelled 闭飞
            if ev == "reopened": d["inflight"] = False; d["post_disp"] = None
            elif ev == "dispatched": d["inflight"] = True; d["post_disp"] = set()
            elif ev in ("merged", "cancelled"): d["inflight"] = False
            elif d["post_disp"] is not None and not _ac.startswith("watchdog@"):
                d["post_disp"].add(ev)   # gt-7ca0：尾派发后的子会话活动（watchdog 机械回执不算——不遮蔽真停转）
        del d["_rows"]
    return tasks


def soft_sync(scripts, home, timeout=30):
    """读前静默 pre-pull（离线/失败不影响读）。"""
    try:
        subprocess.run(["bash", os.path.join(scripts, "sync.sh"), "pre"],
                       capture_output=True, text=True, timeout=timeout,
                       env={**os.environ, "AGORA_HOME": home})
    except Exception:
        pass


def rederive(scripts, home, timeout=15):
    """看板重推导（幂等；失败沿用现有文件）。"""
    try:
        subprocess.run(["bash", os.path.join(scripts, "derive-board.sh")],
                       capture_output=True, timeout=timeout,
                       env={**os.environ, "AGORA_HOME": home})
    except Exception:
        pass
