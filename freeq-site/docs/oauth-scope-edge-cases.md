# OAuth scope narrowing — deploy-readiness review

This document captures every realistic way the Phase 1 (narrow default
scope) + Phase 2 (per-feature step-up) change could break for an
existing user or a partial deploy, what the system does in each case,
and what's left to address. Pair this with the live smoke transcript
in [`oauth-scope-smoke.md`](./oauth-scope-smoke.md) and the test files
under `freeq-server/tests/oauth_scope.rs` and
`freeq-app/src/lib/oauth-step-up.test.ts`.

---

## A. Mixed-version deploys

| ID | Scenario | Behaviour | Status |
|---|---|---|---|
| A1 | **Old broker (no `granted_scope` field) → new server** | Server's `BrokerSessionRequest` defaults missing field to `"atproto transition:generic"`. Old broker always granted that scope, so the default is correct. Upload works as a wide grant. | ✅ Verified by `BrokerSessionRequest` `serde(default)` |
| A2 | **New broker → old server** | Old server's `BrokerSessionRequest` doesn't have the field; serde ignores unknown fields. Old upload path doesn't check scope at all. Works. | ✅ Documented |
| A3 | **Rolling deploy mid-flow** (broker on new, server on old, then both new): `granted_scope` is rebuilt on the next refresh. | Worst case: a single-purpose check fails on the old server during the transition window, which falls through to the legacy "no scope check" path. Net effect: nothing breaks. | ✅ Documented |

**Net:** old↔new deploy combinations are transparent. The only field
change is additive.

---

## B. Existing-user migration

| ID | Scenario | Behaviour | Status |
|---|---|---|---|
| B1 | User has a broker token from a `transition:generic` grant. After deploy, the broker refreshes via PDS. PDS returns scope in the response. | Broker reads scope from response and forwards verbatim. Server stores `transition:generic`; `scope_satisfies_purpose` accepts it for any purpose. Upload works without step-up. | ✅ Verified (`legacy_transition_generic_satisfies_all_purposes_for_grace_period`) |
| B1' | Same, but PDS **omits** scope in the refresh response. | Broker defaults to `"atproto transition:generic"` — conservative wide assumption, since every refresh token currently in the broker DB was originally wide. Works. | ✅ Fixed in this branch (was previously defaulting to `"atproto"`) |
| B2 | Old broker's refresh tokens are bound to `transition:generic`. Some PDSes verify the original grant scope still appears in the current client metadata. | Metadata explicitly retains `transition:generic` in the union for the grace period. Refresh continues to succeed. | ✅ Fixed in this branch (also verified by `metadata_keeps_transition_generic_for_refresh_grace_period`) |
| B3 | Fresh login on the new code path → user's first interaction asks Bluesky only for `atproto`. Then they click upload. | Server returns the structured 403 `step_up_required`; web client opens the step-up popup with `atproto blob:image/*`; PDS shows narrower consent screen; on grant, BlobUpload session is stored; upload retries automatically. | ✅ Wired (popup helper + ComposeBox 403 catch) |
| B4 | User logged in pre-deploy, has a Login session keyed by `(DID, OauthPurpose::Login)` but their granted_scope was set to `"atproto transition:generic"` on a refresh. Tries to upload. | Upload path: no BlobUpload session, falls back to Login. Login's scope satisfies `BlobUpload` (legacy wide). Upload proceeds without step-up. **No popup, no friction.** | ✅ Verified by `scope_satisfies_blob_upload_with_granular_grant` + the legacy variant |

---

## C. PDS variation

