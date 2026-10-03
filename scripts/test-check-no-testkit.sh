#!/usr/bin/env bash
# Self-test for check-no-testkit.sh using tiny fake static libraries in a fake xcframework.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mk() { # mk <xcframework-dir> <symbol>
  local dir="$1" sym="$2"
  mkdir -p "$dir/slice-a" "$dir/slice-b"
  for s in slice-a slice-b; do
    printf 'void %s(void) {}\n' "$sym" >"$TMP/x.c"
    clang -c "$TMP/x.c" -o "$TMP/x.o"
    ar rcs "$dir/$s/libshuai_ffi.a" "$TMP/x.o"
  done
}

mk "$TMP/clean.xcframework" "uniffi_shuai_ffi_fn_func_ping"
mk "$TMP/dirty.xcframework" "uniffi_shuai_ffi_fn_func_start_test_ssh_server"

"$HERE/check-no-testkit.sh" "$TMP/clean.xcframework" >/dev/null \
  || { echo "FAIL: clean xcframework rejected"; exit 1; }
if "$HERE/check-no-testkit.sh" "$TMP/dirty.xcframework" >/dev/null 2>&1; then
  echo "FAIL: testkit xcframework accepted"; exit 1
fi
if "$HERE/check-no-testkit.sh" "$TMP/missing.xcframework" >/dev/null 2>&1; then
  echo "FAIL: missing xcframework accepted"; exit 1
fi
echo "ok"
