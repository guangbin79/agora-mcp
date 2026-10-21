# worktree 路径→实体解析（gt-ac14）

## 决策
- worktree 归一唯一口径 = `scripts/agora_lib.py` 的 `resolve_entity`（直判最深前缀优先 → `main_repo_of` 归一兜底），三消费方统一引用：dispatch 子身份/PROJNAME、server adjudicate、who here。沿 v1.26「解析收口唯一真源」先例。
- `main_repo_of` 语义：自 p 逐级向上找最近 `.git`——目录=普通 repo 即停返 None；文件且 gitdir 指向 `<main>/.git/worktrees/<name>` 且 `<main>/.git` isdir 在场才归一（校验 worktrees 段名 + 主 repo 在场，堵 absorbed submodule 误判与捏造/逃逸 gitdir）。
- worktree cwd 不 auto_register（归属主 repo 实体；主 repo 未注册保持匿名）——否则每个 worktree 刷一个易逝实体页。
- who 的 here：直判 `covers(CWD,d)` 优先、归一 `covers(cw,d)` 兜底——dirs 登记 worktree 路径本身时直判必须仍生效（终闸 ocr finding）。
- worktree 生命周期（建/清/合并）归调用者，机械层零 git 写操作。

## Bug 教训
- **闭包变量误用**：`match(root)` 体内误用外层 `target`，单点 sanity 只测 `main_repo_of` 未覆盖 `resolve_entity` 全链 → 归一静默失效。教训：闭包回调体内禁止引用同名语义的外层变量；sanity 探针必须打全链入口。
- **测试 server RPC 漏传 env**：`agora_mcp.py` 读 `AGORA_HOME` 环境变量而非 argv；Popen 漏传 env 会连**真广场**并 auto_register 污染（两次事故，均 git rm 清理）。教训：测试内嵌 server 一律 `env={**os.environ, "AGORA_HOME": ...}` 显式传。

## v1.30 批增补（gt-b0de）
- **project 裁决归一**：agora_post 匿名 fallback 的 project 过 `main_repo_of`——resolve_entity 口径的第四消费方；who 的 cw hoist 出实体循环。
- **plan-gate 软门设计**：派生会话动手前 post(plan)（body=验收标准+实施步骤+影响面），post.sh 在 done|plan 自动 @任务页 dispatcher——**ack 回路由机制保证，不靠文案**；30min 超时自放行防死锁。不做宿主插件/skill（无插件原则：协议域机制走 BOOT+账本，跨运行时恒可用；BOOT 必达优于 skill 的靠自觉）。与宿主 req-gate 恰好配合：req-gate 挡「没想清楚就动手」，plan-gate 挡「方向没对齐」，req-gate 产物可直接粘贴为 plan body。
- **教训：测试短路**——断言场景 ACTOR 恒非 None，fallback 分支从未执行（ocr 探针发现）。写分支测试先问「这个分支在夹具下真的会走到吗」。
- **教训：ack 回路断裂**——引导文案只说「post 计划」没说通知谁，dispatcher 收件箱永远看不到，软门退化为固定延迟。凡协议依赖「对方看到」，必须有机制化的到达路径（mention→inbox），文案指示不算数。

## 测试模式
- 套件内涉及名册匹配的测试用**独立小广场**（AH4/AH5 模式：mktemp + init.sh + 自建实体），主广场名册会被前段测试的 auto_register 污染（dirs=$T 吞掉一切 $T 下路径）。
- 部署形态注意：MCP server 挂主 repo 代码（install 注册路径），worktree 里的机械层修复在合并+install.sh 刷新前**不生效**——worktree 会话身份仍是旧口径。