| ID | Scenario | Behaviour | Status |
|---|---|---|---|
| C1 | **Self-hosted PDS that doesn't speak granular scopes.** Step-up requests `atproto blob:image/*`. PDS may: (a) return `invalid_scope`; (b) silently drop the unknown granular and downgrade to just `atproto`; (c) silently expand to `transition:generic`. | (a) Step-up popup shows an OAuth error → resolves `false` → ComposeBox surfaces "image upload needs Bluesky permission". (b) BlobUpload session is stored with `granted_scope: "atproto"` — `scope_satisfies_purpose(BlobUpload)` returns false → upload re-fires the structured 403 → loop. (c) Works fine. | ⚠️ **(b) is a real loop trap.** See "Open issues" below. |
| C2 | PDS grants narrower than requested, e.g. user un-checks a permission on Bluesky's consent screen. | `granted_scope` records the truth. `scope_satisfies_purpose` rejects → user gets 403 even after step-up "succeeded". | ⚠️ **(open) need a UX path** for "you completed step-up but didn't grant the permission". Currently shows the same generic error. |
| C3 | PDS rotates DPoP nonce mid-flow. | Existing `freeq_sdk::media::upload_media_to_pds` handles this internally with a single retry. Same as before this PR. | ✅ Unchanged |

---

## D. Network / UX races

| ID | Scenario | Behaviour | Status |
|---|---|---|---|
| D1 | **Popup blocker.** | `requestStepUp` returns `{ok:false, reason:'popup_blocked'}`. ComposeBox surfaces "Allow popups for this site so freeq can request the image-upload permission, then retry." **No full-page redirect** (was the original behaviour; would have lost chat state). | ✅ Fixed in this branch (was `window.location.href = url`); verified by `oauth-step-up.test.ts` |
| D2 | User clicks upload twice quickly while step-up is in-flight. | Second click hits the same upload path. The first click's popup is still open. The second 403 triggers `requestStepUp` again — which calls `window.open` with the same name; browsers focus the existing popup (no second window). When the popup completes, both pending promises resolve via the broadcast and both uploads retry. The retry is idempotent on the user's side; the server may end up uploading twice. | ⚠️ **Minor:** could cause a duplicate upload. ComposeBox could disable the upload button while a step-up is pending — added to the open-issues list. |
| D3 | User denies the scope at Bluesky. | PDS redirects back with `error=access_denied`. Server's `auth_callback` returns the standard error result page. The popup closes. The waiting `requestStepUp` resolves `{ok:false, reason:'closed'}`. ComposeBox shows the generic "needs Bluesky permission" message. | ⚠️ Could be more specific. We don't differentiate "user denied" from "user closed without acting". |
| D4 | PDS slow → popup hangs past timeout (default 120 s). | `requestStepUp` resolves `{ok:false, reason:'timeout'}`. ComposeBox: "The Bluesky permission popup timed out. Try the upload again." | ✅ Verified by JS adversarial test |
| D5 | User opens upload popup, then their Login session expires (24 h TTL) before they complete. | Step-up callback succeeds and stores a BlobUpload session — *no Login dependency at callback time, only at request time*. Upload retry proceeds because `scope_satisfies_purpose(BlobUpload)` accepts the new session. But the user's IRC connection has been dropped (no Login session); message-send fails until they re-auth. | ⚠️ Asymmetric behaviour. Documented; not blocking deploy. |
| D6 | User has multiple tabs open. Step-up succeeds in tab A. | All tabs receive the BroadcastChannel signal. Each tab with a pending upload retries. Server sees N concurrent uploads from the same DID. The PDS may rate-limit. | ⚠️ Minor; documented. |

---

## E. Security

| ID | Scenario | Behaviour | Status |
|---|---|---|---|
| E1 | `/auth/step-up` returns 401 vs 302 depending on whether the named DID has a Login session. **Information leak.** | An attacker can probe the endpoint with arbitrary DIDs to learn which are currently logged in to this server. | ⚠️ **Documented limitation.** This information was already discoverable via WHOIS over the public IRC interface, so the marginal leak is small. Mitigation (deferred): always respond 302 to a generic "checking..." page that itself decides whether to start the OAuth flow or render an error. |
| E2 | **CSRF on `/auth/step-up`.** Malicious page opens a step-up popup pointing at our endpoint with the user's DID. | The user sees Bluesky's consent screen. They have to click "Authorize". If they do, freeq gains the additional permission for their account. The damage ceiling is "freeq has the same permissions it would have had if the user explicitly upgraded" — no token theft, no impersonation. | ⚠️ **Documented.** Mitigation (deferred): require a CSRF token bound to the user's session in the step-up URL. |
| E3 | Open redirect via Host-header manipulation. | `derive_web_origin` reads the Host header; an attacker controlling Host could craft a redirect_uri pointing at attacker.com. Modern proxies normalise Host though, and self-hosted setups can't easily be attacked because the attacker would need a foothold inside the network. | ⚠️ Pre-existing concern; not a regression from this PR. |
| E4 | Replay of `oauth_pending` state. | State is randomly generated, expires at 5 min (Login) / 10 min (step-up), and is removed from the map on first use. Replay → 400. | ✅ Verified by existing flow |

