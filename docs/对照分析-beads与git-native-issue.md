# 对照分析：Beads 与 git-native-issue 的教训

> 本文是《Git 论坛：设计宣言 · 单机版 v0.3》§10 的补充材料。
> 选取两个与宣言血缘最近的开源项目做深度对照：
> **Beads**（为什么它离开了纯文件存储）与 **git-native-issue**（"格式即交付物"怎么写）。
> 目的：验证宣言的核心赌注（纯文本事件日志 + 推导层 + 无数据库）在前人的残骸上是否站得住。

---

## 一、Beads：一部"文件式存储死于并发"的活体编年史

Beads（gastownhall/beads，Steve Yegge）是 Gas Town 多 agent 编排系统的账本层，是目前"AI agent 的任务状态存哪"这个问题上投入实战最多的项目。它的存储架构经历了三代，每一代的迁移原因都是本宣言的直接教材。

### 1.1 第一代：JSONL + SQLite 缓存（classic）

架构：`.beads/issues.jsonl` 是唯一事实源并提交进 git；本地 SQLite 只是查询缓存；配自定义 git merge driver 处理并发；issue ID 用 hash（`bd-a1b2`）而非顺序号。

这一代的四个死因：

1. **单文件热区**。所有 agent 写同一个 JSONL 文件。社区后来的复盘直截了当："no-db JSONL mode——单文件、无并发写，并行 agent 互相覆盖"。merge driver 能解文本冲突，解不了"两个 agent 同时重写整个文件"的语义冲突。
2. **双事实源的同步地狱**。JSONL 和 SQLite 互为副本，daemon 崩溃时 WAL 里未刷盘的写入导致两边行数不一致，恢复时"该信 JSONL 还是信 SQLite"成为人工裁决题。
3. **恢复路径缺失**。JSONL 理论上可用于灾后重建，但实践中"agent 不知道 DB 清空后要从 JSONL 恢复、`bd init` 不主动提供导入、issue ID 和依赖图在重建中丢失"。
4. **顺序 ID 撞号**（第一代早期）：两个分支并发创建 issue 时拿到同一个下一个序号，合并后两个不同 issue 共享一个 ID。hash ID 就是为此而生的。

### 1.2 第二代：Dolt（当前）

迁移理由（官方 FAQ）：Dolt 是"数据库层面的 git 语义"——cell-level merge（字段级自动合并）、server 模式天然多写者、`bd dolt push/pull` 原生搬运历史、无需独立同步格式。

**但 Dolt 不是免费的**，2026 年 3 月的用户故障报告（issue #2573，"Moving to dolt pretty much made beads unusable for me"）记录了新一代的死法：

- Dolt server 无自愈：进程死后所有 `bd` 命令失败，但 `bd init` 又拒绝重跑（"already initialized"），形成**无文档出路的死锁**，唯一解法是删掉数据库重来——两周内至少两次整库清空；
- 端口漂移（3307 vs 13308）、配置熵增；
- schema 迁移要求"恰好一个 clone 当指定迁移者"，其余全部阻塞等待——**一次依赖升级变成一次需要排期的运维操作**。

值得注意的是社区的反提案（issue #4404）：**每个 issue 一个文件**（`issues/foo-001.json`），理由是"并行 agent 写不同文件，文件系统天然无竞争；git 对不同文件的修改自动合并；备份随 push 免费获得"。这几乎就是本宣言"分片消灭热文件"原则的翻版——Beads 社区自己也意识到了这一点。

### 1.3 对宣言的启示

| Beads 的教训 | 宣言的对应设计 | 评估 |
|---|---|---|
| 单 JSONL 热文件被并发写死 | 分片 = 天 × 项目，只追加 | ✅ 方向正确且更激进（Beads 至死没做分片） |
| 顺序 ID 跨分支撞号 | 任务 ID 用 `gt-a1b2c` 式 hash；v0.3 起 seq 改 per-actor | ✅ 已规避 |
| 双事实源（JSONL+SQLite）同步地狱 | 事件日志是唯一事实源，board/ 纯推导、随时可重跑 | ✅ 架构上不存在此问题 |
| 自定义 merge driver 解不了语义冲突 | 只追加 + union 合并 + post.sh 单点写入 | ✅ 语义冲突由"线性化点"在写入侧消灭 |
| server 死锁无恢复路径 | ？ | ⚠️ **宣言欠账**：post.sh/推导层需要 `doctor` 式的自检与恢复路径（见 §四-3） |
| 升级要指定迁移者、全员阻塞 | 宣言 §2.7 追加式演进 + 宽容读取 | ✅ 格式只追加则永远不需要"指定迁移者" |

