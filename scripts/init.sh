#!/usr/bin/env bash
# init.sh —— 广场仓库自举：AGORA_HOME 无 git 仓库时初始化完整骨架
# 幂等：骨架只在首次创建；远端/签名配置段每次执行（env 提供时），可随时补配。
# AGORA_PKG 指向发行包根目录（含 scripts/ 与 docs/），缺省取本脚本上级。
# 可选 env：
#   AGORA_REMOTE       远端地址（MUST 为 SSH：git@host:path 或 ssh://...；file:// 属本地传输）
#   AGORA_SIGN_KEY     SSH 签名公钥路径（缺省 ~/.ssh/id_ed25519.pub，存在即启用提交签名）
#   AGORA_REQUIRE_SIGN 1 时无签名密钥 = 失败
set -euo pipefail
export AGORA_MECHANICAL=1   # 自举即机械层：本脚本的全部提交都过 pre-commit 防线
AGORA_HOME="${AGORA_HOME:-$HOME/agora}"
AGORA_PKG="${AGORA_PKG:-$(cd "$(dirname "$0")/.." && pwd)}"

# 骨架各项幂等：clone 来的仓库缺 scripts/ 时也必须补齐
mkdir -p "$AGORA_HOME"/{log,board,inbox,raw/dispatches,scripts,server} \
         "$AGORA_HOME"/wiki/{entities,tasks,decisions,proposals,topics}
cp "$AGORA_PKG"/scripts/*.sh "$AGORA_HOME/scripts/"
[[ -f "$AGORA_PKG/docs/CONVENTIONS.md" ]] && cp -n "$AGORA_PKG/docs/CONVENTIONS.md" "$AGORA_HOME/" 2>/dev/null || true
[[ -f "$AGORA_PKG/docs/AGENTS.md" ]] && cp -n "$AGORA_PKG/docs/AGENTS.md" "$AGORA_HOME/" 2>/dev/null || true

cd "$AGORA_HOME"
if [[ ! -d .git ]]; then git init -q; fi
git config user.name agora-admin && git config user.email agora@local
git config pull.rebase false   # 宣言铁律：禁 rebase
bash "$AGORA_HOME/scripts/install-hooks.sh" >/dev/null   # 防御纵深随自举装好（幂等覆盖安装）
# 全文本 union 合并：跨机同步的程序化冲突解决（log/board/wiki 是 .md；sessions.map 与 allowed_signers 是共享可变纯文本）
touch .gitattributes
for _pa in '*.md merge=union' 'scripts/sessions.map merge=union' 'wiki/allowed_signers merge=union'; do
  grep -qxF "$_pa" .gitattributes || printf '%s\n' "$_pa" >> .gitattributes
done
[[ -f wiki/decisions/doctor-runbook.md ]] || cat > wiki/decisions/doctor-runbook.md <<'EOF'
---
owner: mayor
---
# doctor 恢复手册
- seq 断档/重号：人工核对 git log 定位脏写；不许删行（只追加），发 diagnosed 事件记录。
- 重复 idem：保留首条，后续行视为脏数据，发 diagnosed 标注无效行 ref。
- board 不一致：doctor.sh --fix（重建）。
- flock 长期不可获取：ps 找持锁进程并 kill；MUST NOT 删除锁文件（锁在 fd 不在文件）。
- §sync 同步冲突（SYNC_CONFLICT）：union 未覆盖的冲突（如二进制）；人工合并后 push，发 diagnosed 记录。
EOF
[[ -f scripts/sessions.map ]] || printf '# <机器名>  <agent名>  <opencode session id>  <登记时间>（多机：仅本机条目算"在场"）\n' > scripts/sessions.map
git add -A
git diff --cached --quiet || git commit -qm "init: agora bootstrap (converge)"
git rev-parse --verify HEAD >/dev/null 2>&1 || git commit -qm "init: agora bootstrap" --allow-empty
echo "agora initialized at $AGORA_HOME" >&2

# ---------- 远端与签名配置（幂等，env 提供时才动） ----------
cd "$AGORA_HOME"
if [[ -n "${AGORA_REMOTE:-}" ]]; then
  case "$AGORA_REMOTE" in
    git@*|ssh://*|file://*|/*|./*) ;;
    *) echo "拒绝非 SSH 远端: $AGORA_REMOTE（必须 git@host:path 或 ssh://...）" >&2; exit 1 ;;
  esac
  git remote get-url origin >/dev/null 2>&1 && git remote set-url origin "$AGORA_REMOTE" \
                                           || git remote add origin "$AGORA_REMOTE"
  git config pull.rebase false
  git push -u origin HEAD >/dev/null 2>&1 \
    || echo "首次 push 未成功（远端非空/网络不可达？下次写入的 pre-pull 会自动合并）" >&2
  echo "remote origin = $AGORA_REMOTE" >&2
fi
SIGN_KEY="${AGORA_SIGN_KEY:-$HOME/.ssh/id_ed25519.pub}"
if [[ -f "$SIGN_KEY" ]]; then
  git config gpg.format ssh
  git config commit.gpgsign true
  git config user.signingkey "$SIGN_KEY"
  printf '* %s\n' "$(cat "$SIGN_KEY")" > "$AGORA_HOME/wiki/allowed_signers"
  git config gpg.ssh.allowedSignersFile "$AGORA_HOME/wiki/allowed_signers"
  git add wiki/allowed_signers 2>/dev/null || true
  git commit -qm "config: enable ssh commit signing" >/dev/null 2>&1 || true
  echo "ssh 签名已启用: $SIGN_KEY" >&2
elif [[ "${AGORA_REQUIRE_SIGN:-0}" == "1" ]]; then
  echo "AGORA_REQUIRE_SIGN=1 但签名密钥不存在: $SIGN_KEY" >&2
  exit 1
fi
