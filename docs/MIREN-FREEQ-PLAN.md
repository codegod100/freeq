# Plan: all of freeq on the Hetzner box, managed by miren

**Status: PLAN ONLY — not yet executed.** Written 2026-07-05.
Companion doc: `MIGRATION-RETH-TO-HETZNER.md` (the data-migration half,
folded in as Phase 5 here).

**Goal:** the Hetzner box (87.99.152.98) runs a miren server registered to
the **Freeq org** (org-freeq-nmg3r6leb0q5) on miren.cloud, with the CLI
logged in on-box, and every freeq service — auth broker, marketing site,
and production `irc.freeq.at` chat (migrated off reth) — deployed and
managed through `miren deploy`. Zero data loss; minutes of downtime, once.

---

## End state

```
DNSimple                          Hetzner box (87.99.152.98)
  freeq.at, www ──────┐           ┌──────────────────────────────────────┐
  auth.freeq.at ──────┼── :443 ── │ nginx (TLS, all HTTP vhosts)         │
  irc.freeq.at ───────┘           │   │ proxy_pass per vhost             │
                                  │   ▼                                  │
  irc.freeq.at:6667/6697 ── TCP ──│ miren ingress (behind-proxy-http,    │
  irc.freeq.at:8080 ──── UDP/QUIC │   127.0.0.1:8090) + L4 node_ports    │
                                  │   │                                  │
                                  │   ▼  miren server (Freeq org cluster)│
                                  │ apps: freeq-server (prod chat+AV)    │
                                  │       freeq-auth-broker              │
                                  │       freeq-site                     │
                                  └──────────────────────────────────────┘
reth: decommissioned for freeq (rollback standby for ~1 week)
```

## Verified facts (checked 2026-07-05, not assumptions)

- miren **builds Dockerfiles** now (homepage: "…Rust, or a Dockerfile") —
  the old "buildpacks only" blocker is gone. `freeq-server`'s repo-root
  Dockerfile (Rust + npm web build) is buildable.
- miren exposes **raw TCP and UDP** via `[[services.X.ports]]` with
  `type = "tcp"|"udp"` + `node_port` (kernel nftables L4). IRC 6667/6697
  and AV QUIC UDP 8080 are all expressible. `node_port` can't be 80/443/8443.
- miren server has `--ingress-mode behind-proxy-http` + `--ingress-address`
  — it can sit behind the box's existing nginx instead of fighting for :443.
- `miren server install` writes a systemd unit; `miren server register`
  attaches the cluster to miren.cloud (→ Freeq org).
- Hard preflight: **4 GB RAM / 50 GB disk minimum** — the box (2 GB /
  13.5 GB free) must be resized first. Chad is Admin of the Freeq org;
  the same account (`chad@blueyard.com`) works from the box CLI.

## Phase 0 — Resize the box (the only spend)

Hetzner console → ubuntu-2gb-ash-1 → Rescale, **with disk increase**:
- **CPX31 (4 vCPU / 8 GB / 160 GB, ~€16/mo) — recommended** for this scope:
  the box becomes prod chat + AV + broker + site + miren control plane +
  BuildKit, and `freeq-server` release builds are the one genuinely heavy
  job (they already need 8 GB swap on the 2 GB box).
- CPX21 (4 GB / 80 GB, ~€8.5/mo) clears miren's minimum and can work, but
  prod chat + builds + BuildKit cache on 4 GB/80 GB will be tight. Upward
  rescale later is 2 minutes (RAM/CPU), so starting at CPX21 is acceptable
  if cost wins.
- ~2–5 min downtime (site, new.freeq.at, auth broker); everything
  auto-restarts (systemd + Docker restart policies). Verify all three after.

## EXECUTION LOG (2026-07-05, no-resize variant)

Ran Phase 1 partially, hit two real blockers (see `QUEUE-FOR-CHAD.md #00`).
Verified facts to save the next session time:
- `miren server install --skip-system-check` works on 2 GB. Ingress
  override via systemd drop-in `/etc/systemd/system/miren.service.d/override.conf`:
  `MIREN_INGRESS_MODE=behind-proxy-http`, `MIREN_INGRESS_ADDRESS=127.0.0.1:8090`.
  Idle footprint ~223 MB; prod broker/site unaffected.
