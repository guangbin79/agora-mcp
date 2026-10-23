# knowledge log

- 2026-10-21 gt-ac14 bootstrap：worktree 感知落地（resolve_entity 唯一口径 + 三消费方收口 + 终闸 HIGH 向上爬修复），入库 modules/worktree-resolution.md（含闭包/测试 env 两事故教训、独立小广场测试模式、部署形态注意）。评审循环 3 轮（ocr 5 findings + 终闸 1H2L + 复审通过），smoke 163/0。
- 2026-10-21 gt-4ea1 v1.31 批：pre-push 钩/心跳 age/post.sh 读取侧三件；ocr 6 findings 全修（块序-幂等时序教训入库 worktree-resolution.md）；终闸通过（幂等/dedup/mention 边界端到端实测）。smoke 168/0。
- 2026-10-22 gt-eefd 批：agora_post actor 三级解析（显式 > dispatch env 反查 child_actor > 进程 ACTOR，run id 反查键）；评审循环 2 轮（终闸三分册 1C1W1S 全修 + 复审零 blocker/high），夹具 env 形状判别教训入库 modules/actor-attribution.md。smoke 169/0。
- 2026-10-23 gt-db15：done_open 状态机 ts 序重放收口（gt-caf3 last 同源漏网）；「派生态单点重放/同源缺陷一次收全/has 守卫≠正确性」入库 modules/ledger-replay-ordering.md。smoke 302/0。
- 2026-10-23 gt-2845 K3 批：run 通道预生成 sid＋子会话命名＋MAX_DEPTH 5＋verify 锚点重建（post.lock 同锁收敛两处重建点并发窗）；「opencode 外部 id spike 先行/旗标漂移 smoke 盲区/sed p 位置回归」入库 modules/opencode-external-session-id.md。评审循环 2 轮（终闸三分册＋ocr 8：7修3记录；Round-2 复核 2W1S 全修），smoke 318/0。
