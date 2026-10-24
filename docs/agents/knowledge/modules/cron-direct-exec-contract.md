# cron 直执接线双合同

> 2026-10-24, gt-5f59（T5 cron 三改接线，实弹射击两连抓）

## 结论
凡写 cron/定时任务直执（无 `bash` 前缀）脚本，两个隐含合同必须显式验收：
1. **执行位合同**：目标脚本 git mode 必须 100755——执行位不在 diff 内容里可见，遗漏（如 drill.sh 曾 100644）表现为运行期 exit 126 Permission denied，周六无人值守任务可潜伏数周。
2. **CLI 形态合同**：cron 行命令必须按脚本 usage 实测，禁照抄任务页/计划文本的字面速记（`drill.sh all` vs 实 CLI `--scenario all`）——快照型文本是高速腐化物，验收 verify/grep 与 CLI 逐字对齐，否则机械闸拦正确修复、放行错误实现。

## 逐字证据
- `setsid: failed to execute /home/guangbin/agora-mcp/scripts/runtime/drill.sh: Permission denied`＋`drill_exit=126`（cron.log 2026-10-24T17:03:35）
- `usage: drill.sh --scenario <restart|kill|quota|wave|all>`＋`drill_exit=2`（cron.log 2026-10-24T17:04:29）
- `git ls-files -s scripts/runtime/drill.sh` → `100644`（修复前），report.sh/opencode.sh 均 `100755`
- tests/smoke-test.sh DDRILL：`bash "$PKG/scripts/runtime/drill.sh" "$@"`，调用形如 `DDRILL --scenario bogus`

## 验收手法
接线完成后立即实弹射击一次：`systemd-run --user --quiet --unit=X bash -c '<cron 同款命令; echo exit=$?>>log'`（atd 缺失时的等价脱附手法，独立 cgroup），exit code 落日志为证。