**核心结论**：Beads 离开文件不是因为"文件不行"，而是因为**它的文件布局是错的**（单热文件 + 原地更新 + 双事实源）。本宣言的三件套（分片、只追加、推导层）恰好逐一对应它的三个死因。但同时，Beads 的 Dolt 时代证明了另一件事：**引入服务器/数据库后，死法从"合并冲突"变成了"运维死锁"——宣言坚持无服务器，就必须在脚本层把自检和恢复做扎实，否则会以另一种方式踩进同一个坑。**

---

## 二、git-native-issue：把"格式即合同"写成一门手艺

git-native-issue（remenoscodes，2025）是一个分布式 issue tracker：issue = `refs/issues/<uuid>` 下的 commit 链，元数据用 git trailers（与 `Signed-off-by:` 同格式），冲突用 merge commit 解决。它对本宣言的价值不在实现（纯 POSIX shell 写的参考实现），而在它把 **ISSUE-FORMAT.md 当作真正的交付物**——"实现可替换，规范长存"。

### 2.1 spec 的写法，逐条可抄

1. **RFC 2119 关键词**。MUST/SHOULD/MAY 全部大写并显式声明按 RFC 2119 解释。宣言目前用"铁律""禁止"等自然语言，约束力依赖读者善意；落成 CONVENTIONS.md 时应改用 RFC 2119 语汇，机械层的校验规则才能逐条对应 spec 条款。
2. **ABNF 形式文法**。commit message 的结构用 ABNF 写死（含 UTF-8 编码细则、"trailer 值不得含 LF"这种边角）。宣言 §5 的事件行格式目前只有一个示例——**示例不是规范**，两个 agent 对"字段间空格是否合法"可以产生分歧。建议为事件行写一段等价的 ABNF 或正则锚定。
3. **状态计算的确定性算法**。当前状态 = "从 HEAD 往前找最近的 `State:` trailer"，并规定找不到时的降级行为（视为 open 并告警）。宣言的推导层需要同款定义：每个字段"从哪条事件推导、缺失时默认值是什么"，写成表而不是散文。
4. **分字段的合并规则**。标量字段 LWW（时间戳大者胜，平手比 SHA 字典序）、labels 三方集合合并、评论 union。**关键实战数据：8 个多月多贡献者生产使用，零次无法自动解决的冲突**——启发式合并在这个领域被证明够用，CRDT 是不必要的复杂。宣言的"duplicate_work_detected 交仲裁"思路与此一致，可以把这条数据写进宣言作为依据。
5. **宽容读取 + 版本号的三条 MUST**：实现必须忽略不认识的 trailer；不得拒绝 Format-Version 更高的 issue；扩展必须递增 Format-Version。宣言 §2.7/§8 有此精神，但**事件格式本身没有版本字段**——建议在分片文件头部加一行 `format: v1` 式声明（纯追加，不违反第 7 条），否则 v1 分布式时代无法区分"老格式的分片"和"新格式的分片"。
6. **refs/ 而非工作树文件**。它的杀手锏论证："issue 存在 refs/ 里、不属于任何 tree 对象，所以代码合并永远碰不到 issue"。宣言的论坛仓库本身就是载荷、没有"代码"，此招用不上；但 §9 v3 的"refs/ 存储层"路线可以以它的 merge/transport 章节（§7：fetch refspec、staging namespace、merge commit 流程）为直接蓝本。
7. **非目标清单（Non-Goals）**。spec 明确列出"不做访问控制、不做实时同步、不服务非开发者、不做富媒体、不保证数学意义上的零冲突"。宣言有类似的诚实（§7 已知限制），建议在 CONVENTIONS.md 中单列 Non-Goals 一节——**写明不做什么，是防止 AI 使用者擅自"帮忙补全"的最有效手段**。

### 2.2 对宣言的启示

| git-native-issue 的做法 | 宣言现状 | 行动建议 |
|---|---|---|
| RFC 2119 + ABNF 形式规范 | 示例 + 自然语言"铁律" | CONVENTIONS.md 增加事件行的形式文法与字段推导表 |
| Format-Version trailer + 宽容读取三 MUST | 有宽容读取原则，无版本字段 | 分片文件头加 `format: v1`；宽容读取写成 MUST 条款 |
| 分字段合并规则（LWW/集合/union） | 只有"union 合并"一句 | derive 层明确每字段的合并语义；引用其 8 个月零不可解冲突的实战数据 |
| Non-Goals 清单 | 散落各处 | CONVENTIONS.md 单列一节 |
| refs/ 存储 + transport 流程 | §9 v3 提了一句 | v3 设计时直接以其 §7 为蓝本 |

