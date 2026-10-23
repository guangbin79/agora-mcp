# wiki-write replace 语义（自动写入方契约）

> 2026-10-23, gt-abcd（poll 每日督报页自动写入实证）

## 契约
- `wiki-write.sh --mode replace` 对已存在页**只写 content、不带 frontmatter**：创建时机械层补 `---/owner/created` 头，replace 时整文件被 content 覆盖——owner 行随首次 replace 丢失，**下次 replace 一律 OWNER_MISMATCH（owner 为空串≠任何 NAME）**。周期性整页重写（督报/统计类）必须自读页首 frontmatter 并随新内容回写（poll.sh ②e 段做法），否则功能静默死亡且仅 report 可见。
- 同内容重写时 `git commit -q` 失败（"nothing to commit"，rc≠0）——已是目标态，写入方应视为成功并翻闸，否则闸门常开、每轮重试刷屏（poll 督报闸处理）。
- 推论：需要 owner 持续有效的 wiki 页，其唯一合法整页重写方＝owner 本人，且必须回写 frontmatter。
