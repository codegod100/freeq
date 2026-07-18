#!/usr/bin/env bash
#
# Generate/update the Sparkle appcast from the packaged builds in build/dist,
# then you upload build/dist/*.zip + appcast.xml to the SUFeedURL host. Sparkle
# signs each update with the EdDSA private key in your keychain (see
# scripts/sparkle-keys.sh) — that signing is independent of Apple code signing.
#
#   ./scripts/generate-appcast.sh
#
# Requires Sparkle's `generate_appcast` tool. After adding the Sparkle SPM
# package it lives under the checkout's artifacts; or install the Sparkle
# release and point SPARKLE_BIN at its bin/ dir.
set -euo pipefail
cd "$(dirname "$0")/.."

DIST="build/dist"
[ -d "$DIST" ] || { echo "no $DIST — run ./scripts/package.sh first"; exit 1; }

GEN="${SPARKLE_BIN:+$SPARKLE_BIN/}generate_appcast"
if ! command -v "$GEN" >/dev/null 2>&1; then
  cat <<'EOF'
generate_appcast not found. Get it one of two ways:
  1. After adding the Sparkle SPM package to project.yml, it's in
     ~/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin
  2. Download the Sparkle release tarball and set:
     export SPARKLE_BIN=/path/to/Sparkle/bin
See docs/DISTRIBUTION.md.
EOF
  exit 1
fi

echo "== generate_appcast over $DIST =="
"$GEN" "$DIST"
echo "Appcast: $DIST/appcast.xml — upload it + the .zip(s) to your SUFeedURL host."
