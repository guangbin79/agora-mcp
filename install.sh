#!/usr/bin/env bash
# install.sh —— agora-mcp 一键安装：依赖检查 + 自举广场仓库 + 注册 opencode 全局 MCP + 装 hook
set -uo pipefail
PKG="$(cd "$(dirname "$0")" && pwd)"
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"

echo "== 0/5 依赖检查"
# 机械层是 bash + GNU coreutils/util-linux：Linux 原生具备；macOS 需 brew 提供 GNU 版本
MISSING=()
for cmd in bash git python3 flock sha1sum timeout setsid; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
# GNU date 特性检测（--iso-8601 与 %N 纳秒，BSD date 均不支持）
date --iso-8601=seconds >/dev/null 2>&1 || MISSING+=("gnu-date(--iso-8601)")
date +%s%N 2>/dev/null | grep -q '^[0-9]*$' || MISSING+=("gnu-date(%N)")
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "缺少依赖: ${MISSING[*]}" >&2
  if [[ "$OSTYPE" == darwin* ]]; then
    echo "macOS 安装建议: brew install coreutils util-linux git python3" >&2
    echo "并把 GNU 工具置于 PATH 前（如 export PATH=\"\$(brew --prefix)/opt/coreutils/libexec/gnubin:\$PATH\"）" >&2
  else
    echo "Debian/Ubuntu: apt install coreutils util-linux git python3" >&2
  fi
  exit 1
fi
echo "依赖齐全（bash/git/python3/flock/sha1sum/timeout/setsid/GNU date）"

echo "== 1/5 自举广场仓库: $AGORA_HOME"
AGORA_HOME="$AGORA_HOME" AGORA_PKG="$PKG" bash "$PKG/scripts/init.sh" || true

echo "== 2/5 注册 opencode 全局 MCP"
CFG="$HOME/.config/opencode/opencode.json"
mkdir -p "$(dirname "$CFG")"
python3 - "$CFG" "$PKG" "$AGORA_HOME" <<'PYEOF'
import json, sys, os
cfg_path, pkg, home = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(cfg_path)) if os.path.exists(cfg_path) else {}
# opencode v2 规范形态：mcp.servers.<name>，disabled 反向开关
entry = {
    "type": "local",
    "command": ["python3", os.path.join(pkg, "server", "agora_mcp.py")],
    "disabled": False,
}
# 非默认位置时把 AGORA_HOME 写进配置，保证 server 运行时找到同一个仓库
if home != os.path.expanduser("~/agora"):
    entry["environment"] = {"AGORA_HOME": home}
cfg.setdefault("mcp", {}).setdefault("servers", {})["agora"] = entry
json.dump(cfg, open(cfg_path, "w"), ensure_ascii=False, indent=2)
print(f"written: {cfg_path}")
PYEOF

echo "== 3/5 安装防御 hook"
AGORA_HOME="$AGORA_HOME" bash "$PKG/scripts/install-hooks.sh" || true

echo "== 4/5 安装 opencode v2 插件（规格 §8.2 宿主适配层；跳过: AGORA_NO_PLUGIN=1）"
if [ "${AGORA_NO_PLUGIN:-0}" != "1" ]; then
  PLUGIN_DIR="$HOME/.config/opencode/plugins"
  mkdir -p "$PLUGIN_DIR"
  # 完整文件落位：env 注入头 + 插件源码拼成独立文件（v2 全局插件自动发现该目录；
  # 删除此文件即卸载插件）
  {
    echo "// 由 agora-mcp install.sh 生成；删除本文件即卸载插件"
    echo "process.env.AGORA_HOME ??= \"$AGORA_HOME\""
    echo "process.env.AGORA_PKG ??= \"$PKG\""
    cat "$PKG/plugin/agora.js"
  } > "$PLUGIN_DIR/agora.js"
  echo "installed: $PLUGIN_DIR/agora.js（零配置注册 MCP + agora_my_queue 工具 + 队列上下文注入）"
fi

echo "== 5/5 冒烟测试（可选跳过: AGORA_SKIP_TEST=1）"
if [ "${AGORA_SKIP_TEST:-0}" != "1" ]; then
  AGORA_PKG="$PKG" bash "$PKG/tests/smoke-test.sh" || echo "⚠ 冒烟测试未通过，请检查上述 FAIL 项" >&2
fi

cat <<EOF

完成。建议再配一条每日备份 cron：
  0 3 * * * AGORA_HOME=$AGORA_HOME bash $AGORA_HOME/scripts/backup.sh

使用：任意项目目录打开 opencode，会话自动挂载广场工具（插件版额外获得 agora_my_queue 零参数队列与队列上下文注入）。
首次使用某项目前，记得在 $AGORA_HOME/wiki/entities/ 登记身份页（dirs 指向项目目录）。
EOF
