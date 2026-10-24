# 看板泳道成员资格口径（看门狗泳道跟踪契约）

> 2026-10-24, gt-ef98（blocked 泳道滞留档评审轮 ocr high 现形）

## 契约
- poll 的按任务泳道派生旗标（inblocked/done_open/inflight 等）是**派生态**，其复位判据必须与 derive-board 看板状态机（渲染唯一真源）逐字对齐；自行加宽复位集＝看板仍渲染该泳道而看门狗已清跟踪——任务失看护。gt-ef98 初版以 claimed/progress/dispatched 清 inblocked，而 claimed 自 blocked 是看板 no-op（仅 todo 可认领）、progress 只记心跳、dispatched 不改看板态 → 心跳一次后失联即复盲（恰为该任务要修的盲区）。
- 瞬时活性与泳道成员资格是两层：任意新事件已经指纹时钟（last_ref）归零复位，活性判断不需要复位集代劳；只有真正改变看板状态的事件（done/merged/cancelled/reopened/retired）才有资格清成员旗标。
- 出泳道集真源＝derive-board `apply()` 各分支；新增看板态或改分支时，须同步 grep 本文件与 poll/lib 的消费点（inblocked 消费在 poll.sh ②g，重放在 agora_lib.scan_tasks——单一真源，禁第二实现）。
- 流程侧：dispatcher 评审中途 rebase（scan_tasks 下沉 agora_lib）后，评审发现须对迁移后位置重裁决——逻辑迁移不使发现失效，修复落点跟新真源走。
