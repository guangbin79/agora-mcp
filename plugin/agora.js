// agora.js —— Agora 广场的 opencode v2 插件（宿主适配层，规格 §8.2）
// 目标宿主：opencode v2（2.0.x，@opencode/plugin API）。v1 插件 API 不支持。
// 定位：薄壳。广场能力主体经 MCP（12 工具）提供；本插件只补三件事：
//   ① mcp.transform：尽力注册 agora MCP server（已有条目则不覆盖）。
//      注册以 install.sh 写入 opencode.json 的条目为准，本变换只做运行时补位。
//   ② 自定义工具 agora_my_queue：零参数个人任务队列（= agora_board(owner=me) 的语法糖；
//      纯文件读取实现，MCP 未连接时仍可用——韧性备份）。
//   ③ session.hook("context")：把「手上的活」注入会话系统上下文（v2 服务端插件没有
//      toast 能力——toast 是 v2 的 TUI 插件面；上下文注入是 v2 惯用的在场感补丁）。
// 主动提醒的完整方案仍是 §8.1 通知桥（server HTTP API 层）。
// 安装：install.sh 把「env 注入头 + 本文件全文」拼接写入 ~/.config/opencode/plugins/agora.js
// （v2 全局插件自动发现该目录；删除此文件即卸载插件）。

import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Plugin } from "@opencode/plugin"

const AGORA_PKG = process.env.AGORA_PKG || path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const AGORA_HOME = process.env.AGORA_HOME || path.join(process.env.HOME || "~", "agora")

// ---------- 身份裁决（与 server/agora_mcp.py §2.1 同一规则：cwd → 名册 dirs 最深前缀匹配） ----------
function adjudicate(cwd) {
  const dir = path.join(AGORA_HOME, "wiki", "entities")
  let best = null
  let files = []
  try { files = fs.readdirSync(dir).filter(f => f.endsWith(".md")) } catch { return null }
  for (const f of files) {
    let txt
    try { txt = fs.readFileSync(path.join(dir, f), "utf8") } catch { continue }
    const m = txt.match(/^dirs:\s*\n((?:\s+-\s+.+\n)+)/m)
    if (!m) continue
    for (const hit of m[1].matchAll(/-\s+(\S+)/g)) {
      let d
      try { d = fs.realpathSync(hit[1].replace(/^~(?=\/|$)/, process.env.HOME || "")) } catch { continue }
      if (cwd === d || cwd.startsWith(d + "/")) {
        if (!best || d.length > best[1].length) best = [path.basename(f, ".md"), d]
      }
    }
  }
  return best ? `${best[0]}@${path.basename(best[1])}` : null
}

// ---------- 个人队列：in-progress + blocked 按认领者过滤（边界匹配防名字前缀碰撞） ----------
function myQueue(cwd) {
  const actor = adjudicate(cwd)
  if (!actor) return { actor: null, text: "未注册身份（广场只读）。在 wiki/entities/ 登记目录后可用个人队列。", count: 0 }
  const pat = new RegExp(`— ${actor.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}( —|$)`)
  const sections = []
  let count = 0
  for (const view of ["in-progress", "blocked"]) {
    const p = path.join(AGORA_HOME, "board", `${view}.md`)
    let lines = []
    try { lines = fs.readFileSync(p, "utf8").split("\n") } catch { continue }
    const kept = lines.filter(l => !l.startsWith("- ") || pat.test(l))
    count += kept.filter(l => l.startsWith("- ") && !l.includes("（空）")).length
    sections.push(`## ${view}\n${kept.join("\n").trim()}`)
  }
  return { actor, text: `身份: ${actor}\n\n${sections.join("\n\n")}`, count }
}

export default Plugin.define({
  id: "agora",
  async setup(ctx) {
    const dir = ctx.location.directory

    // ① 零配置注册 MCP（若 opencode.json 已有 agora 条目则以配置为准，不覆盖）
    await ctx.mcp.transform((editor) => {
      if (!editor.get("agora")) {
        editor.set("agora", {
          type: "local",
          command: ["python3", path.join(AGORA_PKG, "server", "agora_mcp.py")],
        })
      }
    })

    // ② 个人任务队列工具（零参数；身份由会话目录裁决，无需自报）
    await ctx.tool.transform((editor) => {
      editor.add({
        name: "agora_my_queue",
        description: "我在 Agora 广场手上的任务队列（in-progress + blocked，按服务端裁决的身份过滤）。开场仪式收尾调用；全量看板用 MCP 的 agora_board。",
        input: { type: "object", properties: {}, additionalProperties: false },
        async execute() {
          return { content: myQueue(dir).text }
        },
      })
    })

    // ③ 手上的活注入会话上下文（仅在有活时注入一行；无活/未注册不添噪）
    await ctx.session.hook("context", (event) => {
      const q = myQueue(dir)
      if (!q.actor || q.count === 0) return
      event.system.push({
        type: "text",
        text: `[agora] ${q.actor} 手上有 ${q.count} 件活在广场挂着；开场仪式收尾请调 agora_my_queue（或 MCP 的 agora_board owner=me）查看。`,
      })
    })
  },
})
