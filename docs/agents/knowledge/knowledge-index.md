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
- [report-metrics-contract.md](modules/report-metrics-contract.md) — 周报度量口径契约：spawn/merged 取首条、干预事件集、dispatcher 归属任务页字段、N 归零重数、缺席→N/A 禁计 0、点分片伴生 glob、可测性 env 缝 (2026-10-24, gt-77a8)
