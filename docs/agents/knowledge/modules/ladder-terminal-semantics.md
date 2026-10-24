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
