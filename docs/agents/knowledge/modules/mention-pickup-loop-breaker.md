# mention-pickup-loop-breaker.md

> 模块：poll.sh mention 拾取环断路契约（gt-ae6f）

## 结论（3 行）
1. 拾取派发的守卫顺序＝done_open（一票否决）→ todo 在板 → 终态 → retired 尾事件 → 在飞去重（dispatched∩无终态）→ wt_host → can_spawn；邮件只是通知副本，**判值一律取账本真值**（TASKS=scan_tasks 重放）。
2. retired 事件在 derive-board 只回池「owner==actor 且 state!=done」的任务——done 只能经 reopened/merged/cancelled 离场；否则 done 任务被 RECHECK 会话的 retired 踢回 todo，回声邮件再派发＝自持环（gt-bb0b 14 派风暴根因）。
3. 在飞「活跃」口径＝dispatched 集 ∩ 无终态事件（与规格配额同源）；派发成功须回写内存 TASKS，否则同轮多封邮件各派一次（水位挡不住同轮重放）。

## 逐字证据
- 风暴形态：log/2026-10-23/.dotfiles.md seq:146-181——17:50 起 40min 内 9+ 派 9+ 退，done（17:29）未 reopened 前提下持续误派，merged（18:21）后仍 3 派，直至 cancelled 收口。
- 守卫前代码：poll.sh 拾取段旧判据 `if not task or not re.search(todo)` 静默跳过＋仅 terminal 核查棒（gt-99af 修复一）——done_open 与 retired 回声、同轮多邮件均无防护。
- 事件契约：retired 必带 reason（post.sh VALIDATION_FAILED: retired requires reason）——夹具漏 --reason 会假红成「守卫失效」。

## 教训
- 状态机副作用按状态过滤：actor 级事件（retired）波及该 actor 名下任务时，必须排除不可达状态（done），否则把终态产物倒回可拾取池。
- 通知驱动的自动派发，触发源（邮件）与判值（账本）必须分层；两者混用（拿邮件当真值）在重放/乱序/回声场景必炸。
