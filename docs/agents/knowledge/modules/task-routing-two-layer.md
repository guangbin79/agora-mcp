# task-routing 两层路由契约

> 2026-10-25, gt-236a（2508 done 投错会话实证；两层路由取代纯广播）

## 契约
1. **精准层单点、兜底层广播、失败逐级下落**：task-routing (task,role)→sid 命中且 who=live→只投该 sid（kind=R，不广播——2508「多会话竞争投错」根因消灭）；缺行/白名单拒/dead/delegated/inject rc!=0→逐级落兜底广播同实体全部 ts 新鲜活行（kind=F，双收）。精准成功禁再广播——恰一次语义。
2. **采集=hook 自报，写入单源 task-routing.sh**：dispatcher 行三采集点（dispatch 准入分支 input.task、task_create execute.after 输出 gt-id、agora_post 事件方向表）；worker 行=dispatch.sh spawn 顺带＋post 方向表。事件方向表同源两处（notify 桥常量＋enforcer POST_DIRECTION）：ack/amended/reopened→dispatcher，claimed/plan/progress/done/blocked/cancelled/escalated/diagnosed→worker。post 方向表即「谁消费谁接管」自动化——TUI 重开首个 post 刷新 routing，无需 check_mail 观测。
3. **角色订阅只滤兜底层**：sessions.map 第 5 列 role（--role 写入，upsert 覆写/缺省保留）；worker 行仅派发/修正类（dispatched/ack/amended/reopened），dispatcher 行仅终态/计划类（claimed/plan/done/blocked/cancelled/diagnosed/escalated/proposal），无 role legacy 行全收＝现状不劣化；progress 全层零注入（心跳落箱不推醒）。角色映射表常量单源=notify-opencode.sh 文件头。
4. **去抖与活性按 (entity,sid) 粒度**：精准 sid 失败不堵兜底行；桥侧 TTL 活性闸（AGORA_SESSION_TTL_H 同源）＋who 鉴别＋poll 保洁三层。同名变量夹具撞车课：smoke 全局 P/REG 早被占用，测试局部赋值污染后续段——新夹具变量须 grep 全文件查重。

## 边界
- hook 采集依赖 enforcer 运行（headless 直调/他 harness 不采集→fallback 覆盖不劣化）；session.deleted 退出注销 best-effort（SIGKILL 形态 TTL 兜底）；routing 行 sid 为 hook 自报，伪造面同 sessions.map（消费端白名单＋who 双闸）。
- 退出注销/活性刷新基建复用 gt-6fa8（f693786/fe108cc）；注入鉴别/落痕/计数语义沿用 gt-893a 契约（notify-bridge-target-selection 页）。
