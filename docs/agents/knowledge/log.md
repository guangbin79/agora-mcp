# knowledge log

- 2026-10-21 gt-ac14 bootstrap：worktree 感知落地（resolve_entity 唯一口径 + 三消费方收口 + 终闸 HIGH 向上爬修复），入库 modules/worktree-resolution.md（含闭包/测试 env 两事故教训、独立小广场测试模式、部署形态注意）。评审循环 3 轮（ocr 5 findings + 终闸 1H2L + 复审通过），smoke 163/0。
- 2026-10-21 gt-4ea1 v1.31 批：pre-push 钩/心跳 age/post.sh 读取侧三件；ocr 6 findings 全修（块序-幂等时序教训入库 worktree-resolution.md）；终闸通过（幂等/dedup/mention 边界端到端实测）。smoke 168/0。
