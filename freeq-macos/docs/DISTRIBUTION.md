# macOS distribution runbook

How to ship signed, notarized, auto-updating builds of freeq for Mac. The
scripts and config are in place now; the steps marked **[account]** are gated
on Apple Developer Program approval (see `../../docs/DEVELOPER-ACCOUNT-TODO.md`).

Pipeline: **build+sign → notarize → appcast → users auto-update via Sparkle.**

---

## Signing (`scripts/package.sh`)
Env-driven so nothing here changes the working dev build:

```sh
# Ad-hoc (works today, NOT distributable):
./scripts/package.sh

# [account] Real Developer ID build, hardened runtime on (required to notarize):
FREEQ_CODESIGN_IDENTITY="Developer ID Application: <You> (<TEAMID>)" \
FREEQ_TEAM_ID=<TEAMID> FREEQ_HARDENED=YES \
  ./scripts/package.sh
```
Output: `build/dist/freeq-<version>-<build>.zip` (via `ditto`, which preserves
the signature — required for notarization and Sparkle).

**[account]** Get the cert: developer.apple.com → Certificates → *Developer ID
Application* → download → install into the login keychain →
`security find-identity -v -p codesigning` to read the identity string.

---

## Notarize (`scripts/notarize.sh`) **[account]**
```sh
# One-time: store credentials in the keychain
xcrun notarytool store-credentials freeq-notary \
  --apple-id <you@apple> --team-id <TEAMID> --password <app-specific-pw>

FREEQ_NOTARY_PROFILE=freeq-notary ./scripts/notarize.sh build/dist/freeq-<v>-<b>.zip
```
Submits, waits for Apple, staples the ticket, re-zips. After this Gatekeeper
allows the app on any Mac with no prompt.

---

## Auto-update with Sparkle
Sparkle signs updates with its OWN EdDSA key (independent of Apple signing),
so this half can be prepared without the account — but a real update cycle
can only be validated once you have a notarized build + a hosted appcast.

### One-time setup
1. **Add the Sparkle SPM package** to `project.yml` under the app target's
   `dependencies:` (then `xcodegen generate`):
   ```yaml
   packages:
     Sparkle:
       url: https://github.com/sparkle-project/Sparkle
       majorVersion: 2
   targets:
     freeq-macos:
       dependencies:
         - package: Sparkle
   ```
   Sandbox note: Sparkle 2 ships sandbox-compatible XPC services; follow
   Sparkle's "Sandboxing" guide for the `Downloader`/`Installer` XPC
   entitlements. This is why it's a deliberate, tested step rather than
   pre-wired — a broken updater is worse than none.

2. **Generate the EdDSA keypair** (`scripts/sparkle-keys.sh`): stores the
   private key in your keychain and prints the public key.

3. **Add Info.plist keys** (in `project.yml` `info.properties`):
   ```yaml
   SUFeedURL: https://<host>/appcast.xml
   SUPublicEDKey: <public key from step 2>
   SUEnableInstallerLauncherService: true   # sandbox
   ```

4. **Wire the updater**: an `SPUStandardUpdaterController` in `App.swift` and a
   "Check for Updates…" menu item bound to `updater.checkForUpdates(_:)`. (Not
   pre-added because it needs the SPM package above to compile.)

### Each release
```sh
./scripts/package.sh          # (with the [account] signing env)
./scripts/notarize.sh <zip>   # [account]
./scripts/generate-appcast.sh # signs the update, updates appcast.xml
# upload build/dist/*.zip + build/dist/appcast.xml to the SUFeedURL host
```
Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` per
release so Sparkle sees the new version.

---

## Verify before every submission
- `codesign -dv --verbose=4 freeq.app` → Developer ID authority, hardened runtime.
- `xcrun stapler validate freeq.app` → notarization ticket stapled.
- `spctl -a -vvv freeq.app` → “accepted, source=Notarized Developer ID”.
- `./scripts/smoke.sh <app>` → core interactions pass on the release build.
