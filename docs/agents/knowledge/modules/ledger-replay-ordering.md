# ledger-replay-ordering

> 账本扫描派生态（last/done_open/has）的重放次序契约。来源：gt-caf3（last 修复）＋gt-db15（done_open 收口）。

## 结论
- glob+sorted 的文件字典序≠时间序，同日多分片（含点分片）是常态而非边角；任何按扫描序内联推导的派生态都会被乱序事件污染。
- 派生态统一在单一收口重放：`scan_tasks` 先收集每任务 `(ts,event)` 全行（`_rows`），排序后统一重放全部状态机（last 取尾行、done_open 逐行置位/清位），禁止在文件扫描循环里内联推导。
- 同源缺陷要一次收全：gt-caf3 只修了 last（done_open 漏网继续按文件序重放），根因是两处状态机两套重放路径——新派生态入库时必须在同一排序重放点实现，否则必复发。

## 收口复发（gt-6fef）
- gt-3ea2 波（43158da）修了 derive/dispatch/doctor/poll/merge/post 六处读点，仍漏 `agora_lib.iter_events`——history.sh、agora_mcp（agora_history/child_actor 反查）、agora_http 三读面全经它同源断链。「一次收全」必须 grep 全仓 glob/find 读点清单，不能只修当日报障面。
- 语义锚：Python glob 模块 `*` 静默排除点前缀文件（fnmatch/pathlib 无此语义）；系统 Python 3.10 无 `include_hidden`（3.11+），本仓口径=双 glob `glob.glob("log/*/*.md") + glob.glob("log/*/.*.md")`——两模式不相交，排序语义不变。

## 同秒平局稳定排序（gt-b5e9）
- ts 只到秒级：同秒多事件跨分片是常态（watchdog 与 worker 各落各的分片）。重放排序 MUST 单键 `rows.sort(key=lambda r: r[0])` 靠稳定性保文件序＝因果序；裸 `rows.sort()` 元组全排会在平局时按 event 字典序重排——`reopened` 字典序最后，把已 merged 的任务重放回「尾行 reopened、term=None」假象，终态守卫全部失真（cancel/redispatch 探针实证：merged 尾态任务被放行重派）。
- 乱序降级方向必须保守：跨分片同秒无因果序时（如 escalated(hx 分片) 与 dispatched(repa 分片) 同秒），排序误序只允许产生「拒绝侧」失败（INFLIGHT 拒重派），不允许产生「放行侧」误派；smoke 夹具侧错秒（sleep 1）避开平局，G6 先例。
- 新状态机入账（cancel/redispatch）时逐字对照 scan_tasks 重放语义：done_open 置位/清位、term 置位/清位、inflight 置位/清位三条独立线，别合并 elif 链。

## 逐字证据
- `log/*/…` 分片内行序即写入序，但跨分片读取序由文件名决定：`sorted((glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md")))`
- 乱序构造（smoke T6）：字典序前分片放晚闭合事件（merged/cancelled @T2），字典序后分片放早 done（@T1）——文件序重放得 done_open=True 误诊 done-unmerged；ts 序重放得 done→merged 清位（对）。
- 平局构造（cancel/redispatch 探针 ④）：同任务 dispatched/claimed/done/reopened/dispatched/merged 六行全在 22:42:47 同秒，裸元组排序尾行变 reopened → term=None → merged 尾态放行；稳定排序尾行 merged → ALREADY_TERMINAL（对）。
- 诊断侧另有 `\"merged\" in d[\"has\"]` 集合守卫遮蔽 merged 变体（has 与序无关不受乱序影响），cancelled/reopened 变体无守卫、裸露红——守卫只证明「没炸」不证明「对」。

## 实证读面对齐（gt-d31a，2026-10-25）
- 「修复无效/仍读盲」类实证结论前，先对齐观察路径的代码面：主检出分支是否含修复 commit、init 自举拷贝世代、包装器指向哪个 SCRIPTS。gt-d31a 任务页 10-25 实证「history 仍缺 dispatcher 事件」不可由任何现役路径复现（MCP 面 history(gt-c3d7)=16 含 dotfiles-orch×5；f6e4 已移除 plaza 自举拷贝；bg-wait/agentctl 直连产品仓单源）——盲读源锁定为陈旧拷贝/落后检出（环境考古冒充活缺陷）。点分片修复本尊 f874f92（见上节收口复发）无需再动。

## 收口复发二（gt-6769）
- dispatch.sh ledger_scan 的 dispatcher_task 推导（cands[-1]）是文件序残留消费点：同 actor 事件跨 UTC 日期分片分裂（本地 00:00-08:00 长跑跨日界＋写者时区混写）时，昨日分片整目录排前、新 claimed 扫描序反被排后，纯文件序「尾＝最近」取到陈旧遗留 claimed。现场签名：新落账行 ts 带 +00:00（writer-local 时区）落昨日日期分片，seen 计数按分片各自统计（52＋154≈206 全量）。
- 修法口径：推导「最近」按 claimed 行 ts（fromisoformat offset-aware）判新近度，分片文件序＋行序降为破平兜底（＝append-only 写入因果序）；naive/不可解析 ts 不可跨形态比较，一律退扫描序。writer-local 时区不强统（post.sh 落真实时钟），跨机 ts 可比性另立。
- 夹具形态：构造性跨日分片断言（F5b）——遗留 claimed 旧瞬间 ts 落今日分片＋新 claimed 新瞬间 ts 落昨日分片，推导必须取新 claimed；比时区环境翻转确定性高，不依赖faketime。
- 残留同型：cancel.sh 自动推导 pick=cands[-1]（文件序尾＝最近派发）同病未治——--kill 语义下翻车即杀错会话进程组，待红后另立任务。
