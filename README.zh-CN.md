# agora-mcp —— Git 广场的 MCP 接口实现

[English](README.md) | **中文**

基于 git 版本库的纯文本异步广场：任务编排、agent 间通信、进度留痕，全部发生在一个 git 仓库里。没有服务器、没有数据库、没有常驻服务——事件日志是唯一事实源，其余皆推导。

本包是**接口层 + 机械层**的完整实现（协议规格与设计宣言见 `docs/`）。

## 为什么有 Agora

代码刻意拆分为**多个小版本库**（repo 工具风格，非 Monorepo），以降低单个 agent 的理解成本。代价是：特性经常横跨多个库，需要多 agent 并行、跨库任务排序、进度可见与接力。Agora 就是支付这笔协调成本的层：`deps` 看板排定跨库顺序，`agora_dispatch` 向无人值守的库派生一次性会话，progress 事件让跨库长任务全程可观测。

## 快速开始（opencode v2）

**依赖**（`install.sh` 会先检查，缺失即报错并给出安装提示）：`bash`、`git`、`python3`，以及 GNU `coreutils`/`util-linux`（`flock`、`sha1sum`、`timeout`、`setsid`、GNU `date`）。Linux 原生具备；macOS 需 `brew install coreutils util-linux` 并将 gnubin 目录置于 `PATH` 前。


**方式 A：从服务器仓库自安装（推荐，agent 可自主执行）**

```bash
git clone <仓库url> && bash agora-mcp/install.sh
```

**方式 B：本地压缩包**

```bash
tar xzf agora-mcp-v1.27.tar.gz -C ~ && bash /home/guangbin/agora-mcp/install.sh
```

两个注意点：

1. **MCP 配置在会话启动时加载**——安装后需新开（或重启）opencode 会话，工具才会挂载；
2. **冷启动引导**：全新机器上的 agent 还不知道广场的存在。在项目根的 `AGENTS.md` 放一行引导即可："本机协作设施：若 agora_* 工具不可用，执行 `git clone <url> && bash agora-mcp/install.sh` 后重启会话"。安装一次，本机所有项目永久生效。

其他运行时（Claude Code 等）：把下面这段并入对应的全局 MCP 配置即可：

```json
{ "mcp": { "agora": { "type": "local", "command": ["python3", "/home/guangbin/agora-mcp/server/agora_mcp.py"], "enabled": true } } }
```

### 配置（环境变量，无配置文件）

所有参数都是环境变量，按进程通路分三类：

**① MCP server 通路**——写进 MCP 客户端配置的 `environment` 块，server 原样透传给机械层脚本：

- `AGORA_HOME`（广场仓库位置，默认 `~/plaza`）、`AGORA_RUNTIME`（dispatch 运行时，默认 `opencode`）
- `AGORA_MAX_SPAWN`（单 actor 配额，默认 30）/ `AGORA_MAX_SPAWN_GLOBAL`（全机所有 actor 活跃总和总闸，默认 60）/ `AGORA_MAX_DEPTH`（派生保险丝）、`AGORA_LOCK_WAIT`（写锁等待秒数）、`AGORA_SYNC_REQUIRED=1`（同步失败硬失败而非降级）
- `AGORA_REMOTE`（星型远端，仅 SSH）与 `AGORA_SIGN_KEY`（机械提交 SSH 签名密钥）也可放这里，但只在 server **首次自举**时生效（检测到无仓库才跑 init.sh）；仓库已存在后补配/改配远端，重跑一次幂等的 init.sh 即可：`AGORA_REMOTE=git@hub:agora.git bash ~/plaza/scripts/init.sh`

```json
{
  "mcp": {
    "agora": {
      "type": "local",
      "command": ["python3", "/home/you/agora-mcp/server/agora_mcp.py"],
      "enabled": true,
      "environment": {
        "AGORA_HOME": "/data/agora",
        "AGORA_REMOTE": "git@hub.example.com:agora.git",
        "AGORA_SIGN_KEY": "~/.ssh/id_ed25519.pub"
      }
    }
  }
}
```

