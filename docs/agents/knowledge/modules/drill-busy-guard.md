# drill 忙碌守卫三课（gt-ef4c）

> Last updated: 2026-10-24

## 契约
- drill.sh 忙碌让行守卫＝无人值守演练的安全阀：scan 失败 fail-closed 让行（rc2＋报告 skipped），禁 fail-open 盲扰。
- 在飞波次口径＝**尾事件 dispatched**（`scan_tasks().last == "dispatched"`），有意窄于 poll 的 `inflight`；新代码与广场 scripts 拷贝的版本差经「lib 取 drill 同包路径」（`dirname $0/../`）闭合。

## 判据与实证
- **版本配套**：脚本读 `AGORA_HOME/scripts/agora_lib`，而新脚本由包路径调用——广场拷贝滞后（旧 lib 无新函数）时 import 崩溃。fail-open 写法（`|| busy=""`）会让守卫静默失效变盲扰；fail-closed 让守卫崩溃＝让行。实证：真实广场首跑 traceback 后仍 rc0 放行。
- **口径窄化**：`inflight` 把 done-unmerged 合并积压永久计入在飞（状态机里 done 不闭飞，merged/cancelled 才闭）——真实广场 22 个积压任务会让 weekly drill 永久让行失效（演练静默死亡比扰动更危险）。尾事件口径只挡「子会话刚派出无后续」的真波次；积压由 done-unmerged 梯子自行收敛。
- **报告面与账本面分离**：报告 JSON 落本地 state（`~/.local/state/agora-drill/`），账本只经 post/dispatch/cancel 真实通道——演练流量与伪造事件的边界。

## 约束
- 改 scan_tasks 状态机（agora_lib 单点）须同步核对 drill 守卫口径注释与 poll 语义的差异是否仍成立。
- 演练实体（`drill@agora-drill`，can_spawn）首跑自举进真广场；巡检视野含其页与 agora-drill 分片。
- 已知上报项（gt-ef4c 评审轮 1）：restart 场景恢复重派 leg 缺失（F1）；MY_PID 排除契约默认路径无消费者（B①，归 T5）。
