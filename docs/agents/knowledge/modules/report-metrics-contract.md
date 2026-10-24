# 周报度量口径契约（report.sh）

> gt-77a8（2026-10-24）。scripts/runtime/report.sh 的度量语义是毕业判定的唯一口径；改口径必须同步本页与 golden fixture。

## 口径契约
- **spawn/merged 取点**：spawn=任务首条 `dispatched`，merged=任务首条 `merged`；全账本扫描，分片必须含点分片伴生（glob 追加 `log/*/.*.md`，gt-40cc 规矩）。
- **干预事件集**：`diagnosed/reopened/escalated/cancelled`（任何 actor，含 watchdog——watchdog 诊断仍是在场干预信号）。
- **dispatcher 干预数**：干预事件且 actor 与该任务页 frontmatter `dispatcher:` 字段按 @ 本地段身份规范化后相等（账本 actor 带宿主后缀、页面字段为裸名——现网实证严格串比较致指标恒 0；无任务页/无字段则不可归属不计）。
- **毕业计数 N**：仅有 merged 的任务按 merged ts 排序，扫 `(spawn, merged]` 窗口；窗口内出现任一干预事件＝脏，streak 归零重数；未 merged 任务（在飞/取消）不入列。
- **缺席≠0**：账本无事件→四数字与 N 全 N/A；drill JSON 缺失→drill 节显式 N/A。数据源缺席计 0 会伪造毕业信号（设计 Review Focus #4）。
- **坏数据≠崩溃**：坏 ts 或缺时区（naive）的行＝时间算术跳过（p_ts 返 None，naive 值结构性无法进入任何比较/排序，混存崩溃全族闭合，终闸 B1＋Round-2 N1）；跳过≠度量扭曲——该行事件仍入 events，reopened/diagnosed/干预计数照常计值，仅不参与时间窗与墙钟。
- **信任边界**：drill JSON 的 ts/skipped 字段过 md_safe 消毒（`|\r\n#` 剥离），markdown 结构禁入报告（终闸 C2）；AGORA_HOME 与 AGORA_DRILL_STATE 同路径或互相包含（任一为另一子路径）拒跑 rc2，保只读不变量（终闸 C3＋Round-2 绕过收口）。
- **只读**：账本零写入是硬约束；唯一落盘是 state 目录 `report-<YYYY-Www>.md`（ISO 周，`%G-W%V` 语义由 `isocalendar` 提供）。

## 可测性缝
- `AGORA_HOME`／`AGORA_DRILL_STATE` 环境变量覆写缺省路径——smoke golden fixture 的唯一注入面；生产零感知。
- golden fixture 断言精确值（中位 2400s/n=4、2/2/2、N=2 含脏任务居中归零重数），防口径漂移。

## 教训
- 解析元组多消费方（4 元组 events 与 3 元组 per-task evs）时禁裸下索引跨用——本次 `cnt()` 误用 `e[2]`（actor）取 event，静默错值零报错；同类结构一律解包取名字段或断言钉值。