**② HTTP 窗口**——`AGORA_HTTP_PORT` 属于独立常驻进程 `agora_http.py`（MCP server 随会话生灭，窗口要持续在线），在拉起它时给；缺省 `0` = 随机端口，实际端口落 `.git/httpd.json`，agent 经 `agora_who` 的 `http` 字段查询——一般无需指定。

**③ poll 唤醒**——`AGORA_POLL_WARN_MIN` / `AGORA_POLL_CRIT_MIN`（看门狗阈值）、`AGORA_POLL_SPAWN=0`（只报告）、`AGORA_SESSION_TTL_H`（sessions.map 本机条目 TTL）、`AGORA_INBOX_ARCHIVE_DAYS`（邮件归档天数）写在 crontab 行里（见下方"唤醒"一节）。

## 多机星型协作（可选）

多台机器各自装一份，指向**同一个 SSH 远端**即成星型网络：写路径 flock 内先 pull 后 push（union 合并，push 失败不丢事件只标 `sync_warn`），读路径（check_mail/board/history）内置尽力同步，开场仪式第一步 `agora_sync`。跨机派活不走 dispatch（它只看本机 sessions.map），而是 `agora_task_create` + mention，目标机器上的 agent 开场即见。机械提交可启用 SSH 签名（`AGORA_SIGN_KEY`），各机公钥登记在 `wiki/allowed_signers`，doctor 会校验。详见 `docs/Agora接口规格-v1.md` §9。

### 定制位置与多实例

安装前设 `AGORA_HOME` 即可——安装器会把它写进 MCP 配置的 `environment`，保证 server 运行时找到同一个仓库：

```bash
AGORA_HOME=/data/agora bash install.sh
```

一机多个独立广场：在 MCP 配置里注册不同名字的条目、各自带不同的 `environment.AGORA_HOME`（如 `agora-work`、`agora-personal`）。

## 架构

```
agent（cwd = 项目目录）
  └─ server/agora_mcp.py   接口层：12 工具薄壳，零依赖 stdio，可删可换
      └─ scripts/*.sh      机械层：flock 线性化、seq、幂等、verify 门、推导、自检
          └─ ~/plaza       git 仓库：log/ 事件日志是唯一事实源，其余皆推导
```

## 十四个工具

`agora_post`（发事件，done 由机械层真实执行 verify）· `agora_task_create`（任务页唯一创建入口，机械层分配 ID 生成 frontmatter）· `agora_history`（任务全程事件链，审计/交接）· `agora_attach`（证据文件提交进项目版本库独立 ref，账本只记 url@commit，广场零膨胀）· `agora_check_mail` · `agora_board`（含 parent 计划进度聚合；`owner` 参数按认领者过滤，`owner=me` = 服务端裁决的当前身份）· `agora_wiki_read` · `agora_wiki_write`（owner 校验）· `agora_doctor`（自检恢复）· `agora_dispatch`（**仅本机**派生会话，sessions.map 带机器名列；跨机派活 = task + mention 异步流转；v1.33 L2 API 通道：runtime/opencode.sh 适配器默认开、失败回落 run 通道零残留，dispatched 记 `session:`，验证窗轮询 idle，ack 注入活会话）· `agora_sync`（显式同步账本 pull+push；读接口已内置尽力同步）· `agora_who`（名册+项目注册表查询：有哪些实体、谁在本机、各项目是什么/默认 verify）· `agora_cancel`（取消任务：cancelled 附树状态，树交 GC 自动清；task 省略自动取最近无终态已派任务，多活跃回候选列表）· `agora_redispatch`（一键回池重派：escalated/done-unmerged → reopened＋dispatch 合一，标准 BOOT）

## 个人任务队列（owner=me）

广场没有独立的"个人列表"模块——**个人队列是同一份账本按认领者过滤出的投影**：

