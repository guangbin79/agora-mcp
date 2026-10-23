# smoke teardown 孤儿竞态与探针匹配面

> 2026-10-23, gt-2153（B批多仓测试场；gt-ef79 时代 40+ 起同型「夹具删而子会话活」事故收口）

## 契约
1. **teardown 前对 `raw/dispatches/*.live` 有界轮询（清空或超时）再 rm**——dispatch 的验证窗语义是「窗尽仍活=过」（长任务合法）：dispatch.sh 返回≠子会话退场。派发体是 `setsid` 脱离进程，夹具 `rm -rf` 后它仍持 cwd/日志路径跑完，即孤儿。修法只有轮询（`for+sleep 1`，上限 20s），不改夹具目录结构、不动 dispatch/poll 主逻辑。
2. **孤儿探针匹配面＝实例唯一路径，禁按 task id/标题全机 pgrep**——`pgrep -f "agora: gt-xxxx"` 按命令行全机匹配；smoke 常多实例并发（实证一轮评审期间 ≥5 实例），4-hex task id 撞名即假红。探针应 match 本实例 stub 的 mktemp 路径（`$T/bsleeprt`，随机段唯一）；wrapper `bash -c` 的 argv 只含未展开变量名字面量，不会误命中。
3. **竞态用例要先让窗口现形**——断言「dispatch 返回后 .live 仍在＋子进程活」需要 stub 活得比验证窗久（sleep 4s vs `AGORA_VERIFY_WIN=1`）；先证窗存在，再证轮询清零，否则修复断言空转假绿。
4. **stale `.live` 夹具用完即清**——滞留标记（touch -d 旧时戳）是刻意的死标记，不 rm 会让 teardown 轮询空等满上限；每个 stale 夹具段末补一行 `rm -f`。

## 排障
teardown 慢（±20s）＝有 .live 滞留未清，先查 stale 夹具与未收口的真子进程；⑦ 段偶发红而单跑绿＝并发实例探针撞名，查匹配面是否含全局唯一 token。
