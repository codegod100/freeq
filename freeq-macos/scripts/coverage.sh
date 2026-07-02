#!/usr/bin/env bash
# Line-coverage report for the SwiftPM-tested core (FreeqMacosCore).
#
#   ./scripts/coverage.sh          # per-file table + total
#   ./scripts/coverage.sh --html   # also emit an HTML report to .build/coverage/
#
# Scope note: this measures the files compiled into FreeqMacosCore (the
# pure-logic layer listed in Package.swift). SwiftUI views and the
# AVFoundation/FFI shims are exercised by the app build + ui-sweep.sh, not
# by unit coverage.
set -euo pipefail
cd "$(dirname "$0")/.."

# swift test needs the full Xcode toolchain for XCTest; CommandLineTools
# doesn't ship it.
if ! xcrun --find xctest >/dev/null 2>&1; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

swift test --enable-code-coverage >/dev/null

BIN_PATH="$(swift build --show-bin-path)"
PROFDATA="$BIN_PATH/codecov/default.profdata"
XCTEST_BUNDLE="$(find "$BIN_PATH" -maxdepth 1 -name '*.xctest' | head -1)"
BINARY="$XCTEST_BUNDLE/Contents/MacOS/$(basename "$XCTEST_BUNDLE" .xctest)"

echo "── FreeqMacosCore line coverage ──"
xcrun llvm-cov report "$BINARY" \
  -instr-profile "$PROFDATA" \
  -ignore-filename-regex='(Tests|\.build)/'

if [[ "${1:-}" == "--html" ]]; then
  OUT=".build/coverage"
  xcrun llvm-cov show "$BINARY" \
    -instr-profile "$PROFDATA" \
    -ignore-filename-regex='(Tests|\.build)/' \
    -format=html -output-dir="$OUT"
  echo "HTML report: $OUT/index.html"
fi
