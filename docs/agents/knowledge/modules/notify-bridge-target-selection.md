# notify 桥注入目标鉴别契约

> 2026-10-25, gt-893a（桥→TUI 注入静默失败一周排查；三分册终闸 C1/B1 修复实证）

## 契约
1. **sessions.map 是不可信共享可变文本，注册闸可被绕过**：enforcer 懒注册（--cwd→实体推导）把派生 worker 会话登记进项目实体（实证 dotfiles-orch 一实体 8+ sid，仅 1 个真 TUI），历史污染行含命令注入探测样本。消费侧（notify-opencode.sh）对 sid 白名单硬闸 `^[A-Za-z0-9._-]+$` **且拒裸点段 `.`/`..`**（`..` 全匹配字符类——逐字插值 `POST /api/session/../prompt` 点段归一即逃逸 /session/{sid} 作用域，无需斜杠；官方注册面只拒空白/控制字符可直产 `..`，R2 实测。**awk 须 mawk 兼容写法 `/^\.\.?$/`——mawk 1.3.4 对 interval `\.{1,2}` 静默不匹配**）——sid 逐字进 `opencode api` URL 路径且经 `for` 展开，glob 形态按 CWD 展开静默换目标（终闸 C 册双沙箱实弹证）。拒绝式校验信任边界落消费端，不轻信上游注册闸。
2. **注入目标＝同实体 ts 降序首个 live interactive 顶层会话**，文件序不可用：map 行序经 poll TTL 重写/git union merge/新注册 append 持续洗牌（实证真 TUI 双行且 17:26 行排第 6、17:05 行排第 28）——awk 文件序 last-match 是「间歇性静默失败＋无干预自发恢复」的机理（11:47 翻走 16:1x 翻回）。鉴别经 runtime `who` 契约：`delegated`＝parentID 在场（subagent 派生）∨ title `agora: gt-` 前缀（dispatch 派生）；`dead`＝outcome failed/interrupted（会话存储持久化，崩溃会话 API 仍可达 rc=0 收单＝假投递）；who rc1=不可达退回尽力注入（stub 兼容）。
3. **「无条目」与「全被过滤」语义分叉**：raw 计数判真无条目（设计内静默 return 0；map 文件缺失＝awk rc2 无 END 输出空串，raw 判 `-z` 同归静默——R2 实测）；条目在但全被白名单/鉴别过滤＝`fail no-live-interactive` 失败可见（bump_fail＋return 1，水位不推进）。合并两分支会把全污染实体静默丢提醒。
4. **丢不得与防风暴的对价**：注入失败不推进水位（下轮重试）＋60s 去抖按尝试占频（防重试风暴）；`.fail` 计数读值 sanitize（`^[0-9]+$` 否则归 0）——损坏计数文件在 set -u 下 `$(( 展开 ))` 抛 unbound variable 杀长驻 daemon（B 册实弹复现 rc1）。
5. **全路径落痕是一等契约**：`.git/notify-debug.log` 一行一事件（skip no-map-entry/bad-sid、skip delegated/dead、who-unreachable fallback、target、inject-ok、fail inject-rc、fail no-live-interactive、bypass runtime-guard）——零落痕使打偏一周无从定位；成功与失败两窗都要可重建。

## 边界
- worker 会话（delegated）不收实体信是**正确路由**：实体信箱看门人＝interactive 顶层会话；worker 靠 spawn prompt＋协议轮询自查。已知取舍：session-open「注入通道异常 N 次」文案消费面在 .dotfiles enforcer 插件（跨仓待办）。
- daemon 与手动 `--once` 并发的去抖 read-then-write 窗＝偶发重复提醒（queue 语义无害），锁成本>收益，记录不修。
