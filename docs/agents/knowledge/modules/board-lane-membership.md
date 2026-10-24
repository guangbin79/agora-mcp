# 看板泳道成员资格口径（看门狗泳道跟踪契约）

> 2026-10-24, gt-ef98（blocked 泳道滞留档评审轮 ocr high 现形）

## 契约
- poll 的按任务泳道派生旗标（inblocked/done_open/inflight 等）是**派生态**，其复位判据必须与「任务是否真 closed/reopen」对齐，不得自行加宽；自行加宽复位集＝看板仍渲染该泳道而看门狗已清跟踪——任务失看护。gt-ef98 初版以 claimed/progress/dispatched 清 inblocked，而 claimed 自 blocked 不改泳道（同 actor 看板 no-op，他 actor 记 conflicts 行亦不改成员资格）、progress 只记心跳、dispatched 不改看板态 → 心跳一次后失联即复盲（恰为该任务要修的盲区）。
- 出泳道集真源分两层：看板状态机分支（derive-board `apply()`：done/cancelled/reopened/retired）＋**账本终态 merged**——apply() 对 merged 无分支（看板滞后渲染，poll.sh 「看板是派生视图可滞后」在案），merged 停跟踪依据是账本闭铃语义（_RANK/terminal）而非看板分支；瞬时活性（指纹时钟归零）与成员资格是两层，任意新事件归零时钟，复位集只收真闭铃/回池事件。
- 消费点与真源位置：inblocked 消费在 poll.sh ②g，重放真源在 agora_lib.scan_tasks（单一真源，禁第二实现）；derive-board 新增看板态或改分支时，同步 grep 本文件与消费点。
- 流程侧：dispatcher 评审中途 rebase（scan_tasks 下沉 agora_lib）后，评审发现须对迁移后位置重裁决——逻辑迁移不使发现失效，修复落点跟新真源走。