---

## F. Server-side state

| ID | Scenario | Behaviour | Status |
|---|---|---|---|
| F1 | Step-up takes >5 min (slow user, Bluesky's screen open in background). | TTL bumped to **10 min** for non-Login purposes in this branch. Login still 5 min. | ✅ Fixed |
| F2 | WebSession 24 h TTL purges Login + BlobUpload separately. | Each session ages independently; user needs to re-login after 24 h regardless. Same as before. | ✅ Unchanged |
| F3 | DPoP nonce rotation on upload writes back to the right slot. | Code refreshes nonce on the `(DID, BlobUpload)` slot first, falls back to the Login slot only if the upload was served by a legacy wide grant. | ✅ Verified by reading the code path |
| F4 | User runs Phase-2 step-up twice (e.g. two tabs both decide to upgrade). | Second insert overwrites the first. New DPoP key, new nonce. Old key invalidated; old refresh token bound to old grant is still valid until the PDS marks it superseded. | ⚠️ Theoretically can produce orphan tokens. Not exploitable. Documented. |

---

## G. Edge cases in scope predicate (`scope_satisfies_purpose`)

All verified by `tests/oauth_scope.rs`:

- ✅ Whitespace-tolerant (`split_whitespace` handles tabs, multi-space, leading/trailing newlines).
- ✅ Case-sensitive (`ATPROTO` ≠ `atproto`).
- ✅ Empty grant → fails closed for everything except… nothing (`Login` requires `atproto` token explicitly).
- ✅ `transition:generic` satisfies any purpose during grace period.
- ✅ `repo:*` (wildcard) satisfies the specific `repo:app.bsky.feed.post`.
- ⚠️ `blob:image/png` (subtype-narrowed grant) satisfies BlobUpload — over-permissive in spirit (we'd accept "you can upload PNGs" as "you can upload images") but in practice the PDS itself enforces the actual subtype on `uploadBlob`. Documented.

---

## Open issues to track separately

These do **not** block the deploy but should land soon:

1. **C1(b) loop trap** — if a PDS silently downgrades step-up to `atproto`, the upload re-fires the 403 indefinitely. **Mitigation:** after step-up, before the retry, the web client should re-check the granted scope (server can expose `GET /api/v1/me/scope?purpose=blob_upload` returning `{satisfied: bool}`). Or: have the upload retry surface a different message after one failed step-up attempt.
2. **C2 partial-grant UX** — "you completed the popup but didn't grant the permission". Currently produces the same error as "popup closed". Worth distinguishing in a follow-up.
3. **D2 duplicate-upload prevention** — disable the upload button while a step-up is pending in any open tab.
4. **D3 PDS error pass-through** — surface the actual OAuth error from the PDS to the user instead of the generic "needs Bluesky permission".
5. **E1 info-leak hardening** — make `/auth/step-up` return a uniform 302 to a thinking page, deciding internally.
6. **E2 CSRF token** — bind the step-up URL to the user's session.

---

## Deploy notes

1. **Rolling deploy is safe.** Server and broker can be updated in either order; `granted_scope` is additive.
2. **Existing users see no change at first.** Their cached broker tokens carry `transition:generic`; uploads continue to work without prompting.
3. **New sign-ups see the narrower consent screen** at Bluesky from day one.
4. **Existing users get the narrower screen on their next full re-login** (e.g. 24 h after deploy when their Login session expires, or when they manually sign out + sign in).
5. **No DB migration needed.** All session storage is in-memory; new fields are added inline.
6. The grace-period `transition:generic` entry in client-metadata.json should be removed once Bluesky deprecates the scope (no announced date as of this writing — track at <https://github.com/bluesky-social/atproto/discussions/4118>).
