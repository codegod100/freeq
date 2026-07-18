#!/usr/bin/env bash
# Fails the iOS app build if the checked-in FreeqSDK.xcframework is stale
# relative to the Rust FFI source — the exact failure mode that let a
# regenerated `Generated/freeq.swift` reference SDK enum cases the committed
# static lib didn't have (a non-exhaustive-switch compile error, or worse,
# missing symbols at link). Mirrors freeq-macos/scripts/check-ffi-source-fresh.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT="$REPO_ROOT/freeq-ios/FreeqSDK.xcframework/ios-arm64/libfreeq_sdk_ffi.a"
STAMP="$REPO_ROOT/freeq-ios/FreeqSDK.xcframework/ios-arm64/ffi-source.sha256"

if [ ! -f "$ARTIFACT" ]; then
  echo "error: missing iOS FFI artifact: $ARTIFACT" >&2
  echo "Run ./freeq-ios/build-rust.sh before building the iOS app." >&2
  exit 1
fi

if [ ! -f "$STAMP" ]; then
  echo "error: missing iOS FFI artifact fingerprint: $STAMP" >&2
  echo "Run ./freeq-ios/build-rust.sh before building the iOS app." >&2
  exit 1
fi

expected="$(tr -d '[:space:]' < "$STAMP")"
actual="$("$SCRIPT_DIR/ffi-source-fingerprint.sh")"

if [ "$actual" != "$expected" ]; then
  echo "error: iOS Rust FFI artifact is stale." >&2
  echo "Run ./freeq-ios/build-rust.sh, then rebuild the app." >&2
  echo "expected: $expected" >&2
  echo "actual:   $actual" >&2
  exit 1
fi
