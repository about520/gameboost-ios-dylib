#!/usr/bin/env bash
#
# inject_dylib.sh —— 把 GameBoost.dylib 注入 App Store 的 IPA，并重签名
#
#   ./inject_dylib.sh 原始.ipa GameBoost.dylib "签名身份" [输出.ipa]
#
# 签名身份可以用：
#   - Apple 开发者证书：  "Apple Development: xxx (TEAMID)"
#   - 自签证书（Sideloadly/AltStore 生成的）： 查看 `security find-identity -v -p codesigning`
#
# 前提：IPA 必须是**已砸壳（decrypted）**的。
#       App Store 下载的原始 IPA 里的二进制是加密的（cryptid=1），
#       直接注入 + 重签会因为 __TEXT 段仍被 FairPlay 加密而无法运行。
#
set -euo pipefail

IPA="${1:-}"
DYLIB="${2:-}"
IDENTITY="${3:-}"
OUT_IPA="${4:-}"

if [ -z "$IPA" ] || [ -z "$DYLIB" ] || [ -z "$IDENTITY" ]; then
  echo "用法: $0 原始.ipa GameBoost.dylib \"签名身份\" [输出.ipa]"
  echo
  echo "查看可用签名身份： security find-identity -v -p codesigning"
  exit 1
fi

[ -f "$IPA" ]   || { echo "❌ 找不到 IPA：$IPA"; exit 1; }
[ -f "$DYLIB" ] || { echo "❌ 找不到 dylib：$DYLIB"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▶ 解包 IPA"
unzip -q "$IPA" -d "$WORK"

APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "❌ Payload 下没有 .app"; exit 1; }
echo "▶ App: $APP"

BIN_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
BIN="$APP/$BIN_NAME"
[ -f "$BIN" ] || { echo "❌ 找不到可执行文件：$BIN"; exit 1; }

# —— 砸壳检查
echo "▶ 检查加密状态"
CRYPTID="$(otool -l "$BIN" | awk '/LC_ENCRYPTION_INFO/{f=1} f&&/cryptid/{print $2; exit}')"
if [ -z "$CRYPTID" ]; then
  echo "  （没有 LC_ENCRYPTION_INFO，说明已是砸壳版本）"
elif [ "$CRYPTID" != "0" ]; then
  echo "❌ 该二进制仍处于加密状态（cryptid=$CRYPTID）。"
  echo "   请先用 frida-ios-dump / TrollDecrypt / 越狱设备 砸壳，再回来注入。"
  exit 1
else
  echo "  cryptid=0，已砸壳 ✓"
fi

# —— 放置 dylib
FRAMEWORKS="$APP/Frameworks"
mkdir -p "$FRAMEWORKS"
cp "$DYLIB" "$FRAMEWORKS/"
echo "▶ 已放置：$FRAMEWORKS/$(basename "$DYLIB")"

# —— 插入 LC_LOAD_DYLIB
LOAD_PATH="@executable_path/Frameworks/$(basename "$DYLIB")"

if command -v insert_dylib >/dev/null 2>&1; then
  echo "▶ 用 insert_dylib 插入 load command"
  insert_dylib --inplace --strip-codesig --add-original "$LOAD_PATH" "$BIN" >/dev/null
elif command -v optool >/dev/null 2>&1; then
  echo "▶ 用 optool 插入 load command"
  optool install -c load -p "$LOAD_PATH" -t "$BIN" >/dev/null
else
  echo "❌ 需要 insert_dylib 或 optool 来插入 LC_LOAD_DYLIB。"
  echo "   brew install insert_dylib"
  echo "   # 或"
  echo "   brew install optool"
  echo
  echo "   也可以跳过本脚本，直接用 ESign / TrollStore / Sideloadly 的"
  echo "   「注入 dylib」功能（它们内置同样的 Mach-O 重写 + 重签逻辑）。"
  exit 1
fi

# —— 清理旧签名并重签
echo "▶ 清理旧签名"
find "$APP" -name '_CodeSignature' -type d -exec rm -rf {} + 2>/dev/null || true
rm -f "$APP/embedded.mobileprovision" 2>/dev/null || true

echo "▶ 重签名（$IDENTITY）"
codesign -f -s "$IDENTITY" "$FRAMEWORKS/$(basename "$DYLIB")"
codesign -f -s "$IDENTITY" --deep "$APP"

echo "▶ 验证"
codesign -v --verbose=2 "$APP" 2>&1 | head -20 || true

# —— 打包
if [ -z "$OUT_IPA" ]; then
  OUT_IPA="$(dirname "$IPA")/$(basename "${IPA%.ipa}")-boosted.ipa"
fi
echo "▶ 打包 → $OUT_IPA"
rm -f "$OUT_IPA"
( cd "$WORK" && zip -qry "$OUT_IPA" Payload )

echo
echo "✅ 完成：$OUT_IPA"
echo "   安装方式：TrollStore 直接安装；或用 Sideloadly / AltStore 侧载（免费证书 7 天有效期）"
