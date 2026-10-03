#!/usr/bin/env bash
# Builds shuai-ffi for iOS device, iOS simulator and macOS, generates Swift
# bindings (UniFFI library mode) and assembles ShuaiCoreFFI.xcframework.
# Idempotent: outputs are wiped and regenerated on every run.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
PKG="$ROOT/apple/ShuaiKit"
OUT="$ROOT/build/xcframework"
XCF="$PKG/ShuaiCoreFFI.xcframework"
GEN_SWIFT="$PKG/Sources/ShuaiCore/Generated"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
LIB=libshuai_ffi.a

rm -rf "$OUT" "$XCF" "$GEN_SWIFT"
mkdir -p "$OUT/bindings" "$GEN_SWIFT"

cd "$CORE"
for t in "${TARGETS[@]}"; do
  echo "==> cargo build --release --target $t"
  cargo build --release -p shuai-ffi --target "$t"
done

echo "==> generating Swift bindings"
cargo run --release -q -p uniffi-bindgen -- generate \
  --library "target/aarch64-apple-darwin/release/$LIB" \
  --language swift --out-dir "$OUT/bindings"

# Headers + modulemap (must be named module.modulemap inside the headers dir).
HEADERS="$OUT/headers"
mkdir -p "$HEADERS"
cp "$OUT"/bindings/*.h "$HEADERS/"
cp "$OUT"/bindings/*.modulemap "$HEADERS/module.modulemap"
cp "$OUT"/bindings/*.swift "$GEN_SWIFT/"

echo "==> creating xcframework"
args=()
for t in "${TARGETS[@]}"; do
  args+=(-library "target/$t/release/$LIB" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${args[@]}" -output "$XCF"
echo "==> done: $XCF"
