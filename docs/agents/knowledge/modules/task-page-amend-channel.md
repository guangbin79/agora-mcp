# 任务页机械字段修正通道（amended）信任边界契约

> gt-b9fb（2026-10-24）。post.sh `amended` 事件＋`--set k=v` 是任务页创建后首个写通道；四条边界缺一即破「账本↔页」一致性或机械层安全。

## 1. frontmatter 锚定（守卫与改写同锚）
- 「字段行已存在」守卫与 sed 改写都必须锚 `2,/^---$/`。全文件 grep/sed 会把**正文引用旧合同的 prose 行**（`verify: ...`）误当字段：守卫误放行→amend 静默 no-op（账本记了修正、页没变，帐页背离）；改写误中→正文被静默腐蚀。
- 终闸实证：done 门 `grep -m1 '^verify:'` 读 prose 行且 `bash -c` 执行——正文 verify 槽是活的执行槽，prose 误写＝可执行注入槽。

## 2. 应用序：先页后账本
- 页 sed 必须在账本 append **之前**。反序（append 后 sed）下中断→同参重试被 dedup 静默吞（`{"dedup":true}` rc=0）→ 账本↔页**永久分歧无恢复通道**。
- 正序下中断态＝页领先账本，重试无 dedup 挡路，幂等收敛。判据：副作用序要保证「重试可收敛」，不是「单次原子」。

## 3. wt_dir 值收敛命名域
- wt_dir 修正必须校验 `dirname(wt_dir)==dirname(main_repo)`（主仓经 agora_lib.main_repo_of 解析，不可解析即拒）。否则机械层（worktree add/remove）被指到文件系统任意路径做建/删。
- 同理：amend 后首次 done 须 `derived:["verify_amended"]` 显式标注（换约是合同授权面，但评审者必须即时可见，不阻断不翻史）。

## 4. 附带教训
- `set -o pipefail` 下 `grep -m1` 无匹配 rc1 会**静默杀死** `set -e` 脚本（首跑 smoke 派发全灭、输出为空）——读可选字段用 `sed -n 's///p' | head -1` 形态。
- 正在执行的 bash 脚本不可编辑：bash 增量读字节偏移，跑动中改 smoke/post.sh 产生**单点假红**（伪影非回归）——v4 的 C-F2 FAIL 即此，重跑即绿。
- 权限口径：amended 仅任务页 `dispatcher:` 名部==actor 名部（与 done/plan mention 自动提及同源同校验）。

## 5. wt_dir 拒绝须附场景分流（gt-2508，gt-6bef amend 实证）
- 命名域守卫一票拒两种意图（「指他任务树」与「指主仓本体」）时，dispatcher 收拒后无法从文案分辨正确路径——实证绕道 python 直改任务页（恰好落进 bash 盲区，见 §6）。**拒绝文案即用户手册**：守卫每个拒绝 arm 必须告诉调用者「该走哪条路」。
- 分流契约：目标=主仓本体（basename==主仓 basename）→ 拒＋hint「跨仓直改授权勿用 wt_dir：凭据文件 `.omo/agora-delegation/<gt>.md`（worktree=目标）即可，enforcer 凭据优先放行」；目标=专属树错名 → 命名规范文案照旧。enforcer 交叉核验不放宽（防护正确，页字段补齐即放行）。

## 6. 账本面 dirty 审计判据：机械写即 commit（gt-2508 Bug3）
- enforcer 拦 agent 的 edit/write 工具，但**同 OS 用户进程的 bash 子进程（python heredoc 等）直写不可防**——预防不可行转审计＋恢复。判据成立的前提＝「机械写即 commit」（post.sh 收尾 `git add -A` 全面收编）：`git status --porcelain -- log board wiki inbox raw` 非空即绕写痕迹。
- 路径清单勿扩到根：`sessions.map` 由 register-session/poll 常态重写（机械但延迟 commit），纳入即常态误报。报告器语义（warn 不置 FAIL），恢复靠 git（报告不自动回滚）。
- enforcer 自证：对 /tmp 隔离夹具的直写 shell 命令同栏被拦——审计的存在以闸的有效为前提，闸失守时审计是最后兜底而非替代。
