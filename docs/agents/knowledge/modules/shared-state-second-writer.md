# 共享可变状态第二写者契约（gt-8a3c）

> 共享可变文件新增写者时的锁互斥、set -e 副写入吸收、断言按 key 三条硬约束。2026-10-24，gt-8a3c 终闸 B 册双 warning 实证。

## 契约

**① 新增写者 MUST 与既有写者共取同一把锁。**
sessions.map 既有写者 poll 保洁（读全文件→内存过滤→`open(SMAP,"w")` 截断重写），gt-8a3c 在 dispatch.sh 新增第二写者（awk 探查＋`>>` 追加）时未共锁——终闸 B-F1 抓到 lost-update：追加落在 poll「已读/未写回」窗口即被快照覆盖，注册行丢失不可再生，通知静默（恰为本任务要修的症状）在新窗口复发。修法：双方共取 `$AGORA_HOME/.git/sessions.map.lock`（bash `flock -w` 子壳；python `fcntl.flock`），poll 的读-过滤-重写全程持锁。判据：**「写者罕见」不是竞态豁免——poll 重写窗口是毫秒级但周期性出现，任意一次 spawn 完成与之重叠即入窗。**

**② set -euo pipefail 下，尽力而为的副写入 MUST 显式吸收失败。**
register_session 在「spawn 已成功＋dispatched 已落账」之后执行；其 printf 失败（ENOSPC/只读）若沿函数非零返回传播，set -e 在成功主路径终点前杀死脚本——上层按派发失败处理，引发恢复性重复重派（假失败比丢一行路由更贵）。修法：子壳 `|| :`（dispatch.sh register_session）。同文件既有先例：`spawn_died_diag` 均带 `|| true`。判据：**副写入失败只许降级（丢路由行），不许翻转已成功的主事务。**

**③ 对共享可变夹具的测试断言 MUST 按 key 断言，禁全表计数。**
首版断言「注册后 map 恰 2 行」在绿跑即碎（=5）：套件前段其他测试的派生也是合法登记行。共享可变状态的合法内容随系统演进增长，全表计数断言隐含「全库唯我写者」假设。修法：断言本会话 sid 各恰一次＋零整行重复（`sort|uniq -d` 空）。判据：**数行数＝测自己，查 key＝测合同。**

## 附带语义
- poll.sh TTL 时间戳双落兼容：`fromisoformat` 失败→`float` epoch→双失败才 None「存疑不动」；存量裸 epoch 条目自此可回收。`float('nan'/'inf')` 与旧行为（保留）一致，无回归。
- 幂等键恰为 (host,entity,sid)；重派新 sid 自然换绑（桥 awk 取同实体最后一条）。守卫 skip 分支当前无用例可判死（sid 每次随机生成必不同，A-F1 记录）——动该 awk 时需人工构造同 sid 夹具验证。