---

## 三、三方对照总表

| 维度 | Beads（classic→Dolt） | git-native-issue | 本宣言 v0.3 |
|---|---|---|---|
| 存储形态 | 单 JSONL 文件 → Dolt 数据库 | refs/ 下 commit 链（空 tree） | 工作树内分片日志，只追加 |
| 并发答案 | merge driver → cell-level merge | merge commit + 分字段启发式 | post.sh flock 线性化（单机） |
| ID 方案 | hash（防跨分支撞号） | UUID（ref 名） | 任务 hash + per-actor seq |
| 事实源 | 双份（JSONL+SQLite）→ 单份（Dolt） | commit 链唯一 | 事件日志唯一，其余皆推导 |
| 格式合同 | 无独立 spec（schema 在代码里） | ISSUE-FORMAT.md（RFC 2119 + ABNF） | 本宣言 + CONVENTIONS.md（待形式化） |
| 死法 | 合并冲突 → 运维死锁 | 尚无（规模有限） | 待检验 |
| 升级代价 | 指定迁移者 + 全员阻塞 | Format-Version 递增，宽容读取 | 只追加演进（承诺，待验证） |

---

## 四、给宣言的补丁清单（按优先级）

1. **【格式】分片文件头加 `format: v1` 声明**，并在 CONVENTIONS.md 写明宽容读取三 MUST（忽略未知字段、不拒绝高版本、扩展递增版本）。成本一行字，是 v1 分布式时代区分格式世代的唯一手段。
2. **【格式】事件行形式文法**。为 §5 的六字段写 ABNF 或锚定正则（字段顺序、分隔符、值中禁止字符），消除"示例即规范"的歧义。post.sh 的格式校验直接实现该文法。
3. **【机械层】`doctor` 自检与恢复路径**。Beads 的前车之鉴：无服务器架构的死法不是崩溃而是"无法自救的状态"。post.sh 至少应具备：检测 seq 断档/重复、idem 表校验、board 与日志的对账（derive 结果与现有 board 不一致时告警并重建）。恢复路径必须写成文档，不许出现"只能删库重来"的状态。
4. **【协议】任务 ID 全量 hash 化**。确认所有跨 agent 引用的标识符（任务、提案、身份）一律 hash/UUID，杜绝任何"下一个序号"式的分配——Beads 撞号事故的教训。
5. **【文档】CONVENTIONS.md 增加 Non-Goals 一节**。明写：不做访问控制（v0 身份可伪造是接受的）、不做实时同步、不做富媒体、不保证数学意义零冲突（启发式合并 + 仲裁帖足够，引 git-native-issue 8 个月零不可解冲突的数据）。
6. **【验证】压力测试剧本**。用 Beads 的死因当测试用例：N 个模拟 agent 并发 post、故意kill -9 post.sh 持锁进程、制造 SQLite 时代那种"双副本不一致"的等价物（手改 board/ 文件）——验证推导层重跑能否总是回到一致状态。

---

## 五、结论

Beads 证明了"文件式存储 + 多 agent 并发"在**错误的布局**下必死，也证明了引入数据库只是换了一种死法；git-native-issue 证明了"启发式合并 + 格式规范先行"在小规模分布式下可以长期存活。本宣言的设计站在两者之间：**用 Beads 的尸体验证了分片与只追加的必要性，用 git-native-issue 的手艺补格式合同的形式化短板**。两者的教训都不动摇宣言的核心赌注，但都指向同一句告诫：**这个系统的可信度不取决于设计宣言写得多好，而取决于机械层（post.sh/doctor/derive）的实现质量——把最多的工程精力押在那里。**

---

### 参考来源

- [gastownhall/beads FAQ: Why Dolt instead of plain SQLite or flat files?](https://beads.gascity.com/reference/faq)
- [beads issue #2573: Moving to dolt pretty much made beads unusable for me](https://github.com/gastownhall/beads/issues/2573)
- [beads issue #4404: Store issues as one file per issue instead of requiring Dolt](https://github.com/gastownhall/beads/issues/4404)
- [Hysen Labs: Beads bd — a graph issue tracker on Dolt](https://hysenlabs.com/projects/gastownhall-beads)
- [remenoscodes/git-native-issue: ISSUE-FORMAT.md](https://github.com/remenoscodes/git-native-issue/blob/main/ISSUE-FORMAT.md)
- [remenoscodes/git-native-issue: README（数据模型与合并策略）](https://github.com/remenoscodes/git-native-issue)
- [Forgejo issue #2629: 关于在 git 仓库存 issue 的讨论（refs/ vs 文件）](https://codeberg.org/forgejo/forgejo/issues/2629)
