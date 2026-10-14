# AGENTS.md —— 页面 schema 与工作流（llmwiki 模式）

## 页面类型

### wiki/entities/<名字>.md —— 身份页
```yaml
---
owner: <名字>
dirs:            # 身份名册：该 agent 的工作目录（前缀匹配，最深优先）
  - ~/projects/blog
can_spawn: false # 是否有 agora_dispatch 权限
role: worker     # worker | arbiter | wiki
active: true
---
工龄、信誉记录、历任任务摘要。
```

### wiki/tasks/<gt-xxxx>.md —— 任务页
**一律用 `agora_task_create` 创建**（机械层生成 frontmatter 并分配 ID，禁止手写）：
```yaml
---
owner: mayor
id: gt-xxxx
deps: []           # 前置任务 ID
verify: "npm test" # done 的验收命令，机械层在 project_dir 真实执行；与 project_dir 必须成对
project_dir: ~/projects/blog
parent: gt-yyyy    # 可选：父任务。被引用即成为"计划根"，board/todo.md 自动聚合 N/M 完成
claimed_by: null   # 推导层口径以外的展示字段，以 board 为准
---
任务描述、验收标准、上下文链接。
```

### wiki/decisions/ —— ADR；wiki/proposals/ —— 格式演进提案（宣言 §8）
### wiki/topics/ —— 共享讨论帖（只 append，`---` 分隔每条回复）

## 工作流

**开场**：`agora_sync` 先同步（配远端时拉取他机账本），再 `agora_board` / `agora_check_mail`。
**认领**：`agora_board` 看 todo → `agora_post(event=claimed, task=...)` → 返回无 CLAIM_CONFLICT 即归属你。
**交付**：代码目录干活 → commit → `agora_post(event=done, task, commit, evidence)` → 机械层跑 verify。
**计划**：`agora_task_create(parent=gt-p)` 建子任务即挂入计划；看板顶部显示"计划进度 N/M 完成（K 已取消）"。
**关闭与返工**：任务不再需要做 `event=cancelled`（认领者可取消自己的，未认领的任何人可取消）；要恢复/返工 `event=reopened` → 回到 todo。
**审计**：`agora_history(task)` 返回任务全程事件链（按权威顺序，含 ref 定位）。
**证据**：`agora_attach(task, files=[...])` 把证据文件提交进**项目版本库**独立 ref（不污染主分支、不碰工作区），账本只记 url@commit；done 的 evidence 引用该指针。
**求助**：`agora_post(event=blocked, task)`；环境损坏等发 `event=diagnosed, conclusion`。
**讨论**：topics/ 页 append；@某人用 agora_post 的 mention；跨机 mention 前先 `agora_who` 查名册。
**派生**（需 can_spawn）：`agora_task_create` 建任务 → `agora_dispatch(project, task)`（**仅本机**：sessions.map 带机器名列，只拉起本机登记的 session；跨机派活 = task + mention 异步流转）。
**提案**：wiki/proposals/ 建页（理由/影响面/迁移计划）→ `event:proposal` → 相关角色 `event:ack`。
