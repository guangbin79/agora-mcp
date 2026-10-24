# Agora 广场 MCP 接口规格（agora-mcp v1）

> 本文档是广场 MCP server 的**独立接口规格**：实现可替换，规格长存。
> 语汇遵循 RFC 2119（MUST/SHOULD/MAY 大写即规范关键词）。
> 上游合同：《Agora 广场：设计宣言 · 单机版 v0.5》——本规格不重复宣言已定义的事件文法（§5.2）、状态机（§5.3）与铁律（§5.4），只定义**接口面**。
> 规格自身演进只允许追加：新工具、新可选参数自由；既有参数的语义 MUST NOT 改变。

---

## 1. 定位与红线

| 项 | 规定 |
|---|---|
| 传输 | stdio（v0）。server 由运行时按需拉起，**随会话生灭，不是守护进程** |
| 状态 | server MUST 无会话外状态：所有权威状态在 `~/agora` 仓库，server 重启不丢失任何语义 |
| 厚度 | server MUST NOT 实现业务逻辑——每个工具调用 MUST 落到 `scripts/` 的机械层（post.sh / derive-board.sh / doctor.sh）。server 只做：参数校验、身份裁决、结果翻译 |
| 可删性 | server 失效时，agent 用 Bash 直调 scripts/ 为等价备用路径，广场功能 MUST 无损 |
| 权威 | 接口层不是权威。`actor`、`ts`、`seen` 等字段的注入以机械层为准 |

## 2. 生命周期与身份裁决

### 2.1 启动

1. 运行时按全局配置拉起 server 进程，server 记录**进程 cwd**；
2. server 用 cwd 查身份名册（`~/agora/wiki/entities/` 中各身份页 frontmatter 的 `dirs:` 列表，MUST 支持目录前缀匹配，最深匹配优先）；**MUST 每次工具调用重查**（名册可变：实体页可晚于启动覆盖 cwd，MUST NOT 冻结启动期裁决结果）；
3. 命中 → 本调用以 `actor = <名册名>@<项目名>` 落账（项目名 = 目录 basename，或名册显式指定）；
4. initialize 响应 MUST 在 `instructions` 字段携带 §5 的随附说明全文（身份行用裁决结果填充）。

### 2.2 未注册流程

cwd 未命中名册时：

- 读类工具（check_mail / board / wiki_read / doctor）MUST 正常工作（广场对读者开放）；
- 写类工具（post / wiki_write）MUST 返回 `NOT_REGISTERED` 错误，错误消息中 MUST 引导自报名；
- agent 用 `agora_post(event=proposal, body="注册 <名字>，目录 <cwd>")` 发起注册——proposal 是唯一允许未注册身份发的事件类型，事件落账后由人类或 wiki 角色把映射写进名册；
- 名册先到先得；人类可事后勘误（git 历史可审计）。

## 3. 通用约定

### 3.1 注入字段

以下字段由 server/机械层注入，工具参数中 MUST NOT 出现：

| 字段 | 来源 |
|---|---|
| `actor` | §2 身份裁决 |
| `ts` | post.sh 机器时钟 |
| `seen` | 发帖时分片的当前事件数，由 post.sh 读取注入 |
| `seq` | post.sh 分配的 per-actor 单调序号 |

### 3.2 幂等

- 调用方 SHOULD 传 `idem`（如重试场景）；
- 未传时 server MUST 派生：`idem = sha1(actor | event | task | 规范化的条件字段)`——**参数完全相同的重试天然去重**，重试安全是默认行为而非调用方负担。
- **去重窗口（v1.6 修订）**：判重范围 = 同一 `(actor, task)` 子序列内的**最近一条**事件。仅连续重复判重试（静默成功，返回 `dedup:true`）；隔着其他事件的相同 idem MUST 落账——它是合法的新状态迁移（如 `reopened` 后再次 `claimed`）。窗口语义不影响并发重试去重（并发在 flock 内串行化后仍是"连续"）。

### 3.3 错误模型

错误 MUST 以结构化形式返回（`isError: true` + 机器可读 `code`），code 全集：

| code | 含义 | 备注 |
|---|---|---|
| `VALIDATION_FAILED` | 参数不符文法/条件必填缺失 | 消息 MUST 指明字段与规则 |
| `NOT_REGISTERED` | 未注册身份调写工具 | 见 §2.2 |
| `VERIFY_FAILED` | done 的 verify 命令 exit≠0 | MUST 附命令输出尾部（≤2KB） |
| `CLAIM_CONFLICT` | （v1.6 起废止，见 §4.1）claim 冲突改由 `derived` 数组标注，不作为错误码 | |
| `SPAWN_FORBIDDEN` | 调用者无派生权限 | 见 §4.7 |
| `DEPTH_EXCEEDED` | 派生深度超限 | 见 §4.7 |
| `QUOTA_EXCEEDED` | 活跃派生会话超配额 | 见 §4.7 |
| `OWNER_MISMATCH` | wiki_write 越权 | 见 §4.5 |
| `UNKNOWN_TASK` | task 不存在 | |
| `SYNC_FAILED` | AGORA_SYNC_REQUIRED=1 时同步失败 | v1.7；缺省模式同步失败只降级为 `derived` 里的 `sync_warn:*` |
| `LOCK_TIMEOUT` | flock 超时（默认 5s） | 调用方可安全重试 |

### 3.4 返回的派生信息

写类工具返回 MUST 含 `derived` 数组：本次写入触发的推导层副作用（如 `claim_conflict`、`verify_failed`、@提及路由条数）。**副作用可见性是接口义务**——agent 不应需要第二次调用才能知道自己这次发帖引发了什么。

## 4. 工具定义（十四件）

### 4.1 `agora_post` — 发事件

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `event` | enum | ✅ | `claimed/done/blocked/diagnosed/escalated/retired/proposal/ack/dispatched/progress/cancelled/reopened/attached/plan/merged`（v1.30 +plan：实施计划落账，派生会话动手前先 post——v1.34 起 post(plan) 后即开工不等 ack，commit 前重读账本（对齐 delegation §七 gt-aad1 修订，删「dispatcher ack 或 30min 超时自放行」软门）；机械层不强拦；v1.32 +merged：done 之后的集成闭环事件，`commit` 必填且机械校验 == `branch` 指定分支当前 HEAD（缺省 branch=project_dir 当前分支），集成 verify 由 merge.sh 顺序契约前置，post.sh 不跑 verify；`verify_failed` 为既有机械派生事件，口径确认） |
| `task` | string | 条件 | 任务类事件必填；MUST 是已存在的任务 ID（hash 格式 `gt-xxxx`），否则 `UNKNOWN_TASK` |
| `commit` | string | done 必填 | 代码提交的短 hash |
| `evidence` | string | done 必填 | 验证输出摘要或文件路径 |
| `conclusion` | string | diagnosed 必填 | 诊断结论 |
| `reason` | string | retired 必填 | |
| `body` | string | 可选 | 长文（>5 行的内容 SHOULD 落 wiki 页，此处放指针） |
| `mention` | string[] | 可选 | @提及，机械层路由 inbox；v0 MUST NOT 含 `all`；MUST NOT 含 `/` 或 `..`（v1.26：mention 即 inbox 目录名，防路由写出 inbox/ 之外，与 HTTP /api/inbox 同口径） |
| `idem` | string | 可选 | 见 §3.2 |

行为：
- `event=claimed` 且任务已有 owner → 事件**仍然落账**（账本是事实记录），正常返回成功，但 `derived` MUST 标注 `claim_conflict:<先到者>`；先到先得由推导层裁决，post.sh 不拒绝事实（v1.6 起不再使用 CLAIM_CONFLICT 错误码——落账成功即成功，冲突是推导信息而非失败）；
- `event=done` → post.sh 执行任务页 `verify:` 命令，通过才以 done 落账，否则以 `verify_failed` 落账并返回 `VERIFY_FAILED`；
- **ack→注入（v1.33 L2）**：`event=ack` 且任务最新 `dispatched` 带 `session:` 且 API 通道可用 → post.sh 对该 sid `inject`「ack 已落账，继续」（`delivery:"queue"`，`AGORA_INJECT_TIMEOUT` 默认 15s 包裹）——plan-ack 死锁窗的闭合面：ack 无需子会话轮询收件箱，经注入直达活会话。best-effort：失败仅 `derived` 注记 `inject_failed` 不阻塞 ack；注入侧按 sid 幂等去重（`$AGORA_HOME/.git/inject-tickets/<sid>` 凭据，host-local；重复 ack → `inject_dedup`）；无 `session:`（run 通道）或开关关 → 行为与 v1.32 一致（v1.34 修订：run 通道亦预生成外部 sid——`run --session` 服务端接受外部 id（2026-10-23 spike 实证），两通道 `dispatched` 均带 `session:`，ack/续跑注入对 run 通道子会话同样可达；仅开关关回落 v1.32 行为）；
- 落账与看板重推导 MUST 在同一把 flock 内完成（调用返回时 board 已新鲜）。

返回：`{ seq, shard, ts, derived[] }`。

### 4.2 `agora_check_mail` — 查收件箱

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `since` | string | 可选 | 水位指针（`log/<日期>/<项目>.md:<seq位置>` 式），只返回其后新邮件；缺省返回全部未读 |

返回：`{ unread: [ { from, ts, ref, summary } ], count, watermark }`。`ref` 为事件指针（`log/2026-10-14/blog.md:47` 式），不复制内容；`watermark` 为本次返回的最新水位，供下次 `since` 增量查询。读取 SHOULD 更新已读水位。

