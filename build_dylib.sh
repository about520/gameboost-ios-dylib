#!/usr/bin/env bash
#
# build_dylib.sh —— 在 macOS 上编译 GameBoost.dylib
#
#   ./build_dylib.sh            # arm64 + arm64e，合并成 universal
#   ./build_dylib.sh arm64      # 只编 arm64
#
# 依赖：Xcode / Command Line Tools（xcrun clang + iphoneos SDK）
# 不需要 Theos，不需要 jailbreak 环境。
#
set -euo pipefail

NAME="GameBoost"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$ROOT/Sources"
OUT_DIR="$ROOT/build"
MIN_IOS="14.0"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "❌ 找不到 xcrun。编译 iOS dylib 必须在 macOS 上，并安装 Xcode Command Line Tools："
  echo "     xcode-select --install"
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "▶ SDK: $SDK"

mkdir -p "$OUT_DIR"

SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$SRC_DIR" -name '*.m' | sort)
if [ "${#SRCS[@]}" -eq 0 ]; then
  echo "❌ Sources/ 下没有 .m 文件"
  exit 1
fi
echo "▶ 源文件 ${#SRCS[@]} 个"

COMMON=(
  -isysroot "$SDK"
  -miphoneos-version-min="$MIN_IOS"
  -fobjc-arc
  -fmodules
  -O2
  -dynamiclib
  -install_name "@executable_path/Frameworks/${NAME}.dylib"
  -framework UIKit
  -framework Foundation
  -framework QuartzCore
  -framework CoreGraphics
)

MODE="${1:-universal}"

build_one() {
  local arch="$1" out="$2"
  echo "▶ 编译 $arch ..."
  local extra=()
  if [ "$arch" = "arm64e" ]; then
    extra=(-target "arm64e-apple-ios${MIN_IOS}")
  fi
  xcrun -sdk iphoneos clang "${extra[@]}" -arch "$arch" "${COMMON[@]}" \
    -o "$out" "${SRCS[@]}"
}

if [ "$MODE" = "arm64" ]; then
  build_one arm64 "$OUT_DIR/${NAME}.dylib"
else
  build_one arm64 "$OUT_DIR/${NAME}-arm64.dylib"

  if build_one arm64e "$OUT_DIR/${NAME}-arm64e.dylib" 2>/dev/null; then
    echo "▶ 合并 universal ..."
    lipo -create "$OUT_DIR/${NAME}-arm64.dylib" "$OUT_DIR/${NAME}-arm64e.dylib" \
         -output "$OUT_DIR/${NAME}.dylib"
    rm -f "$OUT_DIR/${NAME}-arm64.dylib" "$OUT_DIR/${NAME}-arm64e.dylib"
  else
    echo "⚠️  arm64e 编译失败（旧版 Xcode 常见），回退为纯 arm64 切片"
    mv "$OUT_DIR/${NAME}-arm64.dylib" "$OUT_DIR/${NAME}.dylib"
    rm -f "$OUT_DIR/${NAME}-arm64e.dylib"
  fi
fi

# 先做一次 ad-hoc 签名，方便本地检查；注入后还会用你的证书重签一次
codesign -f -s - "$OUT_DIR/${NAME}.dylib" 2>/dev/null || true

echo
echo "✅ 产物：$OUT_DIR/${NAME}.dylib"
lipo -info "$OUT_DIR/${NAME}.dylib" || true
echo
echo "下一步：用 tools/inject_dylib.sh 注入到 IPA，或直接用 ESign / TrollStore 的「注入 dylib」功能"
