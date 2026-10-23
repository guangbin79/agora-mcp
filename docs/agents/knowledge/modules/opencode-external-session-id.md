# opencode 外部 id 与会话命名（gt-2845 K3）

- **结论**：opencode v2.x 服务端接受 `run --session <外部id>` 与 `--title`（2026-10-23 真机 spike：预生成 `ses_+26 alnum` rc=0 且 sessionID 回显同值；`--title` 经 `GET /api/session/<sid>` 原样可读）。dispatch run 通道因此可预生成 sid 落账（`dispatched.session:` 两通道统一），不再依赖「spawn 后 sid 不可知」假设；ack/续跑注入对 run 通道子会话同样可达。
- **边界**：help 旗标存在≠运行时接受——CLI 旗标有漂移史（`--dir` 随 2.0.32 移除 exit 1），契约性旗标落码前一律真机 spike 并把结论写进代码注释＋规格（本例模式：注释注 spike 日期，规格 §4.7 注「服务端接受外部 id（spike 实证）」）。fake/stub runtime 吞旗标全过，smoke 无法发现旗标漂移——smoke 绿不构成旗标证据。
- **教训（F3 回归）**：sed 单表达式追加清洗逻辑时把 `p` 移到末尾＝「每行打印」，`head -1` 从锚定行变为 frontmatter 首行（`---` 混入 title）——锚定打印与追加清洗拆两段管道，勿合一个 sed 表达式。
