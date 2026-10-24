# 脚本单源收敛契约（gt-f6e4）

> 2026-10-24 评审环 R2 收口；来源任务 gt-f6e4（部署双源 154 行分叉终结）。

## 单源拓扑裁定
- 脚本唯一真源＝产品仓 `<pkg>/scripts`；MCP server `SCRIPTS = os.environ.get("AGORA_SCRIPTS") or os.path.join(_PKG, "scripts")`——env 覆盖口给测试/隔离广场，缺省 `_PKG` 推导（`_PKG` 先于 `SCRIPTS` 定义，非本代引入）。
- bash 兄弟互调一律脚本自定位：`SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`，禁止 `$AGORA_HOME/scripts` 运行态引用（数据目录不再是代码寻址根）。PYTHONPATH 导入同口径，且**自目录先行**（dispatch.sh:39）——数据目录里滞后的 lib 拷贝不再能覆写代码（顺带关闭数据目录代码注入面，C 册实证正向）。
- 账本仓（AGORA_HOME）回归纯数据：脚本不入库不入盘（init.sh 停装）；`sessions.map` 系运行态数据，迁 AGORA_HOME 根，union 合并行同步迁——数据住哪个目录与代码住哪个目录是两个裁决，别让数据蹭代码的目录。

## 路径迁移三课（R1 三分册实证）
1. **git pathspec 也是消费点**——`subprocess.run(["git", "add", <path>])` 的 pathspec 不在 grep「读写该路径」清单里就会漏（poll.sh:762 漏迁 → `git add` rc128 被吞 → 保洁永不入库＋脏 sessions.map 阻断多机 sync pre）。迁移盘点必须含 subprocess/管道里的 git pathspec、awk/sed 文件参数，不止脚本内 open/bash 调用。
2. **存量部署迁移要幂等落 init.sh**——MCP bootstrap 只在 AGORA_HOME 无 .git 时跑 init，存量部署永不吃到；数据迁移（旧 `scripts/sessions.map` 并入根＋删旧）写进 init.sh 幂等块才覆盖手动 init 路径。union 合并属性随账本仓 .gitattributes 提交传播（不必逐机手补），但「产品升级而账本不 pull」的部署形态仍靠 init.sh 兜。
3. **smoke 不断言「变更落库」就拦不住这类回归**——TTL 断言只看计数与文件内容，`git add` 失败全程静默；补「保洁后 `git status --porcelain -- sessions.map` 为净」断言（评审 R1-F1 防复发线）。

## 部署语义注记
- 迁移后 init 幂等语义扩展：骨架 mkdir 不含 scripts；`install-hooks` 走 `$AGORA_PKG/scripts`；克隆机 init 只补数据骨架（sessions.map 种根），脚本永远来自产品包。
- 多机升级顺序敏感窗：产品先升而账本未 pull 的机器，旧登记数据隔离在旧路径直到 init.sh 迁移块或 pull 到 rename——诊断要点＝「活会话收不到 mention 注入且无任何报错」先查两端 sessions.map 路径一致性。
