#!/usr/bin/env bash
# Builds shuai-ffi for iOS device, iOS simulator and macOS, generates Swift
# bindings (UniFFI library mode) and assembles ShuaiCoreFFI.xcframework.
# Idempotent: outputs are wiped and regenerated on every run.
#
# SHUAI_FFI_TESTKIT=1 builds shuai-ffi with the `testkit` cargo feature (exports
# `startTestSshServer()`, an in-process SSH server) into ALL slices, so the generated Swift
# bindings match every slice, and drops a marker file that makes Package.swift compile the
# real-SSH Swift tests. Dev/CI only: never ship an xcframework built this way.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
PKG="$ROOT/apple/ShuaiKit"
OUT="$ROOT/build/xcframework"
XCF="$PKG/ShuaiCoreFFI.xcframework"
GEN_SWIFT="$PKG/Sources/ShuaiCore/Generated"
# Match the Swift package deployment targets (avoids linker version warnings).
export MACOSX_DEPLOYMENT_TARGET=15.0 IPHONEOS_DEPLOYMENT_TARGET=18.0
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
LIB=libshuai_ffi.a
FEATURES=()
MARKER="$PKG/.shuai-testkit"
rm -f "$MARKER"
if [ "${SHUAI_FFI_TESTKIT:-0}" = "1" ]; then
  FEATURES=(--features testkit)
  touch "$MARKER"
fi

rm -rf "$OUT" "$XCF" "$GEN_SWIFT"
mkdir -p "$OUT/bindings" "$GEN_SWIFT"

cd "$CORE"
for t in "${TARGETS[@]}"; do
  echo "==> cargo build --release --target $t"
  cargo build --release -p shuai-ffi --target "$t" ${FEATURES[@]+"${FEATURES[@]}"}
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
