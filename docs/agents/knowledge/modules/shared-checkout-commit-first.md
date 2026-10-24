---
owner: agora-mcp
created: 2026-10-24
---
# 共享主检出写入纪律（shared-checkout-commit-first）

## 并行 merge 冲掉未提交脏改动（Bug，2026-10-24 gt-edc4 评审轮实证）
- 症状：edit 三次报成功、git status 干净、改动消失——另一会话 merge.sh/checkout 在主检出落操作，未提交脏文件被无声还原。
- 纪律：主检出（agora-mcp MCP server 运行区）**写后立即 commit**，禁止让修复以脏态存活超过一次工具往返；验证用 grep 而非信任工具返回值。

## bash -c 隐式 exec 优化坑（Bug，gt-edc4 探针夹具两次假红）
- `bash -c '单命令' name`：bash 对简单命令做 exec 优化，进程镜像被替换、cmdline 丢失 `$0`（name）——pgrep -f 按模式串探测必落空。
- 修法：`; exit` 复合命令禁用优化，cmdline 保全 `bash -c ... name`。凡「以 cmdline 内容为探测面」的夹具（pgrep/pkill/ps 断言）均适用。
