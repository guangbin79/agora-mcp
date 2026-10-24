# knowledge-index

> 模块任务前必查本索引；新知识经 project-compound ingest 入库并回写此索引。

## modules
- [worktree-resolution.md](modules/worktree-resolution.md) — worktree 路径→实体解析唯一口径（resolve_entity/main_repo_of）、闭包与测试 env 两个事故教训、独立小广场测试模式、部署形态注意 (2026-10-21, gt-ac14)
- [actor-attribution.md](modules/actor-attribution.md) — 事件落账身份归属：env 证据优先于调用方自觉/账本权威于现裁决/夹具 env 形状须逐字节对齐生产注入 (2026-10-22, gt-eefd)
- [ledger-replay-ordering.md](modules/ledger-replay-ordering.md) — 账本扫描派生态重放次序契约：last/done_open 统一 ts 序单点重放、同秒平局单键稳定排序（裸元组全排＝ev 字典序假终态）、同源缺陷一次收全、has 守卫≠正确性证明 (2026-10-23, gt-db15＋gt-b5e9)
- [ladder-terminal-semantics.md](modules/ladder-terminal-semantics.md) — 梯子真值分层契约：看板→账本终态旗标→git 祖先短路三层判值、reopened 返工不误杀、短路 fail-open 朝警报、夹具态＝生产态 (2026-10-23, gt-99af)
- [wiki-write-replace-semantics.md](modules/wiki-write-replace-semantics.md) — wiki-write replace 只写 content 丢 frontmatter 的代际退化、周期重写方须回写头、nothing-to-commit 视为成功 (2026-10-23, gt-abcd)
- [ledger-fixture-contract.md](modules/ledger-fixture-contract.md) — smoke 账本夹具三闸：seq 按(分片,actor)从 1 连续、dispatched 夹具收终态防占全局配额、夹具位置 vs doctor 对账窗 (2026-10-23, gt-abcd)
- [smoke-teardown-orphan.md](modules/smoke-teardown-orphan.md) — 夹具 teardown 孤儿竞态：.live 有界轮询再 rm、探针匹配面＝实例唯一 mktemp 路径（禁全机按 task id pgrep）、竞态窗先现形再证修复 (2026-10-23, gt-2153)
- [task-page-amend-channel.md](modules/task-page-amend-channel.md) — amended 修正通道信任边界：守卫/改写同锚 frontmatter、应用序先页后账本（重试收敛判据）、wt_dir 命名域收敛、pipefail×grep 地雷 (2026-10-24, gt-b9fb)
- [mention-pickup-loop-breaker.md](modules/mention-pickup-loop-breaker.md) — mention 拾取环断路契约：守卫序 done_open→todo→终态→retired→在飞去重、邮件=通知账本=真值分层、retired 回池须排除 done（gt-bb0b 风暴根因） (2026-10-23, gt-ae6f)
- [runtime-adapter-guard.md](modules/runtime-adapter-guard.md) — runtime 适配器调用方三重守卫契约（AGORA_RUNTIME/AGORA_RUNTIME_API/-f）、守卫缺失＝静默空转非崩溃、哑 env 哨兵防传输回归 (2026-10-23, gt-2b25)
- [quota-fuse-atomicity.md](modules/quota-fuse-atomicity.md) — 配额检查-落账 TOCTOU：dispatch.lock 锁内复核＋fail-closed（空扫描放行＝复辟）、风暴断言确定性来自串行化、槽位释放账本口径测 (2026-10-24, gt-2e4f)
- [drill-busy-guard.md](modules/drill-busy-guard.md) — 演练忙碌守卫三课：扫描崩溃 fail-closed 让行（禁 fail-open 盲扰）、波次口径=尾事件 dispatched（inflight 计入积压会让 weekly drill 永久失效）、lib 取同包路径防广场拷贝滞后 (2026-10-24, gt-ef4c)
- [report-metrics-contract.md](modules/report-metrics-contract.md) — 周报度量口径契约：spawn/merged 取首条、干预事件集、dispatcher 归属任务页字段、N 归零重数、缺席→N/A 禁计 0、点分片伴生 glob、可测性 env 缝 (2026-10-24, gt-77a8)
- [board-lane-membership.md](modules/board-lane-membership.md) — 看板泳道成员资格口径：poll 派生旗标复位集逐字对齐 derive-board 状态机（自行加宽＝失看护盲区）、瞬时活性与成员资格两层分离、出泳道集真源＝apply() 分支 (2026-10-24, gt-ef98)
- [merged-terminal-precedence.md](modules/merged-terminal-precedence.md) — merged 机械终态先于 retired 过滤、缓存版本 bump 强制全量补账、夹具甄别力与分片因果序双闸 (2026-10-24, gt-5a59)
- [drill-assertion-window-anchor.md](modules/drill-assertion-window-anchor.md) — 演练断言窗内事实锚与场景域隔离契约：断言禁等超窗系统性事实（CRIT 诊断）、poll rc 锚辨真轮（flock skip 也 exit 0）、夹具双域隔离（在场降级/配额互染）、复通断言接受合规降级须记录原因 (2026-10-24, gt-f8ed)
- 共享主检出写入纪律: `docs/agents/knowledge/modules/shared-checkout-commit-first.md`
- [cron-direct-exec-contract.md](modules/cron-direct-exec-contract.md) — cron 直执接线双合同：执行位 git mode 100755（diff 不可见，遗漏=126 静默潜伏）＋CLI 形态实测（字面速记 vs 实 usage，verify/grep 须逐字对齐）；实弹射击验收手法（systemd-run 等价脱附） (2026-10-24, gt-5f59)
- [shared-state-second-writer.md](modules/shared-state-second-writer.md) — 共享可变状态第二写者契约：新增写者与既有截断重写者共锁（lost-update 窗口周期性存在）、set -e 下尽力而为副写入显式吸收失败（防假失败重复重派）、共享夹具断言按 key 禁全表计数 (2026-10-24, gt-8a3c)
