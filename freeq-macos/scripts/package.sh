#!/usr/bin/env bash
#
# Build a distributable Release .app and zip it. Signing is env-driven so this
# is turnkey the moment the Apple Developer ID cert exists — until then it
# produces an ad-hoc-signed artifact for local testing.
#
#   FREEQ_CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)" \
#   FREEQ_TEAM_ID=TEAMID  ./scripts/package.sh
#
# Env (all optional; defaults give an ad-hoc build):
#   FREEQ_CODESIGN_IDENTITY  code-sign identity (default "-", ad-hoc)
#   FREEQ_TEAM_ID            Apple team id (blank ad-hoc)
#   FREEQ_HARDENED           "YES" to enable Hardened Runtime (needs a real
#                            identity; required for notarization)
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IDENTITY="${FREEQ_CODESIGN_IDENTITY:--}"
TEAM="${FREEQ_TEAM_ID:-}"
HARDENED="${FREEQ_HARDENED:-NO}"

DERIVED="build/ReleaseData"
OUT="build/dist"
mkdir -p "$OUT"

echo "== xcodegen =="
command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

# arm64 only, deliberately. The Rust FFI is built solely for
# aarch64-apple-darwin (see build-rust.sh; FreeqSDK.xcframework declares
# SupportedArchitectures = [arm64]), so any x86_64 slice cannot link:
#   ld: symbol(s) not found for architecture x86_64
# Without pinning ARCHS, xcodebuild picks up the x86_64 destination on an
# Apple Silicon Mac and the Release build fails outright. Shipping Intel would
# mean adding an x86_64 Rust target and lipo-ing a universal static lib first.
echo "== build Release arm64 (identity: $IDENTITY, hardened: $HARDENED) =="
xcodebuild -project freeq-macos.xcodeproj -scheme freeq-macos \
  -configuration Release -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME="$HARDENED" \
  OTHER_CODE_SIGN_FLAGS="$([ "$HARDENED" = YES ] && echo '--options runtime' || echo '')" \
  build >/dev/null

APP="$DERIVED/Build/Products/Release/freeq.app"
[ -d "$APP" ] || { echo "FAIL: build produced no app"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 1)"
ZIP="$OUT/freeq-$VERSION-$BUILD.zip"

echo "== zip → $ZIP =="
rm -f "$ZIP"
# ditto preserves symlinks + code signatures (required for Sparkle/notarize).
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "Artifact: $ZIP"
echo "Version:  $VERSION ($BUILD)"
codesign -dv "$APP" 2>&1 | grep -E 'Authority|Signature|TeamIdentifier' | sed 's/^/  /' || true
if [ "$IDENTITY" = "-" ]; then
  echo "  (ad-hoc — NOT distributable/notarizable. Set FREEQ_CODESIGN_IDENTITY once the Developer ID cert exists.)"
else
  echo "  Next: ./scripts/notarize.sh \"$ZIP\"   then   ./scripts/generate-appcast.sh"
fi
