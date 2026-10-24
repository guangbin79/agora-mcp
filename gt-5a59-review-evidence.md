# review-loop 证据 gt-5a59（ses_e931）

- 会话: ses_e931ea5cdffe6PQ3dxIg7SVn4G
- 仓: /home/guangbin/agora-mcp__wt-gt-5a59__10241547（wt 树，分支 wt/gt-5a59，基线 34a3da2）
- scope: dirty-tree, session-edited: scripts/derive-board.sh, tests/smoke-test.sh（无 residue/origin 项）
- 测试命令: bash tests/smoke-test.sh（仓内既有脚本；无 Makefile/package.json）

## 意图声明（A 册基准；本仓无 docs/reqs/，按降级规则以声明为基准）

任务页 wiki/tasks/gt-5a59（dispatcher=dotfiles-orch）合同：
1. derive-board apply() 新增 merged handler：state 任意→done（终态语义，owner 同 done 惯例）
2. blocked handler 加前置守卫 state=="in-progress"
3. smoke 三用例先红后绿：done→merged 离场；done→blocked 不入 blocked 栏；reopened→todo→merged 离场
4. 全量 smoke 绿；真仓 derive 后 board/todo.md 由 65 降至仅真 open（当日 merged 全部离场）
5. 变更面仅 scripts/derive-board.sh＋tests/smoke-test.sh

实施中延伸（验收条款 4 迫使，已在 req-gate 文件与 progress 落账声明）：
6. merged 分支置于 retired 过滤之前（机械票据终态不受 actor retired 盲化）——真仓实证第二根因
7. derive-cache v3→v4（v3 水位下 merged 已被当 no-op 消费，bump 强制全量重放补账）
8. smoke ⑥b 断言随根因消除改形（todo 不残留＋零派发）；增量缓存断言 v==4

## 轮次记录

### R0（评审前自证，2026-10-24 16:04-16:0x）
- 红→绿（隔离临时广场，HEAD 旧 derive vs 新 derive）：②done被拖blocked FAIL／③merged后永驻todo FAIL／④retired盲化 FAIL → 全绿
- 全量 smoke：**474 通过, 0 失败（SMOKE_EXIT=0）**，基线 470＋新增 4 用例
- 真仓验收：board/todo.md 69→35，merged 残留清零（抽查 4/5 离场；gt-d039 账本无 merged 事件属真未并）
- 剩余 35 条复核：9 cancelled经reopened合法回池＋18 done-unmerged待并＋8 纯 open＝账本真值

（结果与评审发现按轮续写）

### R1 ocr_review 快筛发现（glm-5.3，7 条，2026-10-24 16:2x；会话 c01f5f25）

| # | 位置 | severity | 内容摘要 | 裁决 |
|---|------|----------|----------|------|
| 4 | smoke:2438 | **high** | ③夹具跨分片乱序：reopened 由 watchdog@$(hostname) 发出→落 hostname 分片，derive 按分片序重放，reopened 永不落在 done/merged 之间；hostname 排序早于 proj 时 reopened 变 no-op 前置（用例空转），晚于 proj 时重放最后把 merged 任务拖回 todo（跨环境翻红） | **成立，必修**。改经 post.sh --actor watchdog@proj --project proj 落 proj 分片保因果序 |
| 1 | smoke:2443 | medium | ①空转：done 后本就不渲染任何栏，!grep todo 恒过，不能甄别 handler | 成立。①改为 claimed→merged（无 done）→断言离 in-progress 场＋cache state==done——「state 任意→done」的甄别形；与任务页字面（done→merged）偏差记入证据：字面形不可甄别（done 已终态），⑥b 已覆盖 todo→merged、③覆盖 done→reopened→todo→merged |
| 2 | smoke:1683 | low | ⑥b 改形丢失 gt-99af 修复一（poll 账本终态守卫）的覆盖：现形态走普通看板检查即 continue | 成立。补滞后窗变体：raw 追加 merged 行（不经 post.sh 同锁 derive）→看板滞后→POLLT 应 held「终态」＋零派发 |
| 5 | smoke:2451 | low | ④前置未验证：retired POST 结果被丢弃，若静默失败则④退化为普通 todo→merged | 成立。断言 retired 落账（grep seq）再续 |
| 3 | smoke:2451 | low | retired 毒化脚枪：agora-mcp@proj 自此被套件剩余部分盲化（现无后续使用，防未来新增踩雷） | 成立。补尾注 comment |
| 6 | smoke:633 | low | v3→v4 强制失效路径无覆盖：只测了 v4 写侧，旧缓存自愈迁移无回归 | 成立。补毒化 v3 缓存→derive→全量重放自愈＋v4 断言 |
| 7 | derive:89 | low | cancelled→done 非对称：merged 可覆盖 cancelled 而 cancelled 不能覆盖 done；若属本意请注释声明 | 属本意（任务页「state 任意→done」机械真值；merge.sh 实操链对 cancelled 任务不发 merged）。补一行注释声明 |

