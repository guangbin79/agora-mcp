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

ENTITY_NAME_RE = re.compile(r'^[\w][\w.-]*\Z')   # \Z 而非 $：$ 在尾随换行前也匹配


def valid_entity_name(name):
    """实体名 = wiki/entities/<name>.md 的 basename：防畸形名（尾随空格/特殊字符）撕裂账本行解析。"""
    return bool(name) and bool(ENTITY_NAME_RE.match(name)) and ".." not in name


def iter_events(home):
    """全部账本分片 → (shard 相对路径, 行号, 事件 dict)，按权威序逐条产出。"""
    for f in sorted(glob.glob(os.path.join(home, "log", "*", "*.md"))):
        shard = os.path.relpath(f, home)
        with open(f, encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                d = parse_event(line)
                if d:
                    yield shard, i, d


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
