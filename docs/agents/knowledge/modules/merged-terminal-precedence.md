# merged-terminal-precedence

> derive 状态机的 merged 终态契约与缓存迁移语义。来源：gt-5a59（merged handler 缺失致 todo 永驻 65 条实证；retired 盲化为验收期发现的第二根因）。

## 结论
- derive-board `apply()` 事件表必须有 merged 分支：state 任意→done（机械真值＝工作已落目标分支；owner 同 done 惯例不动）。merged 缺席时，被 reopened 拖回 todo 的任务在 sweep 补账后永驻 todo，且连 claimed/done 都可能不可见。
- merged 分支必须置于 `if actor in retired: return` 之前：merged 是 merge.sh 机械票背书的簿记终态，非 actor 的任务主张。retired 过滤先于事件表会盲掉该 actor 的一切后继事件——真账本实证 126 条 retired 事件把共享 actor（agora-mcp@agora-mcp、dotfiles-orch@.dotfiles）整体拉黑，当日 merged 全部失效。
- 改状态机必须同步 bump derive-cache 版本（v3→v4）：旧缓存水位下的事件已被旧代码当 no-op 消费，增量重放永不回看——不 bump 则修复合入后看板滞留不自愈，验收只能靠手删缓存。bump 后首跑自动全量重放补账（stats.full+1 可观测）。
- smoke 夹具甄别力闸：任务页合同的用例字面形可能不可甄别（done→merged 中 done 已终态，handler 缺席也离场）——夹具须取 handler 缺席必红的形态（claimed→merged＋cache state 断言）；每用例先在旧代码上跑出红再上修复。
- smoke 夹具分片因果序闸：POST 助手按 actor 后缀路由分片（--project "${who#*@}"）——同一任务的事件链必须同分片落账，否则 derive 按分片序重放会把 reopened 重放在 done 前（用例空转）或 merged 后（跨主机按 hostname 字典序翻红）。跨 actor 链用显式 `post.sh --actor x@proj --project proj` 钉同片。

## 逐字证据
- 真仓验收对照：修前 board/todo.md 69 条（merged 残留 0 改善空间）；修后 35 条＝9 cancelled经reopened合法回池＋18 done-unmerged待并＋8 纯 open，merged 残留清零；抽查 gt-35b5/gt-40cc/gt-8c5b/gt-7ca0 离场，gt-d039 账本确无 merged 事件属真未并。
- retired 毒化形态（账本逐字）：`actor:agora-mcp@agora-mcp | event:retired | task:gt-3ea2 | reason:冗余重派收工`——一次性会话把「本会话收工」误发成「actor 退休」（宣言 §5.3 retired＝actor 移出在册名单），共享 actor 名下 126 条。
- derive 修复落点（scripts/derive-board.sh）：`tid = f.get("task")` 提前＋merged 早退分支（注释声明含 cancelled→done）＋blocked 前置守卫 `state == "in-progress"`（gt-40cc：done 后合并失败 blocked 不得拖走终态）。
- smoke ⑥b 双形态：merged 经 post.sh 落账→同锁重推导即离板（根因消除形，断言 todo 不残留＋零派发）；raw 追加 merged 行→滞后形态下零派发＋poll 启动 derive（poll.sh:38）自愈离板——同步推导使滞后窗在生产路径结构性不可达，gt-99af 修复一（held 终态守卫）降为崩溃窗纵深，不可拆但不可经真实流触达。
- 终闸 C 册附注（gt-5a59）：merged handler 是状态机唯一无 owner 校验且先于 retired 过滤的写状态分支——信任锚＝账本可信底座（actor 系统级自声明）＋写侧票据防线（post.sh 票据＋commit==branch HEAD，merge.sh 即时销毁票）。若未来给 actor 引入真实认证，merged 分支必须一并纳入归属校验。
