# 配额保险丝原子性：检查-落账 TOCTOU 与锁内复核

> 2026-10-24, gt-2e4f（并发九派风暴；同域依赖 gt-8c5b 分域双闸口径）

## 契约
1. **配额检查与 dispatched 落账必须同锁原子**——账本扫描（含 .live 计数）在锁外读、事件在 post.lock 内落，两段之间无因果：九路零错峰风暴下全员读到落账前状态，MAX_SPAWN=3 实测 9/9 全放行（应为 3/6）。修法＝落账前取 `dispatch.lock`（`$AGORA_HOME/.git/dispatch.lock`，fd8）后重扫账本再落账，落账即 `exec 8>&-` 放锁——锁只罩「复核＋落账」，不罩 spawn 验证窗（否则慢子会话阻塞全场派发）。锁序单向 dispatch.lock→post.lock（post.sh 内层），无反向获取者，无死锁面。
2. **锁内复核 fail-closed**——扫描空输出若放行＝退化回 `.live` 计数（风暴期恒 0），恰好复辟被修的 TOCTOU：`_LS2=$(ledger_scan || true)`＋空判 `fail QUOTA_SCAN rc3`（`|| true` 必须在——裸 `$()` 非零会被 `set -e` 先杀，JSON 错误契约到不了）。复核调用现成 `quota_check`（分域＋总量双闸），不复制闸逻辑。
3. **风暴断言的确定性来自串行化而非错峰**——「恰 3 spawned、6 QUOTA_EXCEEDED」只有在检查-落账原子后才是确定性结论；测试侧零错峰 `&`＋`wait`、stdout/stderr/rc 分文件收、被拒断言 JSON `code` 字段与 rc 多重集。被拒者零落账零 log 零 `.live`（QUOTA 前置拒绝发生在 DID 赋值前，天然零残留）。
4. **槽位释放语义用账本口径测**——stub 子会话秒退不产生终态事件，账本活跃数不降：done 前重派第 7 个必拒（零 .live 也计数），done 出集后同任务放行。这条反向断言同时守 v1.32 账本化配额语义。

## 排障
风暴全放行＝复核没进锁或锁没罩住落账；偶发 QUOTA_LOCK（rc3）＝临界区内网络 IO 过长（远端 sync 嵌在 post.sh 段），默认 `AGORA_LOCK_WAIT:-5` 偏紧，属可重试非缺陷；夹具跑风暴前确认套件级 `AGORA_MAX_SPAWN_GLOBAL` 抬高（长跑累积活跃防误触总量闸）。
