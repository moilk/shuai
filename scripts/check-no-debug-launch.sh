#!/usr/bin/env bash
# Release guard: the DEBUG-only launch arguments (-debugAutoAcceptHostKey, -debugHostFile,
# -debugSendAfterConnect, -debugConnectionState, -debugTerminal, -uiTesting) must be compiled out of Release builds.
# -debugAutoAcceptHostKey in particular would silently disable TOFU host key verification.
#
# Builds the app in Release for the iOS simulator and runs `strings` over the executable (and
# any embedded dylibs). Pass an existing .app to skip the build.
#
# Usage: scripts/check-no-debug-launch.sh [path/to/Shuai.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP="${1:-}"

if [ -z "$APP" ]; then
  DERIVED="$(mktemp -d)"
  trap 'rm -rf "$DERIVED"' EXIT
  (cd "$ROOT/apple/App" && xcodegen generate >/dev/null)
  (cd "$ROOT/apple/App" && xcodebuild build -scheme Shuai -configuration Release \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" -quiet >/dev/null)
  APP="$DERIVED/Build/Products/Release-iphonesimulator/Shuai.app"
fi

if [ ! -d "$APP" ]; then
  echo "check-no-debug-launch: $APP not found" >&2
  exit 2
fi

# The main binary plus the debug dylib Xcode may split out; everything Mach-O in the bundle.
bad=0
while IFS= read -r bin; do
  if ! file "$bin" | grep -q "Mach-O"; then continue; fi
  # Capture once: `strings | grep -q` under pipefail reports SIGPIPE as "not found".
  text="$(strings -a "$bin")"
  # (Short literals such as "-uiTesting" are stored inline by Swift and invisible to `strings`;
  # they are compiled out with #if DEBUG all the same.)
  for needle in debugAutoAcceptHostKey debugHostFile debugSendAfterConnect debugConnectionState debugTerminal debugByteTap debugDelayReplies DebugLaunch; do
    if grep -q "$needle" <<<"$text"; then
      echo "check-no-debug-launch: FAIL: $bin contains '$needle'" >&2
      bad=1
    fi
  done
done < <(find "$APP" -type f)

if [ "$bad" -ne 0 ]; then
  echo "DEBUG-only launch arguments must be wrapped in #if DEBUG." >&2
  exit 1
fi
echo "check-no-debug-launch: ok ($APP)"
