#!/usr/bin/env bash
# Release guard: fails if the XCFramework contains the in-process test SSH server
# (`start_test_ssh_server`, compiled in by SHUAI_FFI_TESTKIT=1). A testkit build must never
# be shipped: it embeds a server with hard-coded credentials.
#
# Usage: scripts/check-no-testkit.sh [path/to/ShuaiCoreFFI.xcframework]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCF="${1:-$ROOT/apple/ShuaiKit/ShuaiCoreFFI.xcframework}"
SYMBOL="start_test_ssh_server"

if [ ! -d "$XCF" ]; then
  echo "check-no-testkit: $XCF not found (build it first)" >&2
  exit 2
fi

libs=()
while IFS= read -r l; do libs+=("$l"); done < <(find "$XCF" -name '*.a' -type f)
if [ "${#libs[@]}" -eq 0 ]; then
  echo "check-no-testkit: no static libraries in $XCF" >&2
  exit 2
fi

bad=0
for lib in "${libs[@]}"; do
  # `nm -g` lists external symbols; stderr is noise about non-object members.
  if nm -g "$lib" 2>/dev/null | grep -q "$SYMBOL"; then
    echo "check-no-testkit: FAIL: $lib exports $SYMBOL (built with SHUAI_FFI_TESTKIT=1)" >&2
    bad=1
  fi
done
if [ "$bad" -ne 0 ]; then
  echo "Rebuild without SHUAI_FFI_TESTKIT: scripts/build-xcframework.sh" >&2
  exit 1
fi
echo "check-no-testkit: ok (${#libs[@]} slices clean)"
