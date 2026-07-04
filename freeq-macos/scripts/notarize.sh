#!/usr/bin/env bash
#
# Notarize a packaged .zip with Apple and staple the ticket, so Gatekeeper
# allows it on other Macs with no prompt. Requires a Developer ID-signed
# artifact (see package.sh) and notarization credentials.
#
#   ./scripts/notarize.sh build/dist/freeq-1.0.0-1.zip
#
# Credentials — either a stored keychain profile OR the three env vars:
#   FREEQ_NOTARY_PROFILE   name of a `xcrun notarytool store-credentials` profile
#   -- or --
#   FREEQ_APPLE_ID, FREEQ_APPLE_PASSWORD (app-specific), FREEQ_TEAM_ID
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ZIP="${1:?usage: notarize.sh <zip>}"
[ -f "$ZIP" ] || { echo "not found: $ZIP"; exit 1; }

if [ -n "${FREEQ_NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$FREEQ_NOTARY_PROFILE")
else
  : "${FREEQ_APPLE_ID:?set FREEQ_NOTARY_PROFILE or FREEQ_APPLE_ID/PASSWORD/TEAM_ID}"
  AUTH=(--apple-id "$FREEQ_APPLE_ID" --password "${FREEQ_APPLE_PASSWORD:?}" --team-id "${FREEQ_TEAM_ID:?}")
fi

echo "== submit (waits for Apple) =="
xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait

# Stapling attaches the ticket to the .app so it verifies offline. Unzip,
# staple the app, re-zip.
TMP="$(mktemp -d)"
/usr/bin/ditto -x -k "$ZIP" "$TMP"
APP="$(/usr/bin/find "$TMP" -maxdepth 1 -name '*.app' | head -1)"
echo "== staple $APP =="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
rm -rf "$TMP"
echo "Notarized + stapled: $ZIP"
