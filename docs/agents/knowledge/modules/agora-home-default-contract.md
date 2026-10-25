# AGORA_HOME env 契约：脚本零静默缺省（gt-ca34）

> 2026-10-25；来源任务 gt-ca34（gt-f6e4/gt-3c7e 两层遗漏叠加：改名后 15 脚本裸调用静默读错路径）。

## 契约
- **scripts/ 下一切脚本禁 `AGORA_HOME` 静默缺省**：`${AGORA_HOME:?…}` fail-fast（报错须指名变量＋给显式 `export AGORA_HOME=$HOME/plaza` 指引）。env 注入唯一合法来源＝MCP server（`agora_mcp.py` 自身保留 `~/plaza` 缺省并注入子进程 env——server 面与脚本面分层，勿混淆）。
- **消费方（cron/ skill 模板/跨仓轮询）须显式设 AGORA_HOME**。bg-wait SKILL 模板裸调 `history.sh` 即此教训的活体（fail-fast 后显式报错，不再静默空转）。

## 为什么缺省是坑（两层遗漏机理）
- **缺省值是隐藏消费点**：改名/迁移盘点 grep「读写该路径」抓不到 `${AGORA_HOME:-$HOME/agora}`——它不出现在路径字面量里。盘点模式必须含 `:-\$HOME`、`:-` fallback 形态。server 有缺省掩护了 MCP 面（一切正常），脚本面裸调用全断且**症状是「读 0 事件/空转」非报错**——静默错路径比崩溃贵一个数量级。
- 修 A（删缺省 fail-fast）优于修 B（改新缺省）：B 下次改名再断一遍；A 让缺省依赖在编译期（调用时）显式爆炸。
- 遗留注记：backup/derive-board/report/poll 四文件缺省已是 plaza（cron 显式 env 下为死代码）——同契约未收全的技术债，统一时另派。

## 套件裸调用测试双坑（红先行实证）
- **红相守护型脚本两害**：①init.sh 红相（guard 未加）会在真 `$HOME` 建目录污染真机；②notify-opencode.sh 红相变 inotify 常驻挂死整条套件。对策：套件内裸调用一律 `env -u VAR HOME="$T/sandbox" timeout 10 bash …`——HOME 沙箱接住副作用，timeout 接住守护。
- **翻旧断言先问哲学**：r1 时代断言「history.sh 未导出仍出合法 JSON」编码的正是本次判死的静默缺省合同——评审翻联合同时，grep 断言名里的行为动词（「仍出/仍可」）核对是否编码旧哲学。
