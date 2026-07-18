# OAuth Scope — Live HTTP Smoke

**Server:** http://127.0.0.1:8086 (release build, no LLM, fresh process)
**Date:** 2026-04-26T13:29:23Z

Each case shows the exact request and the wire response. The point is to
verify the new scope/step-up behaviour over real HTTP, not just in
unit tests.

---

## 1. Discovery — client metadata

```bash
curl http://127.0.0.1:8086/client-metadata.json
```

```json
{
  "application_type": "web",
  "client_id": "http://localhost?redirect_uri=http%3A%2F%2F127%2E0%2E0%2E1%3A8086%2Fauth%2Fcallback&scope=atproto%20blob%3Aimage%2F%2A%20repo%3Aapp%2Ebsky%2Efeed%2Epost%20transition%3Ageneric",
  "client_name": "freeq",
  "client_uri": "http://127.0.0.1:8086",
  "dpop_bound_access_tokens": true,
  "grant_types": [
    "authorization_code",
    "refresh_token"
  ],
  "logo_uri": "http://127.0.0.1:8086/freeq.png",
  "policy_uri": "http://127.0.0.1:8086",
  "redirect_uris": [
    "http://127.0.0.1:8086/auth/callback"
  ],
  "response_types": [
    "code"
  ],
  "scope": "atproto blob:image/* repo:app.bsky.feed.post transition:generic",
  "token_endpoint_auth_method": "none",
  "tos_uri": "http://127.0.0.1:8086"
}
```

Confirms: scope is the union (`atproto blob:image/* repo:app.bsky.feed.post transition:generic`),
with the legacy scope kept for the refresh-token grace period. Primary
login asks for `atproto` only — see case 7.

## 2. /auth/step-up — anonymous (no Login session)

```bash
curl -i "http://127.0.0.1:8086/auth/step-up?purpose=blob_upload&did=did:plc:noone"
```

```
HTTP/1.1 401 Unauthorized
content-type: text/plain; charset=utf-8
vary: origin, access-control-request-method, access-control-request-headers

Step-up requires an active login session for this DID.```

Confirms: 401 when there's no Login session for the named DID.
(Information-leak note: status differs between "DID has session" → 302
redirect and "DID has no session" → 401. Documented as edge case E1.)

## 3. /auth/step-up — unknown purpose

```bash
curl -i "http://127.0.0.1:8086/auth/step-up?purpose=become_admin&did=did:plc:abc"
```

```
HTTP/1.1 400 Bad Request
content-type: text/plain; charset=utf-8
vary: origin, access-control-request-method, access-control-request-headers

Unknown purpose: become_admin```

## 4. /auth/step-up — case-sensitive purpose enum

```bash
curl -i "http://127.0.0.1:8086/auth/step-up?purpose=BLOB_UPLOAD&did=did:plc:abc"
```

```
HTTP/1.1 400 Bad Request
content-type: text/plain; charset=utf-8
vary: origin, access-control-request-method, access-control-request-headers

Unknown purpose: BLOB_UPLOAD```

## 5. /auth/step-up — refuses `login` as a step-up purpose

```bash
curl -i "http://127.0.0.1:8086/auth/step-up?purpose=login&did=did:plc:abc"
```

```
HTTP/1.1 400 Bad Request
content-type: text/plain; charset=utf-8
vary: origin, access-control-request-method, access-control-request-headers

Use /auth/login for the primary login flow.```

## 6. /api/v1/upload — anonymous (no session at all)

```bash
curl -i -X POST -F "did=did:plc:noone" -F "file=@/etc/hosts" \
     http://127.0.0.1:8086/api/v1/upload
```

```
HTTP/1.1 401 Unauthorized
content-type: text/plain; charset=utf-8
vary: origin, access-control-request-method, access-control-request-headers

Upload requires an active connection for this DID```

The Phase-2 structured 403 only fires when the DID has a Login session
but no BlobUpload session — the 401 here is the "not logged in at all"
branch, which is the correct response for an anonymous upload.

## 7. /auth/login — primary login flow shape

The actual redirect requires a real handle resolvable to a real PDS;
this offline smoke just shows the resolver-failure path.

```bash
curl -i "http://127.0.0.1:8086/auth/login?handle=nonexistent-handle.invalid"
```

```
HTTP/1.1 400 Bad Request
content-type: text/plain; charset=utf-8
vary: origin, access-control-request-method, access-control-request-headers

Cannot resolve handle: Public API returned error```

(With a real Bluesky handle this returns a 307 Redirect to the PDS's
authorization endpoint. The PAR sent to the PDS uses scope `atproto`
only — verified via the unit test
`requested_scopes_are_narrow_not_transition_generic` and the codepath
in `auth_login`.)

---

## Verdict

- ✅ /client-metadata.json advertises narrow scopes plus the legacy
  `transition:generic` for the grace period.
- ✅ /auth/step-up rejects unknown purposes, mangled cases, and
  `login` as a purpose.
- ✅ /auth/step-up rejects requests without a primary Login session.
- ✅ /api/v1/upload returns 401 for fully unauthenticated callers.
- ✅ /auth/login returns a clear 4xx on bad handle (no crash, no leak).
- ✅ Server starts cleanly with the new schema — no migration needed.

The structured `step_up_required` 403 on /api/v1/upload only fires
when a Login session exists but BlobUpload doesn't. That path requires
a successful primary login first, which needs a real Bluesky account
and OAuth consent — so it's verified via the integration tests in
`tests/oauth_scope.rs` (which insert WebSession state directly).
