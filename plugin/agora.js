// agora.js —— Agora 广场的 opencode 插件（宿主适配层，规格 §8.2）
// 定位：薄壳。广场能力主体经 MCP（12 工具）提供；本插件只补三件事：
//   ① config hook：尽力注册 agora MCP server（已有 JSON 条目则不覆盖）。
//      注意：部分 opencode 入口（如 mcp list）不应用插件 config 钩子——注册以 install.sh
//      写入 opencode.json 的条目为准，本钩子只做运行时的尽力补位
//   ② 自定义工具 agora_my_queue：零参数个人任务队列（= agora_board(owner=me) 的语法糖；
//      纯文件读取实现，MCP 未连接时仍可用——韧性备份）
//   ③ event hook：session 创建时 toast 提醒手上的活（拉模式的"在场感"补丁；非 TUI 环境静默跳过）
// 主动提醒的完整方案仍是 §8.1 通知桥（server HTTP API 层）；这里只兜 TUI 内会话的底。
// 安装：install.sh 在 ~/.config/opencode/plugins/ 生成两行加载器指向本文件；AGORA_HOME 经加载器注入。

import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { tool } from "@opencode-ai/plugin"

const AGORA_PKG = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
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

export const AgoraPlugin = async ({ directory, client }) => {
  return {
    // ① 零配置注册 MCP（若 opencode.json 已有 agora 条目则以配置为准，不覆盖）
    config: async (config) => {
      config.mcp = config.mcp || {}
      if (!config.mcp.agora) {
        config.mcp.agora = {
          type: "local",
          command: ["python3", path.join(AGORA_PKG, "server", "agora_mcp.py")],
          enabled: true,
        }
      }
    },

    // ② 个人任务队列工具（零参数；身份由 cwd 裁决，无需自报）
    tool: {
      agora_my_queue: tool({
        description: "我在 Agora 广场手上的任务队列（in-progress + blocked，按服务端裁决的身份过滤）。开场仪式收尾调用；全量看板用 MCP 的 agora_board。",
        args: {},
        async execute(_args, context) {
          return myQueue(context.directory || directory).text
        },
      }),
    },

    // ③ 会话创建时 toast 手上的活（只报主会话；TUI 之外的环境静默跳过）
    event: async ({ event }) => {
      if (event.type !== "session.created") return
      if (event.properties?.info?.parentID) return
      try {
        const q = myQueue(directory)
        if (!q.actor) return
        await client.tui.showToast({
          body: {
            title: "Agora 广场",
            message: q.count > 0 ? `${q.actor}：手上有 ${q.count} 件活（agora_my_queue 查看）` : `${q.actor}：手上无活，agora_board 领新任务`,
            variant: "info",
          },
        })
      } catch { /* 非 TUI / server 模式：静默 */ }
    },
  }
}

export default AgoraPlugin
