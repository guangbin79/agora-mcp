# 事件落账身份归属（actor-attribution）

> Last updated: 2026-10-22

## Overview
- agora-mcp 事件落账（agora_post）身份解析契约与测试判别纪律；溯源 gt-eefd（评审 Round1 B1/B2/C1 + 终闸三分册实证）
- Key files: `server/agora_mcp.py`（dispatched_child_actor + agora_post 分支）、`scripts/dispatch.sh`（env 注入形状）
- See also: [[review-loop-philosophy]]（dotfiles）

## 契约

### actor 三级解析 (2026-10-22)
- **Chosen:** 显式 actor（调用方）> dispatched_child_actor()（进程 env AGORA_LIVEF/AGORA_PDIR 反查 dispatched 记录取 child，账本权威于派发时点）> 进程级 ACTOR（cwd 裁决）。project 分片随 child 归一，事件行 actor/shard 自洽
- **Reason:** 共享服务进程（opencode serve --service）派生的会话继承服务 cwd，进程级 ACTOR 兜底失真（gt-49fb/gt-eefd 实证）；调用方自觉显式传参不可靠（漏传/撞名）
- **约束:** 反查键=run id（dispatch env 与子会话进程天然绑定），非 task——同任务多派（gt-b12d 双派实证）不歧义；账本读失败/记录残缺一律退化（pdir 现裁决或 None），绝不拖垮 server；账本 child 值须过 valid_entity_name 二次校验（投毒行可用性防御）

### 夹具 env 形状判别纪律 (2026-10-22)
- **Chosen:** 涉及 dispatch env 的测试夹具，env 值必须逐字节对齐生产注入形状（`raw/dispatches/<DID>.log.live`，含 `.log` 中段）；判别断言须构造「账本权威 vs 现裁决」可分叉的夹具（如账本 child 取名册漂移后的名字），只认目标路径的取值
- **Reason:** gt-eefd 评审 B1（critical）：首版夹具写 `<DID>.live`（缺 `.log` 中段），恰好绕开 `[:-5]` 剥后缀差一层的缺陷——169 绿掩护生产路径死代码；首版断言 child 与现裁决同名，兜底退化也绿，零判别力
- **约束:** 绿测不证真，只证「所测路径按预期取值」；mock/夹具形状偏离生产即测试无效，评审须核对注入方源码
