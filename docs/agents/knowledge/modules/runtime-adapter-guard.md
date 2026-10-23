# runtime 适配器调用方三重守卫契约

> 2026-10-23, gt-2b25（通知桥传输层 HTTP→CLI；ocr 评审抓漏实证）

## 契约
1. **凡调用 `scripts/runtime/opencode.sh` 必带三重守卫**：`"${AGORA_RUNTIME:-opencode}" == "opencode" && "${AGORA_RUNTIME_API:-1}" != "0" && -f "$AGORA_HOME/scripts/runtime/opencode.sh"`——适配器头部明文「AGORA_RUNTIME≠opencode 或本文件缺失时调用方整体旁路 API 面（stub/替代 runtime 零扰动）」，守卫是该契约的执行面。参照实现：dispatch.sh:103、post.sh:262、notify-opencode.sh（注入段）。
2. **守卫缺失的代价是静默空转非崩溃**：非默认配置（如 AGORA_RUNTIME=true）下调用方每轮空 spawn `opencode` CLI（rc127 立败，timeout 不挂）＋若调后有水位记录则占去抖/重试频次；`|| :` 类静默兜底会掩盖契约违反——评审时以「grep AGORA_RUNTIME 调用面」为快筛项。
3. **哑 env 哨兵防传输回归**：换传输层后，旧 env（如 AGORA_OPENCODE_URL）在调用方零消费；smoke 断言仍显式设死值（`http://127.0.0.1:1`）并注明「死变量哨兵」——若将来传输回退且重新读该 env，死端口必败、断言必红。措辞禁写「模拟」（env 不起作用，写明哨兵语义）。

## 排障
调用方在 stub 部署下出现 `opencode: No such file` / 意外 api 调用痕迹＝守卫缺失；smoke 用 PATH 注入 fake CLI 时断言意外红＝守卫把真调用挡了（检查 -f 路径与 AGORA_RUNTIME 值）。
