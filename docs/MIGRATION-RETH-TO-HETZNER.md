# Migrating production freeq (reth → Hetzner) with zero data loss

**Goal:** make the Hetzner box (`87.99.152.98`, now serving `new.freeq.at`)
*become* production `irc.freeq.at`, carrying **all** data, with minimal downtime.

**Why not federation:** S2S only replicates channel governance + live messages —
not history, DMs, media, pre-keys, group keys, or the encryption/signing keys.
It also makes the new box a *peer*, not a *clone*. So we migrate by copying the
(tiny) durable state and having the new box assume prod's identity.

---

## What moves (all of it small)

From reth `/home/chad/src/freeq/`:

| File | Holds | Critical? |
|---|---|---|
| `irc.db` (6.4M) | channels, messages, history, membership, DMs (ciphertext), pre-key bundles, group keys | yes |
| `irc-policy.db` (536K) | policies + issued credentials | yes |
| `media/` (3.8M) | uploaded files (encrypted at rest) | yes |
| `db-encryption-key.secret` | at-rest message decryption | **MAKE-OR-BREAK** — without it, all history is unreadable |
| `msg-signing-key.secret` | server message-signing identity | yes (signature continuity) |
| `verifier-signing-key.secret` | `did:web:irc.freeq.at:verify` credential key | yes (existing credentials stay valid) |
| `iroh-key.secret` | federation identity | only if keeping federation |
| `.env.secrets` | `BROKER_SHARED_SECRET`, GitHub OAuth, etc. | yes (see auth below) |

Target: the Hetzner container's `freeq-data` Docker volume (`/data` inside).

---

## Decisions to make first

1. **Auth broker.** `auth.freeq.at` is a CNAME → a miren cluster (NOT reth), so it
   survives the migration. The web client, when served at `irc.freeq.at`, uses
   `https://auth.freeq.at` as its OAuth broker (ConnectScreen.tsx:144). So the new
   server must be able to talk to that broker: set **`BROKER_SHARED_SECRET`** (from
   reth's `.env.secrets`) on the new container so broker tokens validate. (The new
   box's built-in OAuth is unused when served at irc.freeq.at — the broker path is.)
2. **Federation.** Prod runs `--iroh --s2s-allowed-peers 7e2a8c3a…`. Decide:
   keep it (copy `iroh-key.secret`, run the container with `--iroh` + the same
   allowlist, and expose the iroh UDP port) or drop it (simpler; the peer link
   ends). For a single-instance prod, dropping federation is cleaner.
3. **Native IRC-over-TLS (6697).** nginx is HTTP-only, so native IRC clients on
   `irc.freeq.at:6697` won't work unless we publish the container's 6697 with a
   cert. If everyone uses the web app, skip it. Otherwise: `-p 6697:6697` + mount
   the irc.freeq.at cert + `--tls-cert/--tls-key`.
4. **AV.** Web AV (MoQ-over-WebSocket) works through nginx. Native AV-over-QUIC
   (UDP) needs a published UDP port; add it only if native AV clients matter.
5. **Resize** the box to ≥8 GB first (headroom for prod load + rebuilds).

---

## Pre-flight (no downtime, do a day ahead)

1. **Lower `irc.freeq.at` DNS TTL** 3600 → 300 (via DNSimple) so the eventual
   flip propagates in ~5 min. (Do this ≥1 hour ahead; ideally a day.)
2. **Pre-provision the `irc.freeq.at` TLS cert on the Hetzner box** using
   **certbot DNS-01** with the DNSimple token — no DNS change needed yet:
   `certbot certonly --dns-... -d irc.freeq.at`. (Or `certbot --nginx` at cutover;
   DNS-01 lets us do it in advance.)
3. **Add the `irc.freeq.at` nginx vhost** on the box (same proxy → `127.0.0.1:8080`
   as new.freeq.at), using the cert from step 2. Don't rely on it until DNS flips.
4. **Stage the container config**: prepare the run command with
   `--server-name irc.freeq.at`, `--motd …`, `-e BROKER_SHARED_SECRET=…`, and the
   federation/6697 flags per the decisions above.
5. **Initial data sync (hot, no downtime):** WAL-mode `irc.db` allows a consistent
   snapshot live —
   `sqlite3 irc.db "VACUUM INTO '/tmp/irc.db'"` (+ policy), then `rsync` the
   snapshots + `media/` + all `*.secret` to the box. This pre-seeds the bulk.

---

## Cutover (the only downtime — a few minutes)

1. **Stop prod writes:** `systemctl stop freeq-server` on reth.
2. **Final delta sync:** re-run the `VACUUM INTO` + `rsync` of `irc.db`,
   `irc-policy.db`, and `media/` (only the delta since the pre-sync). Seconds.
3. **Load into the box:** stop the container, copy the DBs + `media/` + `*.secret`
   into the `freeq-data` volume (`/var/lib/docker/volumes/freeq-data/_data`), then
   start the container with the `irc.freeq.at` config from pre-flight step 4.
4. **Flip DNS:** `irc.freeq.at` A → `87.99.152.98` (DNSimple; TTL already 300).
5. **Verify** (below). Total downtime ≈ stop→start + DNS propagation (~5 min).

Note: because `--server-name irc.freeq.at` + the copied `verifier-signing-key.secret`
+ `db-encryption-key.secret` all move, the new box serves the **same** `did:web`
document/key and decrypts the **same** history — it *is* prod, on new hardware.

---

## Verify

- `https://irc.freeq.at/api/v1/health` → 200; valid cert.
- `https://irc.freeq.at/verify/.well-known/did.json` → same key as before (credential continuity).
- Web app loads, OAuth login works (via auth.freeq.at broker), channels + **history** present, DMs decrypt, a known uploaded file downloads.
- `sqlite3` row counts on the box match reth's pre-cutover counts.

## Rollback (clean, because prod is only stopped, not deleted)

If anything's wrong: flip `irc.freeq.at` DNS back to `160.202.129.155`,
`systemctl start freeq-server` on reth. Reth still has the authoritative data
(we only copied it). Keep reth intact for a few days before decommissioning.

## After

- `new.freeq.at` can stay as an alias (already points at the box) or be retired.
- Decommission reth's freeq-server once you're confident.
