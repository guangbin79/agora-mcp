# 演练断言窗内事实锚与场景域隔离契约

> 2026-10-24, gt-f8ed（drill 真跑六败两根因：断言窗错配＋场景互相污染）

## 契约
- **断言不得等待超过观测窗的系统性事实。** 看门狗 stalled diagnosed 阈值是分钟级 CRIT（poll.sh 缺省 40min；WARN 20min 仅报表不派生），在秒级演练窗内按设计不可能出现——等待它＝必败断言，且禁为过断言调低看门狗阈值（阈值是生产韧性参数，不是测试旋钮）。修法＝改验窗内可成立的事实锚：poll 真轮次完成＋任务活性时钟已重建（`poll-state.json` `_activity[task].since` 归锚）。
- **poll 的 rc 锚必须辨真轮。** poll.sh `flock -n` 持锁冲突时 skip 也 exit 0（输出 `{"poll":"skip"...}`）——只看退出码则 cron 语境下空转绿，且下游时钟断言读 absent 假红。锚判据＝输出含 `"poll": *"ok"`＋持锁重试（wait_diag 同款 3 次口径）；这也是 kill 场景 `wait_diag` 注释「poll.lock 被cron占用时静默跳过→重试」的普适化。
- **多场景演练夹具必须双域隔离。** 共享 fixture 仓路径时，前场景活子会话触发 dispatch 在场优先降级 notified（真跑 171553：kill 场景子会话挂 `agora-drill` 仓 → quota 复通与 wave 3 派全 notified——初诊"残余配额拒"不准确，wave-*.out 证据修正为在场降级）；共享 actor 令配额分域互染。修法＝每场景独立 actor（`drill-<scen>@agora-drill-<scen>`）＋独立仓＋独立实体页；cleanup 按 "actor task" 对回收。
- **「复通」类正道断言接受合规降级。** spawned 为正道，notified 是在场委托会话的合规通知通道——断言放行但 detail 必须显式记录降级原因（"合规降级 notified：目标仓在场委托会话走通知通道"），禁静默混淆 rc 与 mode 两层。
- **红绿对判别力自查。** 桩 runtime 下旧断言（滞留诊断）可被 stale-live 路径代偿而恒绿——断言更名改锚时须以旧代码红跑证实判别力（gt-f8ed 红1=541/1、红2=541/2、绿=543/0）。