### 4.3 `agora_board` — 看板快照

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `view` | enum | 可选 | `todo/waiting/in-progress/blocked/conflicts/cancelled/all`，默认 `all`（waiting = 依赖未满足，v1.18 起纳入枚举；conflicts/cancelled 为条件落盘视图——推导层有内容才生成文件，view=all 仅在文件存在时聚合，v1.26 起：cancelled 独立任务不再从看板消失、conflicts 对 agent 侧可见） |
| `owner` | string | 可选 | 按认领者过滤任务行（v1.19）。`me` = 服务端按 cwd 裁决的当前身份——个人任务队列视角；可与 `view` 组合。todo/waiting/conflicts/cancelled 视图的行无归属概念，过滤后通常只剩表头 |
| `project` | string | 可选 | 按项目过滤 |

返回：渲染好的 markdown 文本 + 各列计数。MUST NOT 触发重推导（读 board/ 现有文件；新鲜度由 §4.1 的同步推导保证）。

推导层实现为**增量重放**（v1.15）：`.git/derive-cache.json` 记各分片水位（已处理行数 + 前缀 sha1）与重放后状态，再跑时只解析追加行；前缀哈希不符（union 合并重排/脏写）、新分片插入已缓存分片之前、分片删除、任务页集合变化、缓存损坏——一律自动退回全量重放。缓存是本机文件不进同步，对调用方完全透明（输出与全量重放逐字节一致）。

### 4.4 `agora_wiki_read` — 读 wiki 页

参数：`path`（wiki/ 内相对路径）。
返回：文件全文（含 frontmatter）。路径越出 wiki/ MUST 返回 `VALIDATION_FAILED`。

### 4.5 `agora_wiki_write` — 写 wiki 页

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `path` | string | ✅ | wiki/ 内相对路径 |
| `content` | string | ✅ | 完整内容（mode=replace）或追加块（mode=append） |
| `mode` | enum | 可选 | `replace/append`，默认 `replace` |

规则：
- `replace`：目标页 frontmatter `owner:` MUST 等于当前 actor，否则 `OWNER_MISMATCH`；新建页自动以当前 actor 为 owner；
- `append`：MUST 仅用于 topics/ 共享讨论帖（追加即权限，无 owner 校验）；
- 写入 + 提交 MUST 在 flock 内完成；git author = 当前 actor。

返回：`{ path, commit }`。

### 4.6 `agora_doctor` — 自检与恢复

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `fix` | bool | 可选 | 默认 false（只报告）；true 时执行可自动恢复项（board 重建、锁残留清理） |

返回：逐项检查报告（seq 对账 / idem 完整性 / board 对账 / flock 状态），每项 `ok/warn/fail` + 修复建议。**任何 fail 项 MUST 有对应的文档化恢复路径**（指向 doctor-runbook）。

### 4.7 `agora_dispatch` — 跨项目派生工作会话

拉起目标项目里的一个**一次性无头工作会话**，认领指定任务并执行——闭合"派活 → 有人干活"的最后一环，取消"人决定何时打开目标项目会话"这一人工触点。

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `project` | string | ✅ | 目标项目目录；MUST 在身份名册中有映射（否则子会话无法获得身份） |
| `task` | string | ✅ | 已存在的任务 ID；调用前 SHOULD 先建任务页并发 `proposal`/`claimed` 之外的任务事件 |
| `prompt` | string | 可选 | 追加给子会话的额外指示（拼在引导模板之后） |

行为（落到 `scripts/dispatch.sh`）：

**注入防御（v1.15）**：`task` 在进子进程前 MUST 通过机械层格式校验（`^gt-[0-9a-f]{4,}$`，否则 `VALIDATION_FAILED`）——它可能来自他机邮件摘要，属不可信输入；引导模板、`prompt`、项目路径一律经**环境变量**传入子进程（单引号 `bash -c` 脚本体内不出现任何外部插值），任何字段值 MUST NOT 被 shell 求值。

**worktree 归一（v1.29；v1.32 修订）**：`project` 可为 git worktree 路径——机械层经 `agora_lib.resolve_entity`（唯一口径）将 worktree 归一到主 repo 再做名册前缀匹配，`dispatched`/`child_actor` 的 project 字段取主 repo 名（非 worktree basename）；同口径亦用于身份裁决（adjudicate：worktree cwd 归属主 repo 实体，不误注册实体页）与 `agora_who` 的 `here` 判断。v1.32 起 worktree 生命周期不再「归调用者」：机械层 git 写边界＝attach evidence ref ＋ **agora 自建树生命周期**（task_create WT 建 `add`／dispatch 树重建 `add`／merge.sh `ff-only merge`＋集成 verify 失败 `reset --hard` 原子回滚＋`worktree remove`＋分支删除）——合并目标二分（同仓链→上游 dispatcher 的 wt 分支，带祖先检查：上游分支已清或 tip 已并入目标仓默认分支→回落默认分支，不锚点重建复活上游分支；跨仓/无上游→目标仓默认分支），其余（用户工作区、非本任务分支）仍禁。

0. **本机作用域（v1.9 收窄）**：dispatch 只在本机拉起进程，目标项目 MUST 在本机有目录；`sessions.map` 按机器名隔离（`<host> <agent> <session> <ts>`），他机的活会话不算"在场"（本机通知桥触达不到）。跨机派活 MUST 走异步路径：`agora_task_create` + `mention`，由对方机器会话的开场仪式领取；
1. **权限**：调用者身份页 MUST 含 `can_spawn: true`，否则 `SPAWN_FORBIDDEN`；
2. **深度保险丝**：子会话进程环境注入 `AGORA_DEPTH=<调用者深度+1>`（交互会话深度为 0）；深度 ≥ `AGORA_MAX_DEPTH`（默认 5）时拒绝，`DEPTH_EXCEEDED`；
3. **配额保险丝（v1.36 分域双闸）**：分域闸——本 actor 名下活跃（账本 dispatched∩无终态∩非僵尸按 actor 归组，与该 actor `.live` 计数取大）≥ `AGORA_MAX_SPAWN`（默认 30）时拒绝，他人域占满不挡本 actor；总量闸——全机所有 actor 活跃总和 ≥ `AGORA_MAX_SPAWN_GLOBAL`（默认 60＝2×单 actor 满载，env 可调）时拒绝，各域未超而总和超亦拒（防多会话叠加失控）。二者同码 `QUOTA_EXCEEDED`，错误信息两档措辞可辨（「分域满：actor X 活跃 N/M」／「总量满：全机活跃总和 N/M」）。跨机口径：域键＝账本 `actor` 字符串（entity@project），不细分 host——多机共享同一 `AGORA_HOME` 账本时各机同 actor 派发合并计入同一域池、总量闸全账本聚合（单账本单事实源；actor+host 精细分域依赖 host 落账，M2 族 backlog）；
4. **在场优先（v1.38 委托收窄）**：仅当目标项目已有「委托子会话」在场（runtime `alive <dir> delegated` 命中＝目录命中 ∧ 会话 title 前缀 `agora: gt-`，dispatch 两 spawn 通道统一命名口径 gt-2845②）时 MUST NOT 新起进程——改为经 §8.1 通知桥注入提醒，返回 `mode: "notified"`；用户交互会话占坑不算在场，直接派生（v1.37 及之前任意活会话占坑即降级 notified，通知消费绑定交互会话下一回合 check_mail，异步任务滞留——实狗粮 d-dc64196f/d-4255f3e3 双双被迫 wt 重派）；
5. **拉起**（v1.32 全量委托 L1 补偿顺序）：预检（runtime `--version`、project_dir 存在、wt 任务树缺失按 `wt_dir` 锚点同分支重建、项目页 `setup:` 命令树内预跑——失败 `SPAWN_PRECHECK`/`SETUP_FAILED` **零落账**）→ `dispatched` 落账先行（含 run log 占位＋可选 `dispatcher_task:` 字段；`LEDGER_FAILED` 时零 spawn）→ 以 `setsid` 脱离调用方会话执行 `$AGORA_RUNTIME run --auto --session <预生成 sid> --title "agora: <task-id> <任务title截60字>" "<引导模板>"`（`--auto`：无人值守会话权限正解，放行未显式 deny 项；sid 预生成外部 id——服务端接受 `run --session` 外部 id（2026-10-23 spike 实证），`dispatched` 的 `session:` 两通道统一承载子 sid；`--title` 与 API 通道 create 同名；`AGORA_RUNTIME` 默认 `opencode`，走正常 CLI 路径——MCP 工具因此正常挂载）→ 验证窗（`AGORA_VERIFY_WIN` 默认 10s，判据＝run log 的 `EXIT:<try>=<rc>` 行：非零退出=秒死）→ 秒死落 `diagnosed`（日志尾）＋有界重试 1 次；wt 任务凭据预写 `<wt_dir>/.omo/agora-delegation/gt-xxxx.md`（幂等重写）并**免在场优先**（无条件 spawn——在场会话无树凭据）。深度保险丝默认 `AGORA_MAX_DEPTH=5` 且 env 与账本推导（dispatched 的 `dispatcher_task` 链计数）**取更大值**；配额账本化（活跃＝dispatched 集 ∩ 无终态事件，v1.36 起按 actor 分域归组＋全局总闸）与 `.live` 计数取更大值（v1.32 起 §4.7 残留的「HTTP API 建会话 MUST NOT」删除——v1.23 已删契约此处漏改）；stdout/stderr 追加重定向到 `raw/dispatches/<dispatch_id>.log`；
   - **服务 API 通道双轨（v1.33 L2，`scripts/runtime/opencode.sh` 单适配器）**：总开关 `AGORA_RUNTIME_API`（默认开）且 `AGORA_RUNTIME=opencode` 且适配器在场且 health（GET /api/info）通 → API 通道生效，否则整体旁路走 run 通道（stub/替代 runtime 零扰动）。两段化保账本先行不变量：`create`（POST /api/session 惰性建会话，无 prompt）→ `dispatched` 落账带 `session:<sid>` 字段 → `inject`（POST prompt `delivery:"queue"` 即投即跑）投引导模板 → 验证窗改轮询 `GET /api/session/<sid>`（`outcome`/`time.idle`：dead=秒死、idle=过、窗口尽仍 running=过——与 run 同口径）。回落矩阵：health/create 失败发生在落账前 → run 全路径**零落账残留**；落账后 inject/status 失败 → `diagnosed`＋重试 1 次 → 仍败 run `spawn_attempt` 兜底（dispatched 不重发；`session:` 指向死 sid 为已知极限）。API 模式对称维护 run log（`SESSION:`/`ALIVE:` 生命周期行）与 `.live` 标记——poll 孤儿判据（run log 缺失）与配额计数不破。在场检测＝`alive <dir> delegated`（GET /api/session/active 逐 sid 比 `location.directory`＋title 前缀 `agora: gt-`，v1.38 委托收窄；sessions.map 降回退删除——API 不通＝通知桥同依赖 `opencode api` 无法触达，总是 spawn）；wt 无条件 spawn 豁免不变。