### R1 修复（7/7 落地）
- #4 ③④ reopened 显式 post.sh --actor watchdog@proj --project proj 同片落账（保因果序）
- #1 ①改甄别形 claimed→merged（无 done）＋cache state==done 断言；与任务页字面偏差已在 R1 表声明
- #2 ⑥b-lag 初版红（R1 smoke 475/1：mention post 自身 derive 先行自愈）→改判：poll.sh:38 启动即 derive，
  滞后窗生产路径结构性不可达，held 分支降为崩溃窗纵深；断言改可达不变量（零派发＋自愈离板）
- #3 agora-mcp@proj 盲化脚枪尾注 #5 retired 落账断言（OUT4 grep seq） #6 ⑤毒化 v3 缓存自愈用例
- #7 derive 注释声明 cancelled→done

### R2 全量 smoke（R1 修复后）
- bash tests/smoke-test.sh：**476 通过, 0 失败（SMOKE_EXIT=0）**——绿门过

### R2 三分册终闸（2026-10-24 16:4x，零上下文子代理×3 并行，原文要点＋裁决）

**A 册·需求符合性**：意图符合性表 6/6 met（含①甄别形偏差「met（已声明，且甄别力成立）」）；「做了没声明」clean（tid 上提为机械必然非行为变更）；1 suggestion（④retired 演练永久盲化套件内共享 actor——已有尾注，后续用例用一次性 actor）；独立最小重放 5/5；未覆盖项＝真仓复核（生成者已另行提供 69→35 证据）。
**B 册·崩溃风险**：clean。13 场景动态验证（tid=None merged 行、v3/v4 并发窗、缓存截断半写降级、跨分片乱序、raw 行逐字过 parse_event、增量路径消费 merged、毒化 v3 自愈等）全过。残余注记：混合部署窗内旧 derive 写回 v3 缓存会反复触发全量重放（性能抖动，正确性无损）。
**C 册·安全**：1 warning W-1——merged handler 为全状态机唯一无 owner 校验且先于 retired 过滤的写状态分支，derive 侧不可验证机械票据。评审者自证缓解：actor 字段系统级无认证，基线即可伪造 done；增量权力仅限「诚实署名的 merged 行」，未突破既有威胁模型。其余 clean（raw 追加点无注入、cache JSON 往返安全、LINE_RE 锚定）。

**裁决表（固定规则）**：
| 来源 | 级别 | 裁决 | 依据 |
|---|---|---|---|
| C-W1 | warning→high | **驳回（设计确认项）** | 任务页契约明文「state 任意→done（终态语义）」；账本＝可信底座为本系统既有模型（actor 自声明，done 的 owner==actor 是语义规则非认证）；写侧 post.sh 票据＋commit==branch HEAD＋merge.sh 即时销毁为主防线。附注：未来 actor 引入真实认证时 merged 分支须一并纳入归属校验——已落知识页 |
| A-1 | suggestion | 记录不修 | 代码尾注已在；后续用例一次性 actor 属未来批次 |
| B 残余 | 注记 | 记录 | 混合部署窗性能抖动，正确性已证 |

**结论：零 blocker/high 残留，循环收敛（R2=终闸轮，修复轮 0）。**

（续写：提交与收口）

（续写）
