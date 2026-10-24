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
