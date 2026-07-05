# Queue for Chad — things only you can do

Ordered. Everything else from the top-10 is being executed autonomously
(see git log + DESIGN-APP-OF-THE-YEAR.md matrix updates).

## 00. Miren on the Hetzner box — INSTALLED; 2 things need you
Goal (your ask): miren running on 87.99.152.98, CLI logged in there,
managing all of freeq. Progress made autonomously (2026-07-05), stopped
at two points that genuinely need you. Full plan: `docs/MIREN-FREEQ-PLAN.md`
(minus the irc.freeq.at migration + box resize, which you excluded).

**DONE & verified (prod never disrupted — broker/site/miren all healthy):**
- `miren server` installed as systemd unit `miren` (`--skip-system-check`,
  since the box is 2 GB/13 GB free vs miren's 4 GB/50 GB minimum). Ingress
  set to `behind-proxy-http` on 127.0.0.1:8090 so **nginx keeps :443** and
  coexists. API on :8443. Idle footprint ~223 MB, no pressure.
- Local cluster works (`miren ... -C local`); app.toml schema worked out
  (fixed concurrency + disks + env + `[build] dockerfile=`); the broker
  image imports into miren's containerd fine.

**BLOCKER 1 — cloud registration needs your approval (2 min).**
`miren server register -n freeq` mints a pending registration but it
**never appears in the Freeq-org Clusters page to approve** — because the
box's CLI isn't logged into miren.cloud (its identity is blank). Fix:
run `miren login` ON THE BOX (`ssh root@87.99.152.98`), approve the
device code in your browser, THEN `miren server register -n freeq`; it'll
show up under org-freeq for you to approve. Until this, the box cluster
isn't in your console and can't be driven from your Mac.

**BLOCKER 2 — how to get app images built, on a 2 GB box (your call).**
Deploying the broker (or anything) under miren needs an image. Two paths:
- (a) Let miren BUILD from source — but that's a Rust compile via BuildKit
  on the 2 GB box **that also runs prod auth**; real OOM/thrash risk to
  live sign-ins. I would only do this attended, watching prod. Safer if
  you ever reconsider the resize.
- (b) Deploy a PRE-BUILT image (no compile) — works in principle
  (`[build] dockerfile` = a `FROM <img>` rebase), but miren's BuildKit
  pulls the base from a registry, and miren's built-in registry on :5000
  didn't accept a plain `docker push` (empty catalog / zero-size
  descriptor). Needs figuring out miren's registry auth/push, or standing
  up a small registry BuildKit can read. This is the unblock for
  unattended, prod-safe miren deploys — worth cracking next session.

Net: miren is *running* on the box; making it *manage* freeq is gated on
(1) your login+approve, and (2) settling the image-build path. Nothing is
half-deployed — the box is clean and all three prod services are healthy.

## 0. Auth broker — DONE (moved off miren to the Hetzner box)
`freeq-auth-broker` now runs as a **Docker container on the Hetzner box**
(87.99.152.98), not miren. Why: auth.freeq.at was on the miren *club* org
(org-miren-club) which `chad@blueyard.com` can't deploy to (403), and the
freeq miren org has no cluster yet. Rather than block on org access, we
deployed direct.

Live layout on the box: `docker run freeq-auth-broker` on 127.0.0.1:8081
(image built from freeq-auth-broker/Dockerfile), sessions in the
`freeq-broker-data` volume, `--restart unless-stopped`; nginx vhost
`auth.freeq.at` → :8081 with a Let's Encrypt cert; DNS `auth.freeq.at`
A → 87.99.152.98 (was a CNAME to the miren cluster). Env in
`/root/freeq-broker.env` (BROKER_SHARED_SECRET copied from reth's
.env.secrets, BROKER_PUBLIC_URL, FREEQ_SERVER_URL). Verified live:
health = commit 1b2cadd, `/api/graph/follow` = 401 (not 404), valid TLS.

**Redeploy recipe** (on the box): `cd /root/freeq-build && git fetch &&
git reset --hard origin/main && docker build -f
freeq-auth-broker/Dockerfile -t freeq-auth-broker . && docker rm -f
freeq-auth-broker && docker run -d --name freeq-auth-broker --restart
unless-stopped -p 127.0.0.1:8081:8081 -v freeq-broker-data:/data
--env-file /root/freeq-broker.env freeq-auth-broker`.

Consequences: (a) everyone (you + beings) signs in ONCE — fresh session
DB, old miren sessions don't carry over. (b) The old miren club broker is
now orphaned/unused — fine to leave, or delete from that org later.
(c) The box is now in the prod login path; a nightly off-box copy of the
broker.db volume would be prudent (not yet set up).

## 0b. Deploy the web app (safety + honest 🔒 + status) — 5 min
freeq-app gained block/report/guidelines, real signature verification on
the 🔒 badge (calls /api/v1/verify/{msgid}), and status in DM rows
(commit bc463cd; build + 703 tests green). Deploy irc.freeq.at's web
bundle the usual way (git pull + npm ci + npm run build on the box).
Until deployed, the web 🔒 keeps overstating trust — worth doing soon.

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
