# 自动注册域判据：拒注册取舍与可注册夹具域

> 2026-10-24, gt-583b（review-loop e2e 夹具机械入册污染真实名册；同域依赖 worktree-resolution 的 main_repo_of 口径）

## 契约
1. **adjudicate 自动注册的域闸＝「物理 /tmp 根前缀 ∨ 路径段 e2e 全等 ∨ 段含 fixture 子串」→ 拒注册保持匿名**——判据对 realpath 后的 CWD 生效；/tmp 根须 `os.path.realpath("/tmp")` 比较而非字面前缀（macOS /tmp→/private/tmp 时 getcwd 已物理化，字面前缀整族漏判）。拒注册＝`_auto_register` 返 False 与 $HOME/O_EXCL 让位同语义（匿名，读侧可用），区别于 worktree 的 `return None`（归主）。
2. **取舍：拒注册而非 ephemeral 标记**——污染根因是真实名册「建页」本身：拒＝零建页零 git commit；ephemeral 仍建页只靠 who/board 隐藏，多消费面各需过滤、每面皆泄漏点，改动大一个量级。需身份的 e2e 应自行 provision 实体页（守卫只管自动注册，`resolve_entity` 不滤——人工页覆盖夹具域是合法路径）。
3. **可注册夹具域＝$HOME 子目录且非 worktree**——`main_repo_of` 只认 worktree 指针文件（.git 目录的普通 repo 返 None 可注册）；$HOME 本身若是 linked worktree（.git 为文件），其全部子目录归主不可注册——套件须顶部探针 `main_repo_of(REG)`，不可注册环境把依赖注册的用例降级 skip 并显式注明（假红＝假信号）。
4. **真 $HOME 夹具必须 trap EXIT 清理**——夹具迁出 mktemp 域即失去 OS 清理兜底，中断（Ctrl-C/超时/崩溃）残留的 `~/agora-smoke-reg-*` 本身是可注册域：未来任何 server 以此为 cwd 就把实体写进真实名册——残留复刻了守卫要堵的污染向量。

## 排障
负向断言（「不得建页」类）禁用 `os.listdir` 成员判断——机械建页带 `.md` 后缀，`"name" not in ents` 恒真（gt-583b 红测首版实证：污染不变量从未被验证）；须页级 `isfile(<name>.md)` 断言。`"fixture" in seg` 是子串匹配：真实项目路径段含 fixture 字样会被拒（误伤面良性——匿名读侧可用＋人工 provision 兜底），大写 `Fixtures`/`E2E` 段不命中（逃逸面，suggestion 级留档未修）。