- Local cluster: `-C local`. Working app.toml keys confirmed by trial:
  `[services.web] port=`, `[services.web.concurrency] mode="fixed" num_instances=1`
  (REQUIRED before disks), `[[services.web.disks]] name/mount_path/size_gb`,
  `[[services.web.env]] key/value`, `[build] dockerfile="Dockerfile"`.
- `image = "..."` on the primary service is NOT enough — miren still runs
  stack detection and a build. A `[build] dockerfile=` with a `FROM <img>`
  rebase is accepted, but BuildKit pulls the base from a **registry**, not
  the local containerd (importing into containerd ns `miren` didn't help).
- miren's built-in registry listens on :5000 but a plain `docker push
  localhost:5000/...` reported success yet left an empty catalog and
  BuildKit saw a zero-size descriptor. **Open problem:** the correct way to
  get a pre-built image where miren's BuildKit can pull it (registry
  auth/creds, or a sidecar registry). Cracking this = unattended,
  prod-safe deploys without a Rust compile on the 2 GB box.
- Cloud registration mints a pending reg but it doesn't surface in the
  Freeq-org console because the box CLI has no miren.cloud identity —
  `miren login` on the box first, then `register`.

## Phase 1 — miren on the box, registered to the Freeq org

1. `miren server install -n freeq` … with env overrides in the unit:
   `MIREN_INGRESS_MODE=behind-proxy-http`,
   `MIREN_INGRESS_ADDRESS=127.0.0.1:8090`, `MIREN_SERVER_ADDRESS=0.0.0.0:8443`,
   data path on the resized disk. Start + verify `systemctl status`.
2. `miren server register -n freeq` → attach to miren.cloud → **appears as
   the Freeq org's cluster** (expect a one-click approval in the console).
3. On-box CLI login (`miren login`, device flow, chad@blueyard.com) and
   from the Mac: `miren cluster add` for the box (address + fingerprint via
   `miren cluster export-address`). Deploys then work from either machine.
4. ufw is inactive; if we enable anything later, 8443/tcp (miren API) plus
   the node_ports must stay open.

## Phase 2 — Pilot app: auth broker under miren (lowest risk)

1. `.miren/app.toml` for `freeq-auth-broker`: Dockerfile build (the file
   from commit 060fa9d), a `web` service on 8081, **persistent volume
   addon** mounted at `/data`, env from the current `/root/freeq-broker.env`.
2. Deploy; **copy the live `broker.db`** from the `freeq-broker-data`
   Docker volume into the miren volume (stop broker ~30 s during copy so
   the SQLite file is quiescent → **no user re-login**, sessions carry).
3. Point the nginx `auth.freeq.at` vhost at the miren ingress
   (`proxy_pass http://127.0.0.1:8090` + Host header) instead of :8081.
4. Verify: health hash, `/api/graph/follow` = 401, one real sign-in, one
   Follow tap. Then retire the hand-run Docker container (keep its volume
   as a cold backup for a week).

## Phase 3 — freeq-site under miren

Buildpack or Dockerfile app from `freeq-site/`; nginx `freeq.at` vhost →
miren ingress. Retire `freeq-site.service` (gunicorn systemd). Lowest
stakes; also the second data point that routing-behind-nginx works.

## Phase 4 — Dress rehearsal: new.freeq.at chat under miren  ← GATE

This is the full test of everything prod needs, on the non-prod instance:
- App from repo root (`Dockerfile`), `app.toml` services:
  web (8080, HTTP through ingress incl. **WebSocket /irc** — verify
  upgrade headers survive nginx → miren ingress → app),
  `[[ports]]`: **TCP 6667**… but note: `node_port`s are **globally unique
  per cluster** — new.freeq.at must use throwaway ports (e.g. 16667) so
  prod can own the real 6667/6697/8080 later. That's fine for a rehearsal.
- Persistent volume for `/data` (irc.db etc.), migrated from the current
  `freeq-data` Docker volume.
- **Exit criteria (all must pass before Phase 5):** web client works,
  WSS chat works, native IRC connects via the TCP node_port, AV call works
  over the UDP node_port, container restart keeps data, `miren deploy` of
  a trivial change redeploys cleanly, and build peak RAM/disk observed and
  acceptable.

## Phase 5 — Migrate prod irc.freeq.at (reth → box, via miren)

Exactly `MIGRATION-RETH-TO-HETZNER.md`, with the target being a miren app
instead of a hand-run container. Summary of that plan + deltas:

**Pre-flight (no downtime, ≥1 day ahead):**
1. Decisions from that doc: federation keep/drop (recommend drop),
   native 6697 TLS cert mount, native AV QUIC — under miren these become
   `app.toml` ports: TCP 6667, TCP 6697, UDP 8080 as `node_port`s
   (released by the Phase-4 rehearsal app first — uniqueness).
2. Lower `irc.freeq.at` TTL → 60–300 in DNSimple (use the API token /
   dnsimple CLI — no browser, no delete-then-add gap; **add-before-remove**,
   lesson from the auth flip's 5-min negative-cache blip).
3. Pre-issue the `irc.freeq.at` cert on the box via **certbot DNS-01**
   (DNSimple token) + stage the nginx vhost → miren ingress.
4. Stage the prod app config: `--server-name irc.freeq.at`, env from
   reth's `.env.secrets` (BROKER_SHARED_SECRET already matches the broker).
5. **Hot pre-sync** (WAL-safe): `sqlite3 irc.db "VACUUM INTO …"` (+
   `irc-policy.db`) and rsync snapshots + `media/` + all `*.secret`
   (`db-encryption-key.secret` is make-or-break) into the app's volume.

**Cutover (the only downtime, ~5 min):**
1. `systemctl stop freeq-server` on reth (stops writes; reth data intact).
2. Delta sync: re-VACUUM + rsync the diff (seconds).
3. Start the miren prod app pointing at the synced volume.
4. Flip `irc.freeq.at` A → 87.99.152.98 (dnsimple CLI, add-first).
5. Verify: health, same `did:web` verify key, login via auth.freeq.at,
   history + DMs decrypt, media downloads, row counts match, native IRC
   6697, an AV call. IRC/WS clients reconnect on their own.

**Rollback:** DNS back to 160.202.129.155 + `systemctl start freeq-server`
on reth. Reth keeps authoritative data untouched for ≥1 week.

## Phase 6 — Aftercare

- Nightly off-box backups (cron → reth or object storage): miren volumes
  for irc.db, media, broker.db. The box is now the single point of failure
  for ALL of freeq — backups stop being optional.
- Retire: reth freeq-server (after the standby week), the hand-run Docker
  containers, the old miren-club broker app, `new.freeq.at` (or keep as a
  staging app — useful for Phase-4-style rehearsals forever).
- Update `QUEUE-FOR-CHAD.md`, memory docs, and `freeq-prod-deploy` notes:
  the deploy story becomes **`miren deploy` from anywhere, visible in the
  Freeq org console**.

## Risks / open questions (tracked, each with a gate)

| Risk | Mitigation / gate |
|---|---|
| WebSocket upgrade through nginx→miren-ingress chain | Phase 4 exit criteria |
| freeq-server build resource spike under BuildKit | Phase 4 observes peak; CPX31 recommended |
| node_port global uniqueness (rehearsal vs prod ports) | rehearsal uses 16xxx ports; swap at Phase 5 |
| miren server itself becomes part of the SPOF | systemd auto-restart; apps keep running if control plane hiccups; Phase 6 backups |
| Registration/org flow needs console approval | Chad present for Phase 1 step 2 |
| SQLite copy consistency | VACUUM INTO snapshots + stopped-writes delta at cutover |

## What Chad personally does (everything else is autonomous)

1. Phase 0: the rescale click (or hand over an hcloud API token).
2. Phase 1: approve the cluster registration in the miren console (likely
   one click), and the device-flow login on the box.
3. Phase 5: say GO for the cutover window (suggest a quiet hour).

## Rough timeline

Phase 0–1: ~1 hour (mostly resize + install). Phase 2–3: ~1–2 hours.
Phase 4: ~2–3 hours incl. verification. Phase 5: pre-flight ~1 hour, then
a ~5-minute cutover whenever you call it. Total: comfortably one day, with
the prod cutover as its own deliberate moment.
