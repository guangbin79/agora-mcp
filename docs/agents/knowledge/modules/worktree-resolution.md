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

## 测试模式
- 套件内涉及名册匹配的测试用**独立小广场**（AH4/AH5 模式：mktemp + init.sh + 自建实体），主广场名册会被前段测试的 auto_register 污染（dirs=$T 吞掉一切 $T 下路径）。
- 部署形态注意：MCP server 挂主 repo 代码（install 注册路径），worktree 里的机械层修复在合并+install.sh 刷新前**不生效**——worktree 会话身份仍是旧口径。
