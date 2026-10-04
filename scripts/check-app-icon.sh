#!/usr/bin/env bash
# Build guard: fails if a built .app's compiled asset catalog lacks the AppIcon renditions for the
# default (light), dark and tinted appearances (iOS 18 appearance-aware icon).
#
# Usage: scripts/check-app-icon.sh path/to/Shuai.app
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ] || [ ! -f "$APP/Assets.car" ]; then
  echo "check-app-icon: usage: $0 <built .app> (Assets.car not found${APP:+ in $APP})" >&2
  exit 2
fi

# `assetutil --info` prints a JSON array; icon variants are "Icon Image" entries named AppIcon.
# The default appearance has no "Appearance" key; dark is UIAppearanceDark, tinted is
# ISAppearanceTintable.
info="$(xcrun assetutil --info "$APP/Assets.car")"

count() { # $1 = jq-less filter on python
  printf '%s' "$info" | python3 -c '
import json, sys
want = sys.argv[1]
n = 0
for e in json.load(sys.stdin):
    if e.get("AssetType") != "Icon Image" or e.get("Name") != "AppIcon":
        continue
    a = e.get("Appearance")
    if (want == "light" and a is None) or a == want:
        n += 1
print(n)
' "$1"
}

bad=0
for pair in "light:default" "UIAppearanceDark:dark" "ISAppearanceTintable:tinted"; do
  key="${pair%%:*}"
  n="$(count "$key")"
  if [ "$n" -lt 1 ]; then
    echo "check-app-icon: FAIL: no AppIcon rendition for the ${pair##*:} appearance in $APP/Assets.car" >&2
    bad=1
  fi
done
if [ "$bad" -ne 0 ]; then
  exit 1
fi
echo "check-app-icon: ok (default, dark and tinted AppIcon renditions present)"
