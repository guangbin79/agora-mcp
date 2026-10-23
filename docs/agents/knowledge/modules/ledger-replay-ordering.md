# ledger-replay-ordering

> 账本扫描派生态（last/done_open/has）的重放次序契约。来源：gt-caf3（last 修复）＋gt-db15（done_open 收口）。

## 结论
- glob+sorted 的文件字典序≠时间序，同日多分片（含点分片）是常态而非边角；任何按扫描序内联推导的派生态都会被乱序事件污染。
- 派生态统一在单一收口重放：`scan_tasks` 先收集每任务 `(ts,event)` 全行（`_rows`），排序后统一重放全部状态机（last 取尾行、done_open 逐行置位/清位），禁止在文件扫描循环里内联推导。
- 同源缺陷要一次收全：gt-caf3 只修了 last（done_open 漏网继续按文件序重放），根因是两处状态机两套重放路径——新派生态入库时必须在同一排序重放点实现，否则必复发。

## 逐字证据
- `log/*/…` 分片内行序即写入序，但跨分片读取序由文件名决定：`sorted((glob.glob(f"{HOME}/log/*/*.md") + glob.glob(f"{HOME}/log/*/.*.md")))`
- 乱序构造（smoke T6）：字典序前分片放晚闭合事件（merged/cancelled @T2），字典序后分片放早 done（@T1）——文件序重放得 done_open=True 误诊 done-unmerged；ts 序重放得 done→merged 清位（对）。
- 诊断侧另有 `\"merged\" in d[\"has\"]` 集合守卫遮蔽 merged 变体（has 与序无关不受乱序影响），cancelled/reopened 变体无守卫、裸露红——守卫只证明「没炸」不证明「对」。
