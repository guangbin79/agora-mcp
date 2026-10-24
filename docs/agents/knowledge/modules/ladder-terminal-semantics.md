# ladder-terminal-semantics

> 梯子的真值分层与夹具形态契约。来源：gt-99af（终态核查棒＋git 层已合并短路＋S4 夹具语义适配）。

## 结论
- 梯子判值有三层：看板（derive-board 派生视图，可滞后——merged 事件根本不入状态机）→ 账本（scan_tasks 重放：`d["terminal"]` 旗标，merged/cancelled 置位、reopened 清位）→ git 层（wt/<t> 引用是否为 project_dir HEAD 祖先）。越靠后越接近真相，高层只作快筛不作结论。
- mention 拾取只信账本终态旗标，不信看板；字面 `has∩{merged,cancelled}` 是错的——reopened 返工流（终态→reopened→todo）会被误杀。
- done-unmerged 提醒前先查 git 层：产出已实际并入（引用存在且为 HEAD 祖先）＝簿记滞后，安静收场；无引用/不可判定必须照常响（防树外产出被吞）——短路判据 fail-open 朝警报方向。
- 夹具必须造真形态：done-unmerged 路径的夹具若借「分支==HEAD（已并形态）」偷懒，任何新增 git 层守卫都会把它静默吞掉且测试全灭（S4a-d 实证 6 断言红）。夹具态＝生产态，逐字对齐。

## 逐字证据
- derive-board `apply()` 的 merged 分支曾缺失（merged 落账后任务留 todo 原位）——即「账本终态＋看板滞后」的历史常态窗口；gt-5a59 已补 merged handler（机械终态先于 retired 过滤）＋缓存 v3→v4 全量补账，滞后窗仅剩 raw 落账形态（smoke ⑥b-lag 锚）。
- 短路判据（poll.sh ②c）：`refs/heads/wt/<t>` 或 `refs/remotes/origin/wt/<t>` 存在且 `merge-base --is-ancestor <sha> HEAD` → `mw.pop`＋`report["merge_lagged"]`；`os.path.isdir(project_dir)` 不成立时跳过检查（不短路）。
- S4 夹具改造前后对照：夹具无树内提交 → `merge_lagged: [T4D…]`、redispatched 空（6 断言红）；树内产提交后 redispatched 恢复 injected/spawned（304/0 绿）。

## 非 wt 闭环语义与 actor 链闸（gt-7117 实装；B-1/C-1 评审环 R1 收口 gt-e0a4）

### 结论
- 页无 wt_dir＝直改仓任务的终态闭合走无树操作出票补账：merge.sh 从账本提最新 done commit → 主仓默认分支 `merge-base --is-ancestor` → 机械票出票补 merged（done_open 清零）。verify 背书＝done 时 post.sh 机械 verify 锚 project_dir 真跑，等价 wt 幂等路径「已含→只补账不重验」。
- actor 链闸（C-1，fail-closed）：非 wt 路径无真实 git ref 锚，账本 done 行可被任意 actor 写——claimed→done actor 链＝「锚制品仅派发链可造」的替代闸。校验序固定：done commit 在账本（缺→VALIDATION_FAILED）→ 首个 claimed 事件在场（缺→VALIDATION_FAILED，拒绝无认领链闭环）→ 最新 done actor==首个 claimed actor（异→DONE_ACTOR_MISMATCH exit 4）；caller 身份不校验，dispatcher 代 merge 不受影响。
- 账本检索一律 T1 硬化（B-1）：`find -print0 | sort -z | xargs -0 -r cat`（merge.sh LEDCAT 封装）——裸 `cat $(find ...)` 在 find 空结果时吞调用方 stdin/挂起（/tmp 实测复现；新块系 post.sh 同款回归性复制）。
- 残余（记录不修）：v0 无鉴权，actor 名可冒注——本闸防 confused-deputy/buggy agent，非恶意鉴权绕过；闸后无 claimed 历史任务再调 merge.sh 由幂等 dedup 变显式拒 VALIDATION_FAILED——账本真值不变，操作面 wrinkle。

### 逐字证据
- 校验序锚点（merge.sh 非 wt 块）：`[ -n "$DONEC" ] || fail VALIDATION_FAILED` → `[ -n "$CLAIMA" ] || fail VALIDATION_FAILED "…无认领链拒，fail-closed"` → `[ "$DONEA" = "$CLAIMA" ] || fail DONE_ACTOR_MISMATCH … 4`。
- 结构字段双侧定界锚（R1 评审 ocr/B-F2/C-F1＋R2 评审 ocr-F1/F2/F3 收口）：event 提取 `[|] event:done( |$)`／`[|] event:claimed( |$)`；actor 提取 `sed 's/.*[|] actor:\([^ |]*\) [|].*/\1/p'` 双侧结构锚（值禁 `|`，「| actor:x |」字面序自由文本不可得；右锚单侧不够——后续字段会供给「 |」）；commit awk `[|] commit:`（＋9 offset，对齐同块 task 锚先例）。DONEC/DONEA 同源 LASTDONE 单行快照（末条 done 垃圾 commit→干净 VALIDATION_FAILED，不回退旧锚）；CLAIMA 与 DONE 行提取共用 TASKL 单读快照；`LC_ALL=C sort -z` 钉分片序。
- claimed 提取仿 post.sh claim_conflict 模式（head -1 取首个）再加硬（字段定界锚）——post.sh:316 原文无锚，属未改面。
- 红绿三对（smoke ⑧d＋⑧e）：红 496/2（⑧d 无 claimed 拒＋冒领 done 拒）→绿 498/0；红 498/2（⑧e 伪造 claimed 不放行＋evidence 引 actor 不假拒）→绿 500/0；红 500/2（⑧e 补：非行尾伪造 actor 不放行＋末条垃圾 commit 不回退旧锚）→绿 502/0。⑧b 夹具随闸补 claimed（夹具态＝生产态）。
- 残余（记录不修）：v0 无鉴权，actor 名可冒注——本闸防 confused-deputy/buggy agent，非恶意鉴权绕过；闸后无 claimed 历史任务再调 merge.sh 由幂等 dedup 变显式拒 VALIDATION_FAILED——账本真值不变，操作面 wrinkle。「首个 claimed」谓词边界：reopen→再 claim 合法迁移会被 DONE_ACTOR_MISMATCH 假拒（改「live/末 claim」谓词＝需求决策，超执行侧边界，转 dispatcher）；同日跨分片文件序≠ts 序（LC_ALL=C 钉确定性非时序性，ts 序时序化留专项）；闸验 claimed 并存不验先于 done（late-claim 补账可过闸，流程严格性超出 v0 合同谓词）；wt 路径 UP 检索（merge.sh 约:70）与 post.sh:316 同款未锚提取在场，归 dispatcher 另环处置。
