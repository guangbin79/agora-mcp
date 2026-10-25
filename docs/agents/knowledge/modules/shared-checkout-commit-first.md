---
owner: agora-mcp
created: 2026-10-24
---
# 共享主检出写入纪律（shared-checkout-commit-first）

## 未提交脏态被并发 worker 携带卷提交（Bug，2026-10-26 gt-e5cc 评审环实证）
- 症状变体：脏态不只被「冲掉」，还会被携带——他 worker 在共享检出 `checkout` 建支（同基）时未提交改动无损跟过去，其 `commit -am` 把我的 hunk 卷进他的提交（7ff2e44 混装 gt-7cd9 drill＋我的 smoke 夹具），我随后 `git add <文件> && commit` 把剩余增量落在他的分支上（cd1d6c5 错支）。
- 处置：不动在飞 worker——临时 worktree 内 cherry-pick＋手稿重放自有 hunk，分支独立重构；两支同内容 hunk 在并主时经 rebase 丢弃重复补丁后即无残留（直接 ff 第二支会因分叉被拒，家规 rebase＋ff-only 恰好覆盖）。
- 纪律强化：「写后立即 commit」的失败模式是双态（被冲掉/被卷走），脏态存活超过一次工具往返两种都可能发生；评审环跑长验证（smoke 数分钟）前先提交。

## 并行 merge 冲掉未提交脏改动（Bug，2026-10-24 gt-edc4 评审轮实证）
- 症状：edit 三次报成功、git status 干净、改动消失——另一会话 merge.sh/checkout 在主检出落操作，未提交脏文件被无声还原。
- 纪律：主检出（agora-mcp MCP server 运行区）**写后立即 commit**，禁止让修复以脏态存活超过一次工具往返；验证用 grep 而非信任工具返回值。

## bash -c 隐式 exec 优化坑（Bug，gt-edc4 探针夹具两次假红）
- `bash -c '单命令' name`：bash 对简单命令做 exec 优化，进程镜像被替换、cmdline 丢失 `$0`（name）——pgrep -f 按模式串探测必落空。
- 修法：`; exit` 复合命令禁用优化，cmdline 保全 `bash -c ... name`。凡「以 cmdline 内容为探测面」的夹具（pgrep/pkill/ps 断言）均适用。
