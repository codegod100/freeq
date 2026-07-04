#!/usr/bin/env bash
#
# Generate the Sparkle EdDSA update-signing keypair. The PRIVATE key is stored
# in your login keychain (never in the repo); the PUBLIC key is printed for
# SUPublicEDKey in Info.plist. This signing is Sparkle's own and is independent
# of Apple code signing — so it can be set up before the Apple account clears,
# but it only matters once you ship an appcast.
#
#   ./scripts/sparkle-keys.sh
#
# Requires Sparkle's `generate_keys` tool (ships with the Sparkle SPM
# package / release). Set SPARKLE_BIN to its bin/ dir if not on PATH.
set -euo pipefail

GEN="${SPARKLE_BIN:+$SPARKLE_BIN/}generate_keys"
if ! command -v "$GEN" >/dev/null 2>&1; then
  echo "generate_keys not found — add the Sparkle SPM package or set SPARKLE_BIN."
  echo "See docs/DISTRIBUTION.md."
  exit 1
fi

echo "== generate_keys (private key → keychain) =="
"$GEN"
echo
echo "Copy the printed public key into project.yml → info.properties.SUPublicEDKey,"
echo "then re-run xcodegen generate. Keep the private key in the keychain only."
