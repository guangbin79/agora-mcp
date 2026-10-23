# smoke 账本夹具契约（doctor/配额/对账三闸）

> 2026-10-23, gt-abcd（督报批夹具两轮假红实证；21 失败同根两因）

## 契约
1. **seq 按 (分片, actor) 从 1 连续**——doctor seq 对账判据 `sorted(seq)==range(1,N+1)`，手工夹具行全局编号（9001+）必红。既有词边界夹具 seq:901 之绿是位置侥幸（落在 doctor 段之后），不是规则例外。
0a. **夹具 task id 必须 hex**——账本消费方一律有 `gt-[0-9a-f]+` 任务门（poll 扫描/统计/深度链），非 hex id（如 gt-nul1）被静默过滤，靶点断言假绿、靶点缺陷漏验（gt-abcd 轮 3 实证：NUL run 崩溃修复首测假绿）。
2. **dispatched 夹具必须收终态**——spawn 配额是账本全局口径：`活跃＝dispatched∩无终态∩非僵尸 ≤ MAX_SPAWN(3)`。夹具留 N 个无终态 dispatched＝占满后续全部 spawn 断言（一次连锁 19 败，全看似与夹具无关）。补 `cancelled`（非 done，防污染 done/merged 统计）。
3. **夹具落位先于 doctor 段即入对账窗**——seq/idem/board 对账在 doctor.sh 扫全部 log 分片；新增夹具批要么满足判据，要么放在最后一个 doctor 断言之后。

## 排障
套件大面积失败先 grep 失败段公共前置（QUOTA/seq 断档行），夹具污染的特征是「失败集中在夹具之后的首个消费方」。
