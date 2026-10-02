#!/usr/bin/env bash
#
# push_and_build.sh —— 不依赖 gh CLI，只用 curl + git 走完整个流程
#
#   GitHub 建仓 → 推送 → 等 Actions → 下载 GameBoost.dylib
#
# 用法：
#   export GH_TOKEN=ghp_xxxxxxxx     # 需 repo + workflow 权限
#   ./tools/push_and_build.sh gameboost
#
#   或： ./tools/push_and_build.sh gameboost ghp_xxxxxxxx
#
set -euo pipefail

REPO="${1:-gameboost}"
TOKEN="${2:-${GH_TOKEN:-}}"

API="https://api.github.com"

if [ -z "$TOKEN" ]; then
  cat <<'EOF'
❌ 没有拿到 token。

两种给法：
  export GH_TOKEN=ghp_xxxx
  ./tools/push_and_build.sh gameboost

  ./tools/push_and_build.sh gameboost ghp_xxxx

Token 需要权限（二选一）：
  · Classic PAT      —— 勾 repo + workflow
  · Fine-grained PAT —— Repository permissions: Contents=Read/write,
                        Workflows=Read/write, Actions=Read
创建地址： https://github.com/settings/tokens
EOF
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

api() {  # api <method> <path> [json-body]
  local m="$1" p="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$m" -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$body" "$API$p"
  else
    curl -sS -X "$m" -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" "$API$p"
  fi
}

PY="python"
command -v python >/dev/null 2>&1 || PY="C:/Users/admin/.workbuddy/binaries/python/versions/3.13.12/python.exe"

jqv() { "$PY" -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

echo "════════════════════════════════════════"
echo " GameBoost 云端编译（curl + git，无需 gh）"
echo "════════════════════════════════════════"

# —— 0. 验证 token
ME="$(api GET /user)"
LOGIN="$(printf '%s' "$ME" | jqv "['login']")"
[ -n "$LOGIN" ] || { echo "❌ token 无效或权限不足。返回："; printf '%s\n' "$ME" | head -20; exit 1; }
echo "▶ 登录用户：$LOGIN"

# —— 1. 本地提交
[ -d .git ] || git init -q
git add -A
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.email="local@local" -c user.name="GameBoost" commit -q -m "GameBoost: 云端编译出包"
  echo "▶ 已提交本地改动"
else
  echo "▶ 无本地改动"
fi
git branch -M main 2>/dev/null || true

# —— 2. 建仓库
if api GET "/repos/$LOGIN/$REPO" | grep -q '"full_name"'; then
  echo "▶ 仓库已存在：$LOGIN/$REPO"
else
  echo "▶ 创建仓库 $LOGIN/$REPO"
  R="$(api POST /user/repos "{\"name\":\"$REPO\",\"private\":false,\"auto_init\":false}")"
  printf '%s' "$R" | grep -q '"full_name"' || { echo "❌ 建仓失败："; printf '%s\n' "$R" | head -20; exit 1; }
fi

# —— 3. 推送（用 token 内联 URL，不落盘到 git config）
echo "▶ 推送 main"
git remote remove origin 2>/dev/null || true
git push -q "https://x-access-token:$TOKEN@github.com/$LOGIN/$REPO.git" main:main

# —— 4. 等 Actions
echo "▶ 等待 Actions 运行启动……"
RID=""
for i in $(seq 1 20); do
  sleep 4
  RUNS="$(api GET "/repos/$LOGIN/$REPO/actions/runs?per_page=5")"
  RID="$(printf '%s' "$RUNS" | "$PY" -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for r in d.get('workflow_runs',[]):
        if r.get('name')=='build-ios-dylib' or 'build' in (r.get('path') or ''):
            print(r['id']); break
except Exception: pass" 2>/dev/null)"
  [ -n "$RID" ] && break
done
if [ -z "$RID" ]; then
  echo "⚠️ 没找到运行记录。多半是 .github/workflows/build.yml 没推上去（token 缺 workflow 权限）。"
  echo "   手动看： https://github.com/$LOGIN/$REPO/actions"
  exit 1
fi
echo "▶ 运行 ID：$RID    查看： https://github.com/$LOGIN/$REPO/actions/runs/$RID"

echo "▶ 等待构建完成（最多约 12 分钟）……"
STATUS=""; CONCL=""
for i in $(seq 1 72); do
  sleep 10
  RUN="$(api GET "/repos/$LOGIN/$REPO/actions/runs/$RID")"
  STATUS="$(printf '%s' "$RUN" | jqv "['status']")"
  CONCL="$(printf '%s' "$RUN" | jqv "['conclusion']")"
  printf "\r   状态：%s / %s   " "$STATUS" "${CONCL:-进行中}"
  [ "$STATUS" = "completed" ] && break
done
echo

# —— 5. 失败：拉日志
if [ "$CONCL" != "success" ]; then
  echo
  echo "❌ 构建结论：${CONCL:-未知}"
  echo "──── 失败日志（末尾 80 行）────"
  JOBS="$(api GET "/repos/$LOGIN/$REPO/actions/runs/$RID/jobs")"
  JID="$(printf '%s' "$JOBS" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
for j in d.get('jobs',[]):
    if j.get('conclusion')=='failure': print(j['id']); break" 2>/dev/null)"
  if [ -n "$JID" ]; then
    curl -sS -L -H "Authorization: Bearer $TOKEN" \
      "$API/repos/$LOGIN/$REPO/actions/jobs/$JID/logs" | tail -80
  else
    echo "(拿不到 job 日志，请直接打开上面的运行链接看)"
  fi
  echo
  echo "把这段贴给我，我按报错改。"
  exit 1
fi

# —— 6. 下载产物
echo "▶ 构建成功，下载产物"
mkdir -p build
ARTS="$(api GET "/repos/$LOGIN/$REPO/actions/runs/$RID/artifacts")"
AID="$(printf '%s' "$ARTS" | "$PY" -c "
import sys,json
d=json.load(sys.stdin)
for a in d.get('artifacts',[]):
    if a.get('name')=='GameBoost.dylib': print(a['id']); break" 2>/dev/null)"
[ -n "$AID" ] || { echo "❌ 没找到名为 GameBoost.dylib 的 artifact。返回："; printf '%s\n' "$ARTS" | head -20; exit 1; }

curl -sS -L -H "Authorization: Bearer $TOKEN" \
  "$API/repos/$LOGIN/$REPO/actions/artifacts/$AID/zip" -o build/artifact.zip
"$PY" -c "
import zipfile, pathlib, shutil, sys
out = pathlib.Path('build')
with zipfile.ZipFile('build/artifact.zip') as z:
    for n in z.namelist():
        print('  包内:', n)
        if n.endswith('.dylib'):
            with z.open(n) as src, open(out / pathlib.Path(n).name, 'wb') as dst:
                shutil.copyfileobj(src, dst)
"
rm -f build/artifact.zip

echo
echo "════════════════════════════════════════"
echo "✅ 完成"
find build -name '*.dylib' -exec ls -la {} \;
echo
echo "下一步：TrollStore / ESign / Sideloadly 注入到已砸壳的 IPA"
echo "════════════════════════════════════════"
