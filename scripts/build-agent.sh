#!/usr/bin/env bash
# Cross-builds shuai-agent (static musl, stripped) for the Linux hosts the app installs it on and
# copies the binaries to apple/App/Resources/agent/ (gitignored) as shuai-agent-<target-triple>.
# The App target bundles that folder; AgentBinaryProvider finds the files by triple at runtime.
# Needs: zig, cargo-zigbuild, rustup targets x86_64/aarch64-unknown-linux-musl.
#
# Usage: scripts/build-agent.sh [target-triple ...]   (default: both)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/apple/App/Resources/agent"
TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl)
fi

command -v cargo-zigbuild >/dev/null || { echo "cargo-zigbuild not found (cargo install cargo-zigbuild --locked)" >&2; exit 1; }
command -v zig >/dev/null || { echo "zig not found (brew install zig)" >&2; exit 1; }

mkdir -p "$OUT"
cd "$ROOT/core"
for t in "${TARGETS[@]}"; do
  echo "==> cargo zigbuild --release -p shuai-agent --target $t"
  rustup target add "$t" >/dev/null 2>&1 || true
  # Strip through cargo/rustc: macOS `strip` cannot handle ELF.
  CARGO_PROFILE_RELEASE_STRIP=symbols cargo zigbuild --release -p shuai-agent --target "$t"
  cp "target/$t/release/shuai-agent" "$OUT/shuai-agent-$t"
  chmod 755 "$OUT/shuai-agent-$t"
  echo "    $(du -h "$OUT/shuai-agent-$t" | cut -f1)  $OUT/shuai-agent-$t"
done
