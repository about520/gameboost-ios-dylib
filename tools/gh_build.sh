#!/usr/bin/env bash
#
# gh_build.sh —— 一条命令走完：建仓库 → 推送 → 等 Actions → 下载 GameBoost.dylib
#
# 前置：
#   1. 已安装 gh 并登录：  gh auth status
#   2. 本机已有 git
#
# 用法：
#   ./tools/gh_build.sh mygameboost        # 建 public 仓库 mygameboost 并出包
#   ./tools/gh_build.sh mygameboost --private
#
set -euo pipefail

REPO="${1:-gameboost}"
VIS="${2:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "════════════════════════════════════════════"
echo " GameBoost 云端编译"
echo " 工程目录: $ROOT"
echo " 目标仓库: $REPO $VIS"
echo "════════════════════════════════════════════"

# —— 0. 检查 gh 与登录状态
if ! command -v gh >/dev/null 2>&1; then
  echo "❌ 找不到 gh。请先安装 GitHub CLI： https://cli.github.com/"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "❌ 还没登录。先执行： gh auth login"
  echo "   （需要勾选 repo 和 workflow 权限，否则推送 .github/workflows 会被拒）"
  exit 1
fi
echo "▶ 登录用户: $(gh api user -q .login)"

# —— 1. 本地提交
if [ ! -d .git ]; then
  git init -q
fi
git add -A
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.email="local@local" -c user.name="GameBoost" \
      commit -q -m "GameBoost: 云端编译出包"
  echo "▶ 已提交本地改动"
else
  echo "▶ 无本地改动"
fi
git branch -M main 2>/dev/null || true

# —— 2. 建仓库 / 关联远端
LOGIN="$(gh api user -q .login)"
if gh repo view "$LOGIN/$REPO" >/dev/null 2>&1; then
  echo "▶ 远端仓库已存在：$LOGIN/$REPO"
  git remote remove origin 2>/dev/null || true
  git remote add origin "https://github.com/$LOGIN/$REPO.git"
else
  echo "▶ 创建仓库 $LOGIN/$REPO"
  # --source . --push 会顺便推上去
  if [ "$VIS" = "--private" ]; then
    gh repo create "$REPO" --private --source=. --remote=origin --push
  else
    gh repo create "$REPO" --public --source=. --remote=origin --push
  fi
fi

# —— 3. 推送
echo "▶ 推送 main"
git push -u origin main

# —— 4. 等这次工作流跑完
echo "▶ 等待 Actions 运行……"
sleep 5
RID=""
for i in $(seq 1 20); do
  RID="$(gh run list --repo "$LOGIN/$REPO" --workflow build.yml --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [ -n "$RID" ] && break
  sleep 3
done

if [ -z "$RID" ]; then
  echo "⚠️ 没找到运行记录。检查 .github/workflows/build.yml 是否被推送（需要 workflow 权限）。"
  echo "   也可以去网页手动触发： https://github.com/$LOGIN/$REPO/actions"
  exit 1
fi
echo "▶ 运行 ID: $RID"

gh run watch "$RID" --repo "$LOGIN/$REPO" --exit-status || {
  echo
  echo "❌ 构建失败。拉取日志尾部："
  gh run view "$RID" --repo "$LOGIN/$REPO" --log-failed 2>/dev/null | tail -60 || \
    gh run view "$RID" --repo "$LOGIN/$REPO" --log | tail -60
  echo
  echo "把上面这段报错发给我，按报错改。"
  exit 1
}

# —— 5. 下载产物
OUT="$ROOT/build"
mkdir -p "$OUT"
echo "▶ 下载产物"
gh run download "$RID" --repo "$LOGIN/$REPO" -n GameBoost.dylib -D "$OUT"

echo
echo "════════════════════════════════════════════"
echo "✅ 拿到 dylib："
find "$OUT" -name '*.dylib' -exec ls -la {} \;
echo
echo "下一步：用 TrollStore / ESign / Sideloadly 把它注入到已砸壳的 IPA。"
echo "════════════════════════════════════════════"