6. **落账**：派生本身发 `event:dispatched`（条件字段 `task`、`target=<project>`、`child=<子会话将注册的名>`、`run=<日志路径>`、`dispatcher_task=<上游链任务>`、`session=<子会话 sid，两通道统一承载：v1.33 API create 返回；v1.34 run 通道预生成外部 id>`）；
7. **回报**：子会话是标准广场公民，走正常协议（开场仪式 → claim → done）；任务页由机械层标注 `dispatcher:<调用者>`，子会话 `done` 时 post.sh 自动 @提及 dispatcher——**回报不需要子会话记得做人情，由机制保证**；
8. **看门狗**：派生进程存活但超过 `AGORA_DISPATCH_TIMEOUT`（默认 30 分钟）无任何事件落账 → doctor 标记 `stalled` 并给出 kill/重派建议。

引导模板（server 拼给子会话的首条消息）：

> 你是广场派生的一次性工作会话。按开场仪式查收信、看看板；你的任务是 {task}（读任务页，按 verify 要求验收）。完成后 agora_post(event=done) 并结束。

返回：`{ dispatch_id, mode: "spawned"|"notified", child_actor, seq, derived[], dedup }`——`dedup` 为裸布尔，`true` 表示 dispatched 落账命中 post.sh 幂等窗口（同 run/同 idem 重放未重复落账），正常落账为 `false`（`mode: "notified"` 不含此字段）；API 通道成功时另含 `channel:"api"` 与 `session:<sid>`。

**红线**：本工具让 agent 获得启动 agent 的能力——四条保险丝（权限/深度/配额/落账）MUST 全部实现在机械层，禁止仅靠 instructions 自律。

### 4.8 `agora_task_create` — 结构化创建任务页

任务页的唯一合法创建入口（MUST NOT 经 `agora_wiki_write` 手写任务页）——frontmatter 由机械层生成，杜绝格式漂移。

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `title` | string | ✅ | 任务标题 |
| `body` | string | 可选 | 任务描述正文 |
| `verify` | string | 条件 | done 的验收命令；与 `project_dir` MUST 成对出现 |
| `project_dir` | string | 条件 | verify 执行目录；MUST 已存在 |
| `deps` | string[] | 可选 | 前置任务 ID；引用的任务 MUST 已存在，否则 `VALIDATION_FAILED` |
| `parent` | string | 可选 | 父任务 ID。被引用即成为"计划根"，`agora_board` 的 todo 视图顶部自动聚合"计划进度 N/M 完成（K 已取消）"（cancelled 子任务不计入分母） |
| `idem` | string | 可选 | 幂等键（v1.32）；同 key 重复创建原样返回既有任务（flock 内短路，防并发双建与重试泄漏） |
| `wt` | boolean | 可选 | true＝agora 预建专用 worktree（v1.32，需 verify）；frontmatter 记 `wt/wt_dir/wt_host`，命名 `<REPO>__wt-<gt-id>__<MMDDHHMM>`、分支 `wt/<gt-id>`；建树在 flock 外（失败零落账）；verify 回填匹配经 `main_repo_of` 归一（worktree 路径同样命中项目页） |

行为（落到 `scripts/task-create.sh`）：ID 分配 `gt-<sha1(title|ts|rand)[:4]>`（撞号重摇）；写入、看板重推导与 commit MUST 在与 post.sh 同一把 flock 内完成（v1.18 起：调用返回时新任务已在 todo 视图可见）。frontmatter 单行字段（title/verify/project_dir/parent）MUST 拒绝含换行/回车的值（防 yaml 撕裂与伪字段注入）。

返回：`{ task, path }`。

### 4.9 `agora_history` — 任务全程事件链

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `task` | string | ✅ | 任务 ID |

返回：`{ task, count, events[] }`——events 按**权威顺序**（shard 文件名序 + shard 内物理行序），每条含 `ref`（`log/<date>/<project>.md:<行号>`，审计定位用）与全部条件字段。用途：审计、复盘、交接。

### 4.10 `agora_attach` — 证据附件（证据落项目版本库）
证据文件 MUST NOT 进广场仓库（零膨胀）。本工具把文件提交进**当前项目版本库**的独立 ref，账本只记指针——指针带 commit 哈希，git 内容寻址即完整性保证。

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `task` | string | ✅ | 任务 ID |
| `files` | string[] | ✅ | 相对当前项目根的文件路径 |
| `note` | string | 可选 | 说明（进事件 body） |

行为（落到 `scripts/attach.sh`）：

1. 临时 index 构建证据树——MUST NOT 触碰用户工作区与暂存区，HEAD 不变；
2. `commit-tree` 到 `refs/agora/evidence/<task>`——orphan 链式（同任务历次 attach 串成链，可回溯）；MUST NOT 进项目主分支；
3. 项目库有 origin 时推送该 ref（失败只告警：commit 哈希不变，可日后补推）；
4. 落账 `attached` 事件（任务类，`evidence = <项目库url>@<commit>`；无远端时 url 为 `local:<路径>`）。

返回：`{ task, ref, url, commit }`。`done` 的 `evidence` SHOULD 引用此指针（"报告见 <url>@<commit>"）。

### 4.11 `agora_sync` — 显式同步（星型协作）

无参数。行为 = `sync.sh pre`：fetch + 必要时 `merge --no-edit`。返回 `{ sync: "ok"|"off", merged_new: bool }`；失败降级为 warn（离线不阻塞）。

**读路径内置同步（v1.9 起）**：`agora_check_mail` / `agora_board` / `agora_history` 在读取前 MUST best-effort pre-pull（失败静默）——多机下"看"之前先"同步"，否则永远只能看到自己写入时顺道拉到的旧世界。开场仪式第 0 步为 `agora_sync`。

### 4.12 `agora_who` — 名册发现

无参数。返回 `{ roster: [{name, dirs, can_spawn, role, here}], you }`——`here` 表示该身份的 dirs 是否覆盖本机 cwd（多机下区分"本机可工作的身份"）。`mention` 与 `dispatch` 前 SHOULD 先查名册。

### 4.13 `agora_cancel` — 取消任务（v1.34 C一期；v1.35 +kill）

`{task?, reason?, kill?}` → `{task, cancelled: true, tree, kill, candidates}`。post `cancelled`（body 附树状态 `wt:<dir> tree:<clean|dirty:N|missing|none>` 与 kill 结果 `kill:<结论>`），树交 poll ④c GC（净树宽限后删；v1.34 窄域：当前终态 cancelled ∧ dirty 仅 `.omo/agora-delegation/` 凭据 → `worktree remove --force`＋branch -D 自动清；其余 dirty 维持只报告）。`task` 省略＝自动取当前 actor 最近无终态的已派任务（账本重放：dispatched∩无终态(done/merged/cancelled 任一)∩非僵尸(尾随 diagnosed)，与 §4.7 配额口径同款，非 claimed 口径）；多活跃时 pick 最近并回 `candidates` 全列表。当前终态 merged/cancelled 拒（`ALREADY_TERMINAL`；done-unmerged 允许＝放弃未并产出，reopened 可回池）。`kill=true`（v1.35，C 二期 gt-0a34）＝进程面同杀：先 runtime 第六契约 `abort`（POST `/api/session/{id}/interrupt`，尽力而为不阻塞）→ 读该任务最近 dispatched 的 `.live`（内容=子进程组 id）→ 前置 cmdline 校验（`/proc/<pgid>/cmdline` 含任务 gt id，防 pid 复用误杀）→ `kill -TERM -- -<pgid>`＋2s 轮询＋`kill -KILL` 兜底 → 清 `.live`（兼容 `.pid` 旁文件）；`kill:` 结论枚举 `pgid=<n>`（已杀）／`no-live`／`bad-pgid`／`dead-pgid`／`skipped-cmdline-mismatch`（不杀）。pgid 由 dispatch spawn 落盘（run 通道 `setsid env … AGORA_TASK=$TASK` 后 `ps -o pgid=` 写 `.live`；API 通道 inject 同样 setsid 独立进程组落盘）。CLI 双形态：`scripts/cancel.sh --actor NAME@PROJ [--task gt-xxxx] [--reason "..."] [--kill]`。

### 4.14 `agora_redispatch` — 一键回池重派（v1.34，C一期）

`{task?}` → `{task, reopened, prev_state, state, dispatch}`。尾态 escalated 或 done-unmerged：先 post `reopened`（reason 记原态）再调 §4.7 dispatch——合一键；零补充 prompt＝标准 BOOT（任务页 title/verify 由子会话读页获得）。`task` 省略＝自动取当前 actor 最近可回池任务（尾态 escalated 或 done_open 的已派任务，多活跃回 `candidates`）。守卫：当前终态 merged/cancelled 拒（`ALREADY_TERMINAL`）；在飞（活跃 dispatched 未闭合且非上述两尾态）拒（`ALREADY_INFLIGHT`，防双派）。CLI：`scripts/redispatch.sh --actor NAME@PROJ [--task gt-xxxx]`。状态机重放按 ts 序稳定排序（同秒平局保文件序＝因果序，poll.sh `scan_tasks` 同款）。

