# Queue for Chad — things only you can do

Ordered. Everything else from the top-10 is being executed autonomously
(see git log + DESIGN-APP-OF-THE-YEAR.md matrix updates).

## 1. Sign in to the macOS app (2 min)
The old broker token was dead server-side (broker 502s on it — S3). It's
been cleared; the running build shows the sign-in screen. After this one
sign-in, the token lands in the rebuild-proof store and persists across
launches AND rebuilds.

## 1b. Verify the message-list hitch budget on a Release build
The AppKit list rewrite (default now; legacy behind Settings ▸ Advanced ▸
"Use legacy message list") is architecturally sound but its after-numbers
are *projected*, not measured — the hitch harness needs a live window +
main run loop, which couldn't run headlessly. Before treating the Phase-2
gate as closed: Release build, then via DebugBridge run `#stress` (10k
msgs) → `#sweep`, `#editstorm`, `#hitch`. Target <1% (was 43% sweep / 100%
editstorm on the old LazyVStack). Repro is in SPIKE-MESSAGE-LIST.md.

## 1c. Try the new macOS integrations (installed build)
All build; a few need a signed install or one-time registration to fully
light up at runtime:
- **Menu bar extra** — should appear immediately (freeq icon in the menu
  bar): call status, mute/leave, unread jump. Works ad-hoc.
- **Global hotkey ⌥⌘Space** — floating quick-send panel from any app.
  Works ad-hoc.
- **App Intents / Shortcuts** — open Shortcuts.app → search "freeq":
  Send Message, Join Call, Toggle Mute, Set Away, Open Conversation. Also
  drivable by agents. May need the app launched once from /Applications so
  Shortcuts indexes it.
- **Writing Tools** — select text in the composer → right-click / the
  Writing Tools affordance (macOS 15+, Apple Intelligence enabled).
- **Share Extension "Send to freeq"** — appears in other apps' Share menus
  for text/links. This one most needs proper signing to load reliably
  (like the sandbox items). If it doesn't show up under the ad-hoc build,
  it's the signing gap (item 4), not a code bug — verify after Developer ID.
- `freeq://share?text=…&channel=…` URLs work now (test: `open "freeq://share?text=hi"`).

## 2. Dogfood call — 20 minutes with one other person
Verifies a week of AV work that can't be tested solo. Checklist:
- [ ] Speaking rings light up when the other person talks (AudioLevel events)
- [ ] Screen share macOS → web: lands in web's spotlight row, not a camera tile
- [ ] Screen share web → macOS: appears in the letterboxed spotlight row
- [ ] Share button opens the system picker; pick a WINDOW (not just a display)
- [ ] Camera + screen share at the same time
- [ ] Background blur / custom image (camera chevron → Background); check the
      other side sees the processed feed
- [ ] Speaker picker (mic chevron → Speaker) actually reroutes audio
- [ ] Kill Wi-Fi 10s mid-call, re-enable: "Reconnecting…" in the call bar,
      call recovers, no modal, no red apocalypse
- [ ] Mute + talk: "You're talking but muted" hint appears

## 3. Prod deploys (one ssh session, when ready)
On chad@tech.blueyard.com (see memory: deploy = git pull + build + restart):
- [ ] freeq-server with S2 announce scoping (backward-compatible; old clients
      keep working, new scoped clients get server-enforced isolation)
- [ ] freeq-auth-broker with S3 (dead sessions → 401; ends the
      "Reconnecting… forever instead of sign-in" class for everyone)
After the server deploy, say the word and the native FFI + web get flipped
to the scoped dial URL (client patches will be ready and noted in the log).

## 4. Developer ID signing + Sparkle (30 min of Apple-account work)
This permanently kills the "rebuild loses keychain/session" bug class and
unlocks the dogfood update channel (plan §7.1):
- [ ] developer.apple.com → Certificates → create "Developer ID Application"
      (needs your Apple Developer account; I can't do this step)
- [ ] Download + install the cert into your login keychain
- [ ] Tell me the identity name (`security find-identity -v -p codesigning`)
      — I'll wire CODE_SIGN_IDENTITY into project.yml, set up Sparkle
      (package, appcast, EdDSA keys) and the release pipeline from there.

## 5. Track D: name the visual-design owner (decision)
Plan §10 is explicit: engineering gates alone can't win the visuals axis,
and D1 key-screen mockups gate the Phase 2 list rewrite's visual target.
Decide who owns it (external designer? you?) and whether to commission the
Icon Composer icon + six-sound set (D2) now — both have lead time.

## 6. Glance-check the calm-reconnect + escape-hatch UI
Next time the connection blips: quiet spinner banner (no red wash). If the
broker is unreachable 3+ times: "Having trouble restoring your session"
with a Sign In Again… button. Complain if either still feels alarming.