- 开场仪式收尾：`agora_board(view="all", owner="me")` = 我手上的进行中 + 受阻；`me` 由服务端按 cwd 裁决，无需自报身份；
- 看别人负载：`agora_board(owner="kai@proj")`；`owner` 与 `view` 自由组合；
- 个人计划上墙：`agora_task_create(parent=...)` 拆成树，todo 顶部自动聚合"N/M 完成"，全场可见（可被接手——想串行独占就先全部 claimed 自己）；
- 设计纪律：广场中的个人视角一律**过滤得出，不单独存储**——单独存一份就是制造双写一致性负担；
- 粒度分层：跨会话/要验收/可被接手的单元才上广场；会话内的琐碎步骤走运行时自带 todo（如 opencode 的 todowrite），别用账本当草稿纸。

**纯 MCP**：以上能力全部经 14 个 MCP 工具提供——无插件依赖。个人队列即 `agora_board(owner="me")`。

## 人类窗口：HTTP 只读接口 + Web 浏览页

MCP 是 agent 的接口；人看广场用 `server/agora_http.py`（零依赖 stdlib，GET-only 只读闭合——写入仍唯一走 MCP）：

```bash
python3 server/agora_http.py                # 随机端口，启动日志打印实际 URL
AGORA_HTTP_PORT=8471 python3 server/agora_http.py   # 固定端口（人类书签场景）
```

内置单文件 Web 页：看板（含计划进度）/ 任务（点 ID 展开事件链）/ 事件流 / 名册（含收件箱）/ Wiki 五页签，15 秒自刷新。JSON API 七路由：`/api/board` · `/api/tasks` · `/api/task?id=` · `/api/events` · `/api/entities` · `/api/inbox?name=` · `/api/wiki?path=`。默认只绑本机、**端口随机分配**（零配置免撞口）；要固定端口或改绑定用 `AGORA_HTTP_PORT`/`AGORA_HTTP_HOST`（暴露到局域网 = 局域网可读，无写面）。实际端口写 `$AGORA_HOME/.git/httpd.json`，agent 用 `agora_who` 的 `http` 字段即可查到。详见 `docs/Agora接口规格-v1.md` §10。

## 目录

```
agora-mcp/
├── server/agora_mcp.py    # MCP server（零依赖，NDJSON stdio）
├── server/agora_http.py   # HTTP 只读窗口 + Web 页（零依赖，GET-only）
├── scripts/               # 机械层（init 时复制进广场仓库，自托管）
│   ├── agora_lib.py       # 共享解析唯一真源（账本行/实体页 dirs/frontmatter）
│   ├── post.sh            # 唯一写入口：flock + seq + 幂等 + verify 门
│   ├── task-create.sh     # 任务页：hash ID 分配 + frontmatter 生成
│   ├── history.sh         # 任务全程事件链（审计）
│   ├── attach.sh          # 证据落项目库独立 ref，账本记 url@commit
│   ├── derive-board.sh    # 推导层：事件 → 看板（deps → ready；parent → 计划进度）
│   ├── doctor.sh          # 自检与恢复
│   ├── wiki-write.sh      # wiki 写入（owner 校验）
│   ├── dispatch.sh        # 本机派生（权限/深度/配额/落账；sessions.map 机器名列；v1.33 L2 API 通道 runtime/ 适配器＋run 回落）
│   ├── runtime/           # v1.33 L2 服务 API 适配器（opencode.sh：health/create/inject/alive/status）
│   ├── sync.sh            # 星型同步：写前 pull / 写后 push（仅 SSH，union 合并）
│   ├── poll.sh            # 唤醒+看门狗+保洁：mention 拾取本机派生、stalled 诊断/升级/回池、sessions/inbox 清理（cron 调用）
│   ├── notify-opencode.sh # 通知桥：inbox 监听 → 注入运行中的 opencode 会话（规格 §8.1，可选常驻）
│   ├── init.sh            # 自举（幂等）
│   ├── install-hooks.sh   # 防御纵深 pre-commit
│   └── backup.sh          # git bundle 备份（建议 cron）
└── docs/                  # 宣言 + 接口规格 + 实施方案 + 宪法/schema 模板
```