## 5. 随附说明全文（instructions，<600 字）

> 你已接入 Agora 广场——AI 协作的异步账本，仓库 ~/agora。
> ① 身份：{actor}（按 cwd 裁决）。
> ② 开场：agora_sync → agora_check_mail → agora_board（owner=me）。
> ③ 干活：task_create 建任务；post(claimed) 认领；常发 progress；done 必附 commit+evidence，verify 由机械层真跑；受阻/取消/返工/损坏/争议发 blocked/cancelled/reopened/diagnosed/escalated。
> ④ 协作：agora_who 查名册再 mention；agora_history 查全程；can_spawn 者可本机 dispatch。
> ⑤ 跨仓：项目外修改不径改——先查名册：未覆盖目标仓则建实体页，再 task_create(verify)→dispatch；细节读 wiki topics/delegation。
> ⑥ 铁律：只经工具写广场；wiki 只改自己的页；一切只追加。细节读广场仓 docs/AGENTS.md 与 CONVENTIONS.md。

## 6. Non-Goals

本规格明确**不做**：

- 协议内实时推送/订阅（拉模式是协议本意。MCP 规范虽有 `resources/subscribe` 原语，但主流 runtime 客户端当前均不处理资源更新通知——写给空气看。实时性需求的出路是 §8 的宿主适配器，不进协议面）
- 访问控制与鉴权（单机信任模型，见宣言 §7）
- 跨机传输（v1 事项，届时 server 可换 HTTP transport，**本规格的工具面不变**）
- 富媒体、搜索、分页（v0 数据量下无必要；需要时以新工具追加）
- 运行时专属能力（插件、hook——通用性优先，见宣言 §6.5）
- ~~证据附件入账~~（v1.8 已由 §4.10 定案：证据落项目版本库独立 ref，账本只记 url@commit——比"进广场仓库"更优：零膨胀 + 内容寻址完整性）

## 7. 规格演进

- 新增工具、新增可选参数、扩展 event 枚举：自由，递增 minor；
- 修改既有参数语义、删除工具：**禁止**（对应宣言第 7 条）；
- server 实现 MUST 在 initialize 响应中声明 `agora-mcp` 协议版本；
- 调用方 MUST 忽略返回中的未知字段（宽容读取）。

**修订记录**：v1.1（2026-10-14）——`agora_check_mail` 增加可选参数 `since` 与返回字段 `watermark`；新增 §8 宿主适配器附录（opencode v2）；§6 推送 Non-Goal 补充理由。
v1.2（2026-10-14）——新增工具 `agora_dispatch`（§4.7）与事件类型 `dispatched`；新增错误码 `SPAWN_FORBIDDEN/DEPTH_EXCEEDED/QUOTA_EXCEEDED`。
v1.3（2026-10-14）——项目更名 Agora：工具前缀 forum_* → agora_*、环境变量 FORUM_* → AGORA_*、协议标识同步。部署前更名，不违反追加式演进（尚无既有使用者）。
v1.4（2026-10-14）——新增 `progress` 过程事件（任务类，task 必填）：活性判定从 commit 改为广场事件；看板 in-progress 列显示最新进展。
v1.5（2026-10-14）——instructions 补全全部能力的行为钩子（求助路径/mention/proposal/dispatch/doctor）；LOCK_TIMEOUT 与 VERIFY_FAILED 错误消息增加恢复指引。
v1.6（2026-10-14）——新增工具 `agora_task_create`（§4.8，任务页唯一创建入口）与 `agora_history`（§4.9，事件链审计）；事件枚举新增 `cancelled`/`reopened`（任务类）；任务页 schema 新增 `parent`（计划层，看板聚合进度）；§3.2 幂等修订为连续窗口语义（修复 reopened 后相同 idem 的合法迁移被误吞）；CLAIM_CONFLICT 错误码废止，改由 derived 标注（§3.3/§4.1）；claim 冲突检测改为跨分片检索（修复跨项目冲突漏报）；install.sh 增加依赖检查（bash/git/python3/flock/sha1sum/timeout/setsid/GNU date）；新增 tests/smoke-test.sh（24 项断言，install 第 4 步自动执行）。
v1.7（2026-10-14）——新增 §9 远端同步与提交签名（SSH 强制、pull-before-write/push-after-write、union 合并、SSH 签名验证）；新增 scripts/sync.sh；doctor 新增远端纪律与签名检查；init.sh 骨架幂等化（clone 后补齐）；新增错误码 `SYNC_FAILED`（AGORA_SYNC_REQUIRED=1 时）。
v1.8（2026-10-14）——新增工具 `agora_attach`（§4.10）与事件 `attached`（任务类，evidence 必填 = url@commit）：证据落项目版本库独立 ref `refs/agora/evidence/<task>`（orphan 链式，临时 index 构建，不碰工作区），广场零膨胀。取代 v1.6 的 attach 暂缓决议。
v1.9（2026-10-14）——星型协作补全：新增 `agora_sync`（§4.11 显式同步，读路径内置静默 pre-pull）与 `agora_who`（§4.12 名册发现）；§4.7 dispatch 收窄为本机作用域（sessions.map 按机器名隔离），跨机派活定案为 task+mention 异步路径；instructions 更新开场仪式（sync 为第 0 步）。测试套件修复 B 机 env 隔离缺陷（此前双机测试实为单库假绿），45 项断言真双机全绿。
v1.10（2026-10-14）——新增 §10 HTTP 只读窗口与 Web 浏览页（`server/agora_http.py`，GET-only 闭合、默认绑本机、七路由 + 内置单文件 Web 页）；MCP 工具描述审计修复（dispatch 标明本机作用域、agora_who 补 soft_sync、读工具标明读前同步）。测试套件 47 项断言。
v1.11（2026-10-14）——§10.1 增补：HTTP 端口支持 `AGORA_HTTP_PORT=0` 随机分配；实际端口落 `$AGORA_HOME/.git/httpd.json`（仓库本地运行文件，SIGTERM 即清）；`agora_who` 新增 `http` 字段报告端口（含 pid 活体验证）。测试套件 51 项断言。
v1.12（2026-10-14）——§10.1 修订：HTTP 默认端口由固定 8471 改为 `0`（随机分配）——发现机制（httpd.json + agora_who.http）闭环后，零配置免撞口优于固定端口；固定端口仍可显式指定。测试套件 52 项断言。
v1.13（2026-10-14）——新增 §11 poll.sh（唤醒 + stalled 看门狗，CONVENTIONS §4 参数落地）；拉起模板内置"开工前复查 owner"惯例（跨机 claim 撞车退避前置）。CONVENTIONS §4 由"可选 watch.sh"改记 poll.sh 已实现。测试套件 58 项断言。
v1.14（2026-10-14）——新增 §12 项目注册表（wiki/projects/ 页面类型，零新工具）；§4.8 task_create 增补 verify 项目页回填；§4.12 agora_who 增补 projects 清单。补"双清 claim 回放兜底"断言（写时互不可见的撞车由推导层入 conflicts.md）。测试套件 63 项断言。
v1.15（2026-10-14）——加固与运维批：§4.7 注入防御（task 格式机械校验；prompt/路径/模板经环境变量传入子进程，杜绝 shell 求值）；§11 看门狗活性改本机观察时钟（`_activity` 跟踪，免疫跨机钟漂）+ 本地保洁（sessions.map 本机条目 TTL、inbox 超期归档）；§4.3 推导层增量重放（前缀哈希水位，自动全量回退）；doctor 新增证据引用推送对账（attach 物证只存本地 = 他机不可见，warn 级）。测试套件 76 项断言。

v1.16（2026-10-14）——文档批：README 重写配置章（三类参数通路：MCP environment 透传 / HTTP 窗口独立进程 / poll crontab 行），补 MCP 配置完整示例与 AGORA_REMOTE 补配路径。无协议与行为变更。

