---
owner: agora-mcp
created: 2026-10-26
---
# 非 wt 出票锚点与目标契约（nontwt-ticket-anchor）

## 出票目标恒取默认分支，禁取检出 HEAD（gt-762a 跨任务错乱根因）
- 非 wt 闭环（页无 wt_dir）无树操作只做「已含→补票」；共享检出 HEAD 随 worker verify 窗口 checkout 漂移，把「当前检出」当目标＝票面把任务分支记成合并目标（实证：六连票全记 branch:gt-762a-alive-running、gt-762a 票记 branch:gt-236a-two-layer-routing）。
- 探针序 origin/HEAD→init.defaultBranch→main→master（gt-e5cc R1-ocr）：origin/HEAD 是克隆时记录的仓库事实（读 refs/remotes/origin/HEAD，与检出状态无关），host/global init.defaultBranch 与 main/master 启发在后；origin/HEAD 缺失或具名分支不存在时逐级回落。main↔master 迁移窗口双支并存时配置启发会绑错目标。
## done 锚点提取三闸（merge.sh 非 wt 路径）
- 点分片双态 glob：GNU find -name 本已匹配点文件（4.8.0 实测）——gt-3ea2/gt-6fef 的点分片盲在 python glob/bash glob 层，勿再误诊 find；双态为跨 find 实现保险。
- 多 done 取行内 `ts:` 最大者（分片路径字典序≠事件序）；全部无 ts 回落末行（兼容前 ts 代账本/外来分片）；shortcut: ts 字典序跨时区偏移不可比，现全分片同偏移。
- commit 复合值（repo@branch:hex,…）取字段值内（下一 | 截断防跨字段误赎回）全部 7+ hex run 为候选，逐个验 merge-base --is-ancestor，首个在默认分支者胜——单候提取对分支名段含 hex（wt-…-10222158 命名实态）误取致假阴性复发。分类单一归属：零候选 VALIDATION_FAILED（末条垃圾不回退旧锚）、有候选全落空 NOT_IN_TARGET；禁设早门（双 fail 位漂移＝死代码，ocr-1）。
## 轮询陷阱：history 权威序≠时间序
- agora_history 事件数组按权威序排（dispatcher ack 可在头部）——轮询必须全数组扫描找 event:ack，slice(-N) 尾部采样会漏 ack 假自放行（gt-e5cc 实证，幸实现与 ack 零偏差）。