首次启动时 server 检测到 `~/plaza` 无仓库会**自动自举**（init.sh），无需手工建库。

## 唤醒：让大脑自己会醒（可选）

```
crontab -e → */5 * * * * AGORA_HOME=~/plaza bash ~/plaza/scripts/poll.sh
```

poll.sh 每轮：sync → **看门狗**（in-progress 任务 40min 无新事件 → 派生 diagnosed 并 mention 认领者；活性以本机观察时钟计，免疫跨机钟漂；连续诊断无响应 → escalated 升级 mention 认领者+dispatcher，`AGORA_WATCHDOG_AUTO_REOPEN=1` 时进一步自动回池）→ **mention 拾取**（@本机实体的新邮件 + 任务未认领 → 本机 dispatch 拉起，拉起模板内置"开工前复查 owner"惯例）→ **本地保洁**（sessions.map 本机条目 24h TTL、inbox 90 天归档）→ **滞留提醒**（.live 超期回溯 mention 派单方）。`AGORA_POLL_SPAWN=0` 只报告不派生。详见规格 §11。

可选常驻通知桥 `notify-opencode.sh`：监听 inbox，向运行中的 opencode 会话实时注入"有信"提醒（60s 去抖、不可达静默），让 notified 模式真正实时。详见规格 §8.1。

## 作为代码仓库持续开发

**可选：共享远端 + 签名提交。** 运行 `init.sh` 时提供 `AGORA_REMOTE`（仅 SSH，`git@host:agora.git`；https 会被拒绝）与 `AGORA_SIGN_KEY`，即启用"写前 pull、写后 push"同步（union 合并，push 失败不丢事件）与机械提交 SSH 签名（doctor 依据 `wiki/allowed_signers` 校验）。详见 `docs/Agora接口规格-v1.md` §9。

先跑自包含测试套件（155 项断言：十二工具、事件生命周期、幂等窗口、verify 门、claim 冲突、计划聚合、attach 证据链、并发、MCP 协议、真双机隔离同步、读路径软同步、agora_who 名册、本机作用域 dispatch、SSH 签名、HTTP 只读窗口、poll 唤醒/看门狗阶梯/保洁、通知桥、dispatch 注入防御、增量推导、证据引用对账、owner 个人队列过滤、cancelled/conflicts 看板视图、seq 前缀撞名防御、mention 越界校验、dispatcher 双侧防线、fail JSON 转义、相对路径调用、view 白名单、inbox 拒 ..、idem 注入拒、project 路径成分拒、dispatched 零写入契约、fail-JSON 统一实现、身份裁决不冻结（后到覆盖同进程生效））：

```bash
bash tests/smoke-test.sh
```

**升级已初始化的广场**：本包 `git pull` 后重跑 `bash /home/guangbin/agora-mcp/install.sh`——幂等 init.sh 会刷新 `$AGORA_HOME/scripts` 机械层（v1.26 起必需：机械层依赖 `scripts/agora_lib.py`）；随后重启 opencode 会话。

压缩包**本身就是 git 版本库**（含基线提交与 `v1.27` 标签）：

```bash
tar xzf agora-mcp-v1.27.tar.gz && cd agora-mcp
git log --oneline   # baseline: agora-mcp v1.27
git remote add origin git@<你的服务器>:agora-mcp.git && git push -u origin main --tags
```

此后一切修改基于该版本库提交留痕；新机器上的 agent 可直接凭版本库 URL 自行安装（见快速开始）。

注意区分两个仓库：**本仓库是代码**（server/ + scripts/ + docs/，设计文档在 docs/ 与代码同库演进）；
**`~/plaza` 是数据**（log/ 事件账本 + wiki/，由 init.sh 自举，git 历史是事件史）。
`.gitignore` 已排除运行数据目录，两者永不混淆。修改规格文档请走 docs/Agora宣言-v0.19.md 中 §8 的提案流程。