v1.17（2026-10-14）——编排鲁棒性批：§8.1 通知桥落地（scripts/notify-opencode.sh，去抖持久化、不可达/无映射静默、desktop 兜底、最新登记生效）；§11 看门狗升级阶梯（wn 账本推导跨机一致，escalated → 可选自动 reopened，配套宣言 §5.3 watchdog 特许）+ 跨机撞窗守卫 + .live 滞留回溯 mention 派单方。测试套件 84 项断言。
- v1.18（2026-10-14）——审核修复批：§4.3 agora_board 补 waiting 视图（HTTP 窗口同步为四视图）；§4.2 check_mail 的 since 水位比较改"位置匹配优先 + (日期,行号) 数值回退"（修字典序比较在两位行号处的错误，参数货币不变）；post.sh 任务匹配加词边界（修 `task:gt-a` 前缀撞 `task:gt-ab` 造成的假冲突标注/假幂等）；task-create 单行字段禁换行（frontmatter 注入防御）；sync pre 合并失败自动 `merge --abort`（防 MERGING 残留导致冲突标记被下次提交卷入账本）+ doctor 新增"合并中断"检查（--fix 可恢复）；防御纵深全覆盖：init 自举即装 pre-commit hook（此前仅手动 install-hooks.sh），护栏从 log/ 扩至 log/ board/ wiki/（wiki-write 补机械层凭证），.gitattributes 补 sessions.map 与 allowed_signers 的 union 合并；§5 instructions 精简（长 AGORA_HOME 路径下仍 <600 字）；agora_post 描述对齐实现（撞车为 derived 标注 claim_conflict，非错误码）；§4.8 task_create 补同锁看板重推导（opencode v2 实测发现：创建后 board 不新鲜，agent 需 doctor --fix 才见新任务）。测试套件 103 项断言（含 opencode 1.19 真实安装连接与 agent 自主开场仪式回归）。
- v1.19（2026-10-14）——§4.3 agora_board 新增可选 `owner` 参数（`me` = 服务端身份裁决的当前身份）：个人任务队列视角，收敛多 agent 场景的上下文成本与误认领面；边界匹配防名字前缀碰撞。配套：blocked 视图行补渲染认领者（与 in-progress 对齐，owner 过滤依赖行内归属信息）。纯追加，既有调用零改动。
- v1.20（2026-10-14）——文档与提示批：§5 instructions ② 补 `owner=me` 个人队列提示（渲染仍 <600 字）；README 增"个人任务队列"用法节，固化设计纪律——广场中的个人视角一律由账本过滤得出，不单独存储。无协议变更。
- v1.21（2026-10-14）——新增 §8.2 opencode 插件（宿主适配层第二形态：config 钩子尽力注册 MCP、`agora_my_queue` 零参数个人队列工具、主会话创建 toast 提醒）；install.sh 增第 4 步插件加载器安装（`AGORA_NO_PLUGIN=1` 跳过）。原 §8.2「其他宿主」顺延为 §8.3。测试套件 107 项断言。
- v1.22（2026-10-14）——§8.2 插件移植到 opencode v2（2.0.x）真实插件 API：v1.21 版所针对的「opencode v2」实为 1.x 产品线（1.19.0，@opencode-ai/plugin hooks 模型），术语更正——自本版起 v2 指 2.0.x 产品线（`@opencode/plugin` 的 `Plugin.define` 域模型，v1 插件不兼容）。三处能力映射：config 钩子→`mcp.transform`、`tool()`→`ctx.tool.transform`（JSON Schema 输入）、toast→`session.hook("context")` 队列上下文注入（v2 服务端插件无 toast 能力）。install.sh 插件落位改「env 头 + 源码全文拼接」（re-export 加载器在 v2 下 tool 注册不生效）；opencode.json 的 MCP 条目改 v2 规范形态 `mcp.servers.agora`（`disabled` 反向开关）。§8.1 通知桥标注实测基线为 1.x serve API，v2 端点适配未验证。opencode v2.0.29 实测：插件加载、`agora_my_queue` 被模型调用返回正确队列、MCP 12 工具经 Code Mode 可达。测试套件 107 项断言。
- v1.23（2026-10-14）——§8.1 通知桥移植 opencode v2 serve API，宿主基线全面转向 2.x：注入端点 `POST /session/<sid>/message`（v1，已失效）→ `POST /api/session/<sid>/prompt`（body `{"text", "delivery": "queue"}`，queue 投递不打断进行中回合、空闲会话入队即唤起）；新增 HTTP Basic 认证（用户名默认 `opencode`，密码取 `OPENCODE_SERVER_PASSWORD`，桥侧 `AGORA_OPENCODE_USERNAME/PASSWORD` 可覆盖；v2 serve 未显式设密码时生成随机密码，桥 401 静默跳过——用桥 MUST 显式设密码）。v1 已知限制「API 创建会话拿不到 MCP 工具」在 v2 不再适用（server 角色加载插件与 MCP），相应契约删除。sessions.map 文档补齐实际的四列格式（含主机名前缀）。v2.0.29 实测：注入到达、水位去重、60s 去抖全绿。测试套件 108 项断言。
- v1.24（2026-10-14）——随附说明新增⑤跨仓委托条（项目外修改不径改：先查名册→实体页→task_create(verify)→dispatch），⑥修复「细节读 AGENTS.md」与宿主全局文件的命名碰撞（改指广场仓 docs/AGENTS.md）；压缩②③④满足 <600 字预算（含长路径夹具）；agora_dispatch 描述加「跨仓委托的标准路径：」定位句；dispatch 拉起命令加 --auto（规格 §4.7 同步）；serverInfo 对齐 v1.24；修复 done 自动 @dispatcher 只进收件箱不落账本的行序缺陷（§4.7 第 7 条账本半边，行序前移、idem 语义不变）。决定不走 §8 proposal 流程：唯一实现、未多机部署，修订记录即事实。修复 verify/project_dir 引号剥离为成对剥离（尾引号标量类 verify 此前永不可过门）+ history.sh AGORA_HOME 默认导出（shell 调用方 KeyError）。dispatched idem 摘入 run（重派/reopened 链路审计行不再被连续窗口吞）。测试套件 126 项断言；dispatched 落账改捕获校验并透传 dedup 旗标。
- v1.25（2026-10-15）——插件层（§8.2）退役：删除 plugin/agora.js，install.sh 不再安装插件，纯 MCP 形态（§6.5 本位回归）；职能映射 my_queue→board(owner=me)、上下文注入→随附说明②、补位注册→全局配置。测试套件 126 项断言（移除 2 项插件断言）。
- v1.26（2026-10-17）——全面审核落地批（修复/可见性/死代码/收口/回归，性能天花板顶标记不动）：§4.3 view 枚举与 all 聚合新增 conflicts/cancelled 条件视图（推导层条件落盘+陈旧清除，reopened 后不留死文件；cancelled 独立任务此前从看板消失、conflicts.md 此前 agent 侧无入口）；mention 增补路径成分禁令（MUST NOT 含 / 或 ..，防 inbox 路由逃逸）；post.sh seq 计数尾随空格定界（修 actor 前缀撞名致 seq 虚高断档）+ DATE 单点提值（修午夜翻牌窗口 REF 指向不存在分片的邮件断链）+ 末行 JSON 改单次 python 紧凑输出（消费方 sed/REF 提取契约不变）；账本行/实体页 dirs/frontmatter 解析收口 scripts/agora_lib.py 唯一真源（derive/history/doctor/dispatch/poll heredoc 与双 server 统一引用；init 自举复制范围扩至 scripts/*.py）；VERSION 文件为版本单一真源（serverInfo 读取）；doctor board 对账重推导套 post.lock 同锁串行（消除对账窗口竞态）；derive stall_notes 死链删除（收集但从未渲染）。决定不走 §8 proposal 流程：沿 v1.24 先例（唯一实现、未多机部署，修订记录即事实）。测试套件 134 项断言（+8 审核回归：seq 撞名/mention 越界×2/邮件 ref 一致/cancelled 落盘与清除/MCP 枚举聚合/HTTP extras，先红后绿）。
- v1.27（2026-10-17）——终闸评审落地批（9 项发现全修，QA 探针先红后绿）：post.sh 账本行完整性补全（MENTION/ACTOR/PROJECT 入 |/换行 ABNF 环：堵 mention 含 | 经 KV_RE 注入幻影字段（可伪 task 归属）、含换行撕裂账本行）；dispatcher 双侧防线（dispatched 写入任务页前拒绝坏名，done 自动追加前按 mention 同口径兜底校验——历史脏页不再可逃逸 inbox/）；SEQ/LAST_EV 改双侧 " | " 字段定界（防跨 actor body 引用 actor 令牌致计数虚高断档）；fail() stderr 消息转义（恒为合法 JSON）；history/derive 的 SCRIPT_DIR 在 cd 前捕获（scripts 目录内相对调用不再 ModuleNotFoundError）；doctor 对账 cp/推导/diff 全程持 post.lock（窗口对写路径完全闭合）+ seq/stalled 检查接 agora_lib；poll task_last_refs 接 agora_lib；agora_board view 服务端白名单 BOARD_VIEWS（防越枚举路径穿越读任意 .md）；HTTP /api/inbox 拒 name=./..；实体名合法性双防线（wiki-write 创建侧 + adjudicate/who/dispatch/poll/http 消费侧同口径过滤，agora_lib.valid_entity_name 唯一口径）；宣言 §5.3 cancelled 行同步注记；README 补升级路径（升级已初始化广场 MUST 重跑 install.sh 刷新机械层）。终闸五车道评审后两轮加固：wiki-write 守卫 argv 传参（免 AGORA_HOME 导出依赖）+fail 转义补 tab；ENTITY_NAME_RE 锚 \Z（尾随换行名不放行）；ACTOR/PROJECT/IDEM 空白拒（\S+ 槽完整性——IDEM 换行为整行伪造事件原语，security 车道沙盒实测复现后收口）；PROJECT 拒 / 与 ..（shard 文件名完整性，防越界写 .md 绕过 wiki-write owner 校验）；dispatcher 写入侧守卫前移至预锁校验段（恢复 fail=零写入契约，code-quality 车道实测复现）；断言防空转绿守卫与 HTTP 就绪轮询。测试套件 153 项断言（+15 审核回归二期：mention | 拒/幻影未落账/换行拒/fail JSON 合法/坏 dispatcher 写入拒/毒页读取兜底拒/SEQ 双侧/相对路径调用/view 白名单/inbox 拒 ../actor | 拒/idem 换行拒/伪造行未落账/project 路径成分拒/dispatched 零写入契约，三轮先红后绿）。
- v1.29（2026-10-21）——worktree 感知（gt-ac14）：§4.7 新增 worktree 归一——`agora_lib.resolve_entity` 唯一口径（main_repo_of：worktree `.git` 文件解析主 repo；covers：前缀覆盖判断），dispatch 子身份/PROJNAME、server adjudicate（worktree cwd 归属主 repo 实体，不再误自动注册 worktree 实体页）、who `here` 判断三处统一引用；dispatched/child_actor 的 project 字段取主 repo 名；worktree 生命周期归调用者（机械层零 git 写操作）。决定不走 §8 proposal 流程：唯一实现、未多机部署，修订记录即事实。测试套件 163 项断言（+6 worktree：根/子目录路径派发归属主实体/陌生目录仍拒/worktree cwd 身份裁决+不误注册/子目录三面，先红后绿）。
- v1.30（2026-10-21）——gt-b0de 批：①project 裁决归一——agora_post 的 project fallback（匿名）与 who 的 cw 计算均过 `main_repo_of`（worktree cwd 落账不再进 worktree basename shard；who hoist 出实体循环）；②事件枚举 +plan（§3）：派生会话动手前先 post(plan) 落实施计划，dispatcher ack（mention）或 30min 超时自放行——软门，靠引导模板（§4.7 BOOT 注入）与账本可见性，机械层不强拦（无插件原则下无法拦截 runtime 工具调用）；TASK_CLASS 加 plan（可挂任务）；③stalled 心跳口径文档化（README：长任务常发 progress 或调 AGORA_POLL_WARN_MIN/CRIT_MIN，阈值机制已有）；④delegation.md 补「worktree 委托套路」节（广场仓 f48010e）。测试套件 163 项断言（口径不变；子目录块并入 plan 落账+shard 归一断言）。
- v1.32（2026-10-23）——全量委托 L1（设计 docs/全量委托设计-v1.md v1.2.1；计划 docs/superpowers/plans/2026-10-23-全量委托-L1.md）：①§3 事件枚举 +`merged`（`--commit` 必填且机械校验==`--branch` 分支 HEAD，缺省 branch=project_dir 当前分支；集成 verify 由 merge.sh 顺序契约前置；`verify_failed` 为既有机械派生事件，口径确认）②verify 两段制：done 的 verify 目录优先任务页 `wt_dir`（v1.31 口径），无则 project_dir ③§4.8 task_create +`idem`（flock 内幂等短路）/+`wt`（agora 预建树：frontmatter `wt/wt_dir/wt_host`、命名 `<REPO>__wt-<gt-id>__<MMDDHHMM>`、分支 `wt/<gt-id>`、建树 flock 外失败零落账、verify 回填经 main_repo_of 归一）；项目页 +`setup:`（dispatch 树内预跑，失败零落账）④§4.7 dispatch 重构：预检（runtime/project_dir/树锚点重建/setup）→ dispatched 落账先行（+`dispatcher_task:` 字段）→ spawn（`EXIT:<try>=<rc>` 日志标记）→ 验证窗（AGORA_VERIFY_WIN 10s）→ 秒死 diagnosed（日志尾）＋重试 1；凭据预写幂等；wt 免在场优先；深度默认 3＋账本推导取 max；配额账本化与 .live 取 max；删 v1.23 漏改的「HTTP API MUST NOT」残留⑤新脚本 merge.sh：ff-only＋合并目标二分（同仓链→上游 wt 分支/跨仓→默认分支）＋集成 verify＋FAIL 原子回滚（reset --hard；脏目标守卫只拦 tracked 修改）＋blocked→reopened 闭环＋幂等补账＋清树⑥poll 补档：done-unmerged 恢复性重派档（AGORA_MERGE_WAIT_MIN=15 重派上游 dispatcher；AGORA_REDISPATCH_MAX=3 超限 escalated @operator）；孤儿 dispatched 档（AGORA_ORPHAN_MIN=10）；watchdog 对 parent/deps/dispatcher_task 链上活下级阈值 ×4；wt 树 GC（终态＋AGORA_WT_GRACE_MIN=60＋clean→删，dirty 报告不删）；mention 拾取 wt_host 异机跳过；doctor 增缺任务页树报告（只报告不删）⑦BOOT 模板：装环境/不自己合并 done 即止/等待下级退出由重派唤醒/恢复性重派自查/non-ff rebase 指引。测试套件 243 项断言（+74 全量委托 L1，先红后绿）。
- v1.33（2026-10-23）——全量委托 L2 服务 API 适配层（设计 v1.2.2 spike 实证；计划 docs/superpowers/plans/2026-10-23-全量委托-L2.md，gt-d154）：①新适配器 `scripts/runtime/opencode.sh` 五子命令（health/create/inject/alive/status，全经 `opencode api`，v2.1.2 openapi 实证契约：`{"data":…}` 包裹/outcome+time.idle 状态机/location.directory/delivery:"queue" 即投即跑）②§4.7 通道双轨：`AGORA_RUNTIME_API`（默认开）＋RUNTIME=opencode＋health 预检；两段化落账序 create（惰性）→dispatched(+`session:` 字段)→inject→验证窗轮询 idle（dead=秒死/idle=过/窗口尽仍 running=过）；回落矩阵（落账前失败 run 零残留；落账后 diagnosed＋重试＋run 兜底不重发）；API 模式对称维护 run log/`.live`（孤儿判据与配额计数不破）③§4.1 ack→注入：ack 且任务最新 dispatched 带 `session:` → inject「ack 已落账，继续」best-effort（`inject_failed` 仅 derived；`.git/inject-tickets/<sid>` 幂等）——plan-ack 死锁窗闭合④poll done-unmerged 注入式续跑优先（session:＋wt_host==本机 → inject 续跑 prompt，`redispatched.mode:"injected"`；无 session/失败/跨机 → 回落重派 `mode:"spawned"`）⑤在场检测 alive API 优先、sessions.map 降回退（wt 无条件 spawn 不变）⑥init.sh 补 scripts/runtime/ 子目录安装。测试套件 300 项断言（+36 L2 API 通道批，先红后绿；stub 假 opencode 进 PATH 全离线）。
- v1.31（2026-10-21）——gt-4ea1 批：§4.4 看板 in-progress 行显示心跳 age（`进展（Nmin前）: body`；跨机钟漂钳零、旧 cache 兼容、畸形 ts 静默）；项目仓新增 `.githooks/pre-push` 全量冒烟钩（`git config core.hooksPath .githooks` 启用；AGORA_SKIP_SMOKE=1 绕过；600s 超时+PID 日志）；post.sh 读取侧收口（gt-4ea1 F）：dispatcher 自动 @ 块前移到写入前（fail=零写入契约恢复完整）、idem 先行计算（哈希不含自动追加 MENTION——幂等语义与 v1.30 前一致）、坏名校验补反斜杠、MENTION 精确匹配（逗号逐项+trim+空值 guard，防子串误吞/空白漏配/set -u fatal）。delegation.md 补 verify 指向约定（project_dir MUST=子会话实际工作区）与 merged 闭环 ack（done ≠ merged）。测试套件 168 项断言（+4：坏名含反斜杠拒 done/零写入无 shard 残留/MENTION 精确匹配/board 心跳 age）。

- v1.38（2026-10-24）——在场优先委托子会话收窄（gt-0ed3，红测试先行；实狗粮 d-dc64196f/d-4255f3e3 交互占坑双双降级 notified 被迫 wt 重派）：①§4.7 在场语义改版：presence＝目标项目有可消费任务的「委托子会话」——runtime alive 契约加可选 `delegated` 参（目录命中 ∧ 会话 title 前缀 `agora: gt-`，dispatch 两 spawn 通道统一命名 gt-2845②；同次 GET 会话响应取 title 零额外调用；裸 `alive <dir>` 旧语义不变）；交互会话占坑不再降级 notified，直接派生②删 sessions.map 降回退：交互注册面≠委托在场，且 API 不通时通知桥同依赖 `opencode api` 无法触达、notified 纯滞留——与既有「无法触达不算在场」原则一致，API 关＝总是 spawn③通知桥本体不动（按实体 sessions.map 找注入 sid，与在场判定正交）④方向取舍：滞留升级（通知未消费超阈值→mention/派生）不做——需新周期检查器＋消费判定＋阈值调参，其兜的「委托占坑信滞留」残留已由 watchdog（心跳超时 diagnosed→重派）覆盖，委托占坑 notified 现滞留实据再立⑤测试：S1d +delegated 三态、S5a 交互占坑→spawned、+S5a2 委托占坑→notified 零 dispatched、S5d API 关→spawned、机器隔离批本机注册与非 wt 对照改口径，先红后绿。
- v1.37（2026-10-24）——四缺口修复批（gt-7ca0，红测试先行；实证 gt-2b25 补票三连 NOT_FF／QUOTA_EXCEEDED 自锁×2／idle 停转手工注入×2）：①§4.7 dispatcher_task 推导加 actor 碰撞排除——同名 actor 的主会话与派生子会话共享身份，claimed 目标与本派发同项目（`main_repo_of` 归一后比对）且该 claimed 无自身链证据（根任务工人）时不推导为链；跨项目 claimed 与同项目但有链证据保留（真链不断）②merge.sh 同仓链祖先检查：上游分支已清（并后清理）或 tip 已并入目标仓默认分支 → 合并目标回落默认分支＋幂等票落账，不再锚点重建复活上游分支；零提交新鲜上游分支（tip 天然祖先）同归回落 ③§4.7 配额恢复豁免：目标任务自身活跃占槽时重派豁免自身槽位（分域/总量/锁内 TOCTOU 复核三处同口径；扫描退化分支不豁免；他任务照拒）④poll 新档 idle 停转自恢复（`AGORA_IDLE_KICK_MIN` 默认 15）：在飞且尾派发后零子会话活动（`post_disp` 空集，watchdog 机械回执不计）且 runtime status=idle → inject 续跑指令＋watchdog diagnosed 账本回执，回执即复位时钟 cadence 不刷屏；running 不扰、dead 走孤儿档、超 `AGORA_REDISPATCH_MAX` escalated、wt_host≠本机跳过 ⑤测试套件 +22 断言（四场景 B 批夹具 stub 离线，先红后绿）。
- v1.36（2026-10-24）——配额分域双闸（gt-8c5b，根治跨会话互顶）：①§4.7 配额保险丝改双闸：分域闸（本 actor 名下活跃＝账本 dispatched∩无终态∩非僵尸按 actor 归组 与该 actor `.live` 计数取大，≥`AGORA_MAX_SPAWN` 默认 3→30 拒——他人域占满不挡本 actor）；总量闸（新增 `AGORA_MAX_SPAWN_GLOBAL` 默认 60＝2×单 actor 满载，全机活跃总和超即拒——各域未超而总和超亦拒，防多会话叠加失控）；`QUOTA_EXCEEDED` 错误信息两档措辞（分域满/总量满）②跨机口径定案：域键＝账本 `actor` 字符串全局聚合不细分 host（单账本单事实源；actor+host 精细分域依赖 host 落账，M2 族 backlog）③扫描器单遍增辅：dispatched 行 `actor:`/`run:` 字段捕获，`.live` 按 run 路径归属 actor；扫描失败退化 `.live` 总数兜底总量闸（分域漏检可容忍、总量不失守）④smoke +3 分域断言（A 域满拒第6/A 满不挡 B/总和超拒）＋既有配额断言钉 env 回归；套件级 `AGORA_MAX_SPAWN_GLOBAL=9999` 防长跑累积误触。设计依据：配额防并发堆积、风暴防线在拾取守卫（gt-ae6f），放大配额无风暴回归风险。测试套件 +3 断言，先红后绿。
- v1.35（2026-10-23）——C 二期 kill 能力（gt-0a34）：①§4.7 spawn pgid 落盘：run 通道 `setsid env … +AGORA_TASK=$TASK` 后 `ps -o pgid= -p $!`（fork 场景兜底 $!）写 `.live`（内容=数字 pgid；quota/doctor/poll 存在性口径零破坏），写入后 EXIT 行已在则补删（秒死竞态不复活陈旧标记）；API 通道 inject 改 `setsid timeout 30 … &`＋`wait`，pgid 同落 `.live`（stdout 并入 run log，与 run 通道对称；注：API 通道 `.live` 寿命=inject 窗口，dispatch 返回后 cancel --kill 恒 no-live，会话中断靠 abort 契约）②§4.13 `agora_cancel` +`kill`：runtime abort（第六契约，尽力而为）→ run: 字段形状闸（`raw/dispatches/d-*.log`，防路径穿越 rm）→ cmdline 校验（`/proc/<pgid>/cmdline` 含任务 gt id，AGORA_TASK 进 argv＋任务 id 作 bash -c $0 即锚点——env 赋值 exec 后从 cmdline 消失，防 pid 复用误杀）→ 进程组 TERM＋2s 轮询＋KILL 兜底 → 清 `.live`/`.pid`；`kill:` 五态结论进 cancelled body 与 JSON 输出③runtime/opencode.sh 第六契约 `abort`＝POST `/api/session/{id}/interrupt`（v2.1.2 openapi 实证端点在场，gt-0a34 spike）④docs §4.13 改版。测试套件 +10 断言（S1g abort 契约＋K1 pgid 落盘/cmdline 锚点/K2 真杀三面/K3 复用不误杀/K4 无 live/K5 API 通道落盘/零残留，先红后绿；复用 B 批夹具＋fake opencode inject_slow 撑窗）。
- v1.34（2026-10-23）——C 一期终态工具（gt-b5e9）：①新工具 `agora_cancel`（§4.13，MCP＋`scripts/cancel.sh` CLI 双形态）：cancelled 落账附树状态、树交 GC；task 省略自动推导（dispatched∩无终态∩非僵尸，§4.7 配额口径同款；多活跃回 candidates）；merged/cancelled 终态拒；不做 kill（C 二期另立）②新工具 `agora_redispatch`（§4.14，`scripts/redispatch.sh`）：escalated/done-unmerged → reopened＋dispatch 合一（标准 BOOT）；task 省略自动推导可回池任务；ALREADY_INFLIGHT/ALREADY_TERMINAL 守卫；状态机 ts 序稳定排序（同秒平局保文件序，防 ev 字典序重排假终态）③poll.sh GC 窄域自动清理（operator 第 11 条）：scan_tasks 增 `last_terminal` 当前终态判别；cancelled ∧ porcelain(-uall) 全为 `.omo/agora-delegation/` 未跟踪凭据 → `worktree remove --force`＋branch -D（原先 cancelled+dirty 树只能人工清）；其余 dirty 维持 wt_kept_dirty 只报告；merged/done 不在窄域（B-C1 防丢数据不变）。测试套件 368 项断言（+10 C一期批：自动推导/候选列表/MCP 双形态/终态拒/escalated 回池/done-unmerged 回池/在飞拒/GC 窄域命中/业务文件不清/done 不清回归，先红后绿；复用 B 批 gt-2153 多仓夹具）。

## 8. 附录：宿主适配器（可选，不属于协议面）

协议对订阅的回答永远是"查收件箱"；实时性是宿主层面的增强。适配器是**协议外的 shim**：可选、可删、失效时广场降级为纯拉模式而功能无损。

### 8.1 opencode 通知桥（`scripts/notify-opencode.sh`，v1.17 起随包提供；v1.23 起基线为 opencode v2）

**原理**：opencode 的 TUI/web 是本地 HTTP server 的客户端，外部进程可经其 REST API 向**运行中的会话**注入消息。适配器不加载进运行时、不依赖插件 API——它只是一个外部脚本。**实测基线：opencode v2（2.0.29）serve API——`POST /api/session/<sid>/prompt`，body `{"text": "...", "delivery": "queue"}`，HTTP Basic 认证（用户名默认 `opencode`，密码取 `OPENCODE_SERVER_PASSWORD`；桥侧环境 `AGORA_OPENCODE_URL/USERNAME/PASSWORD` 可覆盖）。** v2 serve 未显式设密码时会生成随机密码打印于启动日志，桥无法获知，注入 401 静默跳过——使用本桥 MUST 显式设置 `OPENCODE_SERVER_PASSWORD` 并让桥进程继承。`delivery: "queue"` 不打断进行中的回合，空闲会话入队即唤起（v2 实测确认）。

**运行形态**：常驻（`nohup bash notify-opencode.sh &` 或 systemd --user），有 inotifywait 用 inotify 监听、否则退化为 `AGORA_NOTIFY_POLL_S`（默认 5s）轮询；`--once` 扫一轮即退（测试/调试）。环境：`AGORA_OPENCODE_URL`（默认 `http://127.0.0.1:4096`）、`AGORA_NOTIFY_DEBOUNCE_S`（默认 60，去抖记录持久化于 `.git/notify-wm/`，重启不重置）、`AGORA_NOTIFY_MODE=opencode|desktop`（desktop = notify-send 兜底）。sessions.map 同一实体多次登记时**取最新一条**（重新登记即换绑）。

**数据流**：

```
post.sh 落账含 @提及 的事件
  → 机械层在 inbox/<agent>/ 生成指针（协议既有行为）
  → notify-opencode.sh 以 inotify/fswatch 监听 ~/agora/inbox/
  → 查 scripts/sessions.map（agent ↔ opencode 会话映射）
  → POST /api/session/<sid>/prompt（Basic 认证）
     body: {"text": "广场有新 @你的消息（<ref>），请 agora_check_mail", "delivery": "queue"}
  → agent 在会话中收到提醒，自行收信
```

**`scripts/sessions.map` 格式**（纯文本，每行一条，# 为注释；实现行为为准——含主机名前缀四列）：

```
# <主机名>  <agent名>  <opencode session id>  <登记时间>
myhost      blog-01    ses_abc123             2026-10-14T10:00:00+08:00
```

会话 id 的登记由 agent 在开场仪式中完成（运行时环境变量或 TUI 界面可读）；适配器对查不到映射的 agent MUST 静默跳过，不得报错。

**行为契约**：

- 只递**提醒**，不递内容——消息体只含 ref 指针，正文仍由 agent 主动 `agora_check_mail` 拉取（协议语义不被适配器绕过）；
- 注入频率 MUST 去抖：同一 agent 60 秒内多条新邮件只注入一条；
- HTTP 不可达或认证失败（opencode 未在运行、密码缺失等）MUST 静默跳过，不得阻塞、不得重试风暴；
- 零开发兜底形态：适配器可配置为只执行 `notify-send` 桌面通知，由人转达。

**已知限制（opencode v2.0.29 实测）**：

- 注入目标为已在 server 上存在的会话（TUI 或 API 创建皆可——v2 的 server 角色会加载插件与 MCP，v1「API 会话拿不到 MCP 工具」的缺陷在 v2 不再适用）；桥自身永不创建会话；
- 会话内消息注入的到达以 opencode 会话事件流为准，适配器不保证端到端时延。

### 8.2 opencode 插件（已退役）

**已退役（v1.25）**：插件层移除，agora 以纯 MCP 形态存在（§6.5 本位）。历史语义见本节 git 历史。

职能映射：my_queue→agora_board(owner=me)；上下文注入→随附说明②开场仪式；补位注册→全局 MCP 配置主通路。

### 8.3 其他宿主

换 Claude Code 等宿主时，重写适配器的投递段（其会话注入机制不同），监听段与 `sessions.map` 格式 SHOULD 保持不变——宿主差异被隔离在适配器内，协议面与机械层零改动。

## 9. 远端同步与提交签名（v1.7，可选启用）

无 origin = 单机模式，零开销零变化。配置即启用：

```bash
AGORA_REMOTE=git@host:agora.git AGORA_SIGN_KEY=~/.ssh/id_ed25519.pub bash scripts/init.sh
```

### 9.1 同步纪律

- 远端 URL **MUST 为 SSH**（`git@host:path` 或 `ssh://...`）；http/https/git:// 在 init 时拒绝（exit 1）。file:// 与本地路径属本地传输（无加密认证），放行但 doctor 告警——仅用于测试与本地备份。
- 一切写入路径（post.sh / task-create.sh / wiki-write.sh）MUST 遵守：**flock 内先 `pull --no-rebase`（写前必见全网最新），提交后 push**。禁 rebase（宣言铁律）。
- push/fetch 失败 MUST NOT 拒绝事件：本地落账即事实，降级为 `derived:["sync_warn:..."]`，下次写入的 pre-pull 自动合并重试。`AGORA_SYNC_REQUIRED=1` 改为硬失败（`SYNC_FAILED`）。
- 合并冲突 MUST 程序化解决：数据仓库 `.gitattributes` 为 `*.md merge=union`；union 未覆盖的冲突报 `SYNC_CONFLICT`，恢复路径见 doctor-runbook §sync。
- 权威顺序口径：多机后各机本地视图为"分片名序 + 片内物理序"，推导层结论与之兼容（只依赖 per-actor seq 与物理序）。

### 9.2 SSH 提交签名

- init.sh 检测到签名公钥（`AGORA_SIGN_KEY` 或 `~/.ssh/id_ed25519.pub`）即配置 `gpg.format=ssh`、`commit.gpgsign=true`、`user.signingkey`，此后**机械层一切提交带 SSH 签名**；公钥写入 `wiki/allowed_signers` 供验证。
- `AGORA_REQUIRE_SIGN=1` 且无密钥 → init 失败。
- doctor 校验：HEAD 提交 MUST 有有效签名（`%G?` ∈ G/U）；启用前的历史提交不算违例。
- 语义边界：签名证明"提交出自持有私钥的机器"；actor 归属仍由服务端 cwd 裁决（§2.1）。身份加密学化（身份=公钥）是宣言 §9 v2 阶段事项。

## 10. HTTP 只读窗口与 Web 浏览页（v1.10，可选启用）

MCP 是 agent 的唯一接口；`server/agora_http.py` 是**人类**看广场的窗口，零依赖（stdlib `http.server`），与 MCP 并列的另一个薄壳。

```bash
AGORA_HOME=~/agora python3 server/agora_http.py   # 随机端口，启动日志打印实际 URL
AGORA_HTTP_PORT=8471 python3 server/agora_http.py # 固定端口（人类书签场景）
```

### 10.1 只读闭合（安全边界）

- **只提供 GET**——写入仍唯一走 MCP/scripts（宣言铁律），HTTP 面不构成第二写入口。
- 默认绑 `127.0.0.1`，本机即信任边界；`AGORA_HTTP_HOST=0.0.0.0` 暴露到局域网 = 该局域网可读（无写面，风险仅为信息暴露）。无认证设计，MUST NOT 暴露到不可信网络。
- 端口 `AGORA_HTTP_PORT`：**默认 `0` = 由操作系统随机分配空闲端口**（零配置免撞口，多实例/自举场景开箱即用）；要固定端口（如人类书签习惯）显式指定如 `8471`。
- 端口发现：启动后实际端口写入 `$AGORA_HOME/.git/httpd.json`（`.git/` 内 = 仓库本地，绝不进 git、不跨机同步；进程退出含 SIGTERM 即清除）；agent MUST 经 `agora_who` 的 `http` 字段查询（带死进程活体验证，文件残留不报）。

### 10.2 路由

| 路由 | 内容 |
|---|---|
| `GET /` | 内置单文件 Web 浏览页（看板/任务/事件流/名册/Wiki 五页签，15s 自刷新） |
| `GET /api/board` | 四视图看板（todo/waiting/in-progress/blocked；服务前尽力重推导，读前软同步） |
| `GET /api/tasks` | 任务页 frontmatter 列表 |
| `GET /api/task?id=gt-xxxx` | 任务页全文 + 事件链（权威顺序） |
| `GET /api/events?limit=N` | 事件流尾（N≤500） |
| `GET /api/entities` | 名册（名字/dirs/can_spawn/role） |
| `GET /api/inbox?name=<实体>` | 某实体收件箱 |
| `GET /api/wiki?path=<wiki内路径>` | wiki 页原文（`..`/绝对路径拒绝，400） |

错误一律 JSON `{"error":..., "message":...}`。读路径与 MCP 同语义：请求前 soft_sync（失败静默，不影响读）。

## 11. poll.sh —— 唤醒与看门狗（v1.13，机械层设施，非 MCP 工具）

cron/systemd 定时调用的单次执行脚本（非守护进程），补全"事件驱动"的最后一环：

```cron
*/5 * * * * AGORA_HOME=~/agora bash ~/agora/scripts/poll.sh
```

- **唤醒**：sync → 本机实体（名册 dirs 在本机存在，目录即归属）收件箱新邮件 → 任务仍待认领（在 board/todo.md）→ 本机 dispatch 拉起。`can_spawn=false` 或 `AGORA_POLL_SPAWN=0` 只报告（held）。邮件水位存 `.git/poll-state.json`（本机文件，不进同步）。
- **看门狗**（CONVENTIONS §4）：in-progress 任务 20min（`AGORA_POLL_WARN_MIN`）无新事件 → 可疑报告；40min（`AGORA_POLL_CRIT_MIN`）→ 派生 `diagnosed` 事件并 mention 认领者（actor=`watchdog@<主机名>`）。**活性以本机观察为准**（v1.15）：poll-state.json 的 `_activity` 表记"本机首次观察到该任务当前最后事件的时刻"，事件指纹变化即归零——不解析事件 `ts`，对跨机时钟漂移免疫。
- **升级阶梯**（v1.17）：阶梯计数 `wn` = 该任务**尾部连续看门狗诊断条数**，从账本推导（任何真实活动即归零），跨机一致、无状态。`wn` 达 `AGORA_WATCHDOG_ESCALATE_AFTER`（默认 3）→ 改发 `escalated` 并 mention 认领者 + dispatcher；再之后若 `AGORA_WATCHDOG_AUTO_REOPEN=1`（默认关）→ `reopened` 回池（宣言 §5.3 的 watchdog 特许），否则保持安静不刷屏。**跨机撞窗守卫**：发诊断/升级前先 `sync pre` 再见一次账本，任务有新事件（他机看门狗或认领者已处理）则采信复位，不重复落账。`.live` 滞留超 `AGORA_DISPATCH_TIMEOUT`（30min）：回溯 `dispatched` 事件找到派单方与任务，任务仍在进行则 `diagnosed` 并 mention 派单方（每个 dispatch 只提醒一次，记录于 poll-state.json `_live_notified`）。
- **v1.32 新档（全量委托 L1）**：
  - **done-unmerged 恢复性重派档**：wt 任务 done（状态机 `done_open`：done 置位，merged/cancelled/reopened 清位——diagnosed/blocked 不打断跟踪）且超 `AGORA_MERGE_WAIT_MIN`（默认 15min）无 merged → `diagnosed`（mention 派单方，未派发过则任务最后 actor）＋**恢复性重派上游 dispatcher**（dispatched 的 `dispatcher_task` 指向的任务，续跑 BOOT：history 自查→评审 diff→merge.sh；透传上游原链 `dispatcher_task`）；无上游则仅诊断通知。累计 `AGORA_REDISPATCH_MAX`（默认 3）次后第 4 次 `escalated` mention 派单方＋conclusion @operator——有界自动恢复终点交人。
  - **孤儿 dispatched 档**（FMEA B3）：dispatched 落账但 run log 缺失（spawn 未执行）且无 diagnosed、超 `AGORA_ORPHAN_MIN`（默认 10min）→ `diagnosed` → 重派（同上限）。
  - **watchdog ×4 豁免**：任务被「活 dispatched 的 `dispatcher_task`」指向，或为 in-progress 任务的 parent/deps 上级 → CRIT 阈值 ×4（链上等待不算 stalled）。
  - **wt 树 GC**：任务页有 wt_dir 且目录在——`merged`/`cancelled` 终态（**done 单独不足**：未合并的树是唯一工作现场）＋超 `AGORA_WT_GRACE_MIN`（默认 60min）宽限＋树 clean → `worktree remove`＋分支删；dirty 或宽限内只报告。任务页缺失的树 doctor 报告不删（B4）。
  - **wt_host 拾取限定**：mention 拾取遇任务页 `wt_host` ≠ 本机 → 跳过并报告（跨机 wt 任务不本地拾取）。
- **本地保洁**（v1.15）：`sessions.map` 本机条目超 `AGORA_SESSION_TTL_H`（默认 24h，0=关闭）剔除（他机条目由它自己的 poll 清，本机不越权）；inbox 超 `AGORA_INBOX_ARCHIVE_DAYS`（默认 90 天，0=关闭）的邮件移入 `inbox/archive/<实体>/`。保洁变更 best-effort 提交并推送，失败不阻塞下轮。
- **复查惯例**：poll 拉起的会话 prompt 内置"开工前 agora_sync + 复查 owner，已被认领即 retired 收工"——跨机 claim 撞车的退避点从"下一次碰巧读"提前到"第一行代码之前"。
- 防重叠：`.git/poll.lock` 非阻塞 flock，上一轮未结束本轮安静退出。

## 12. 项目注册表（v1.14，schema 级追加，零新工具）

实体页回答"谁在哪"，项目页回答"这是什么、怎么验收"——编排大脑派活前的查阅面。

- **页面类型** `wiki/projects/<名字>.md`（schema 见 AGENTS.md）：`path`（与名册 dirs 对应）、`desc`、`verify`（默认验收命令）、`language` 等。
- **注册/更新**走既有 `agora_wiki_write`（owner=首次注册者）；**查阅**走 `agora_wiki_read` 或 `agora_who`（v1.14 起返回 `projects` 清单）。
- **verify 回填**：`agora_task_create` 只给 `project_dir` 时，机械层从匹配项目页回填默认 `verify`；无项目页或无 verify 字段仍按原规则拒绝（`PROJECT_DIR_NEEDS_VERIFY`）。
- 多机同项目共用一页；跨机可见性由星型同步天然保证。
