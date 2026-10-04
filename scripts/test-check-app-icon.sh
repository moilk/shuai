#!/usr/bin/env bash
# Self-test for check-app-icon.sh: compiles a tiny catalog with and without dark/tinted AppIcon
# variants using actool, then expects the guard to accept the complete one and reject the other.
# macOS with Xcode only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SET="$HERE/../apple/App/Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

compile() { # compile <catalog> <out-app-dir>
  mkdir -p "$2"
  xcrun actool "$1" --compile "$2" --platform iphoneos --minimum-deployment-target 18.0 \
    --app-icon AppIcon --target-device ipad --output-partial-info-plist "$TMP/partial.plist" \
    >/dev/null
}

full="$TMP/full.xcassets"
mkdir -p "$full/AppIcon.appiconset"
cp "$SET"/*.png "$SET/Contents.json" "$full/AppIcon.appiconset/"
compile "$full" "$TMP/full.app"

partial="$TMP/partial.xcassets"
mkdir -p "$partial/AppIcon.appiconset"
cp "$SET/AppIcon-light.png" "$partial/AppIcon.appiconset/"
cat >"$partial/AppIcon.appiconset/Contents.json" <<'JSON'
{ "images" : [ { "filename" : "AppIcon-light.png", "idiom" : "universal",
                 "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
JSON
compile "$partial" "$TMP/partial.app"

"$HERE/check-app-icon.sh" "$TMP/full.app" >/dev/null \
  || { echo "FAIL: complete catalog rejected"; exit 1; }
set +e
"$HERE/check-app-icon.sh" "$TMP/partial.app" >/dev/null 2>&1
rc=$?
"$HERE/check-app-icon.sh" "$TMP/nothing.app" >/dev/null 2>&1
rc_missing=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL: light-only catalog exit $rc, expected 1"; exit 1; }
[ "$rc_missing" -eq 2 ] || { echo "FAIL: missing app exit $rc_missing, expected 2"; exit 1; }
echo "ok"
