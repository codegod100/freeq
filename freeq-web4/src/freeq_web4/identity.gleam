//// Identity state machines for freeq-web4.
////
//// Two orthogonal machines, both driven by exhaustive pattern matches:
////
//// 1. **Credentials** — browser cookie session ↔ disk OAuth tokens
////    (`NoCredentials` | `Valid` | `Stale`). Decides whether `/login`
////    should bounce to chat or show the form.
////
//// 2. **Identity** — LiveView wire face (`Guest` | `AwaitingSasl` |
////    `Bound` | `NeedsReauth`). Only `Bound` is “signed in” for UI,
////    private channels, and uploads. Stale disk tokens never look signed-in.
////
//// Transitions are pure functions; side effects (refresh, disk I/O) live in
//// the callers (`auth`, `ws`) and feed results back through these constructors.

import freeq_web4/atproto/oauth
import freeq_web4/atproto/oauth_session.{type OAuthSession}
import freeq_web4/session_store
import gleam/option.{type Option, None, Some}
import gleam/string

// ── Credentials (HTTP / disk) ────────────────────────────────────────────────

/// OAuth material keyed by the `freeq_session` cookie.
pub type Credentials {
  /// No session file (or empty cookie).
  NoCredentials
  /// Access token is usable for SASL (fresh, or just refreshed).
  Valid(session: OAuthSession)
  /// File exists but access cannot be renewed — re-login required.
  Stale(session: OAuthSession, reason: String)
}

/// What `/login` should render / do.
pub type LoginDisposition {
  /// Show the handle form (optional flash).
  ShowForm(flash: Option(String))
  /// Tokens still good — bounce to chat.
  RedirectChat(handle: String)
}

/// Load + classify credentials for a cookie session id.
///
/// Attempts a refresh when access is near expiry so a valid session survives
/// overnight without forcing OAuth. On terminal refresh failure → `Stale`
/// (and the caller should clear disk so `/login` does not bounce forever).
///
/// **Do not call from WebSocket `on_init`** — refresh is a network round-trip
/// and will stall the upgrade (browser: Invalid frame header / 1006).
/// Use `peek_credentials` there; call this from bootstrap / ensure_upstream.
pub fn resolve_credentials(session_id: String) -> Credentials {
  case session_store.load(session_id) {
    Error(_) -> NoCredentials
    Ok(session) -> classify_session(session)
  }
}

/// Disk-only load (no HTTP). Safe for WebSocket mount / on_init.
///
/// Expired access still returns `Valid` when a refresh token exists so IRC
/// can open and `ensure_upstream` can refresh; without RT → `Stale`.
pub fn peek_credentials(session_id: String) -> Credentials {
  case session_store.load(session_id) {
    Error(_) -> NoCredentials
    Ok(session) ->
      case oauth.access_still_fresh(session, 120) {
        True -> Valid(session)
        False ->
          case session.refresh_token {
            Some(rt) if rt != "" -> Valid(session)
            _ -> Stale(session, "access expired, no refresh token")
          }
      }
  }
}

/// Classify an already-loaded OAuth session (refresh if needed).
pub fn classify_session(session: OAuthSession) -> Credentials {
  case oauth.access_still_fresh(session, 120) {
    True -> Valid(session)
    False ->
      case oauth.refresh(session) {
        Ok(next) -> Valid(next)
        Error(reason) -> Stale(session, reason)
      }
  }
}

/// Login page policy. `force` (e.g. `?reauth=1`) always shows the form.
///
/// `Stale` clears the dead session so the next visit is clean and so IRC
/// bootstrap does not keep attempting SASL with a dead refresh token.
pub fn login_disposition(
  session_id: String,
  force: Bool,
) -> LoginDisposition {
  case force {
    True -> {
      // Explicit re-auth: drop disk creds for this cookie so SASL starts clean.
      session_store.remove(session_id)
      ShowForm(None)
    }
    False ->
      case resolve_credentials(session_id) {
        NoCredentials -> ShowForm(None)
        Valid(session) -> {
          // Persist refreshed tokens when classify rotated them.
          session_store.save(session_id, session)
          RedirectChat(session.handle)
        }
        Stale(session, reason) -> {
          session_store.remove(session_id)
          ShowForm(
            Some(
              "Session expired for "
              <> session.handle
              <> " — sign in again ("
              <> short_reason(reason)
              <> ")",
            ),
          )
        }
      }
  }
}

/// OAuth session to open IRC with, if any.
///
/// `Stale` → None (guest IRC). Never feed a dead access token into SASL.
pub fn oauth_for_upstream(credentials: Credentials) -> Option(OAuthSession) {
  case credentials {
    Valid(session) -> Some(session)
    NoCredentials | Stale(_, _) -> None
  }
}

/// Persist `Valid` credentials after classify (no-op for others).
pub fn persist_if_valid(session_id: String, credentials: Credentials) -> Nil {
  case credentials {
    Valid(session) -> session_store.save(session_id, session)
    NoCredentials | Stale(_, _) -> Nil
  }
}

// ── Identity (LiveView / wire) ───────────────────────────────────────────────

/// What the chat shell believes about the user’s AT identity.
///
/// Exhaustive match at every UI/policy site — never a loose `authenticated`
/// bool that can disagree with handle/DID/nick.
pub type Identity {
  /// Anonymous guest (no OAuth, or after logout).
  Guest
  /// Credentials present; CAP/SASL not finished. Not “signed in” yet.
  AwaitingSasl(handle: String, did: String)
  /// SASL 903 — DID bound on this IRC connection. True signed-in.
  Bound(handle: String, did: String)
  /// Must re-auth (SASL 904, stale tokens, guest nick demotion). Shows Sign in.
  NeedsReauth(handle: String, did: String, reason: String)
}

/// Seed LiveView identity from resolved credentials at mount.
pub fn from_credentials(credentials: Credentials) -> Identity {
  case credentials {
    NoCredentials -> Guest
    Valid(session) -> AwaitingSasl(session.handle, session.did)
    Stale(session, reason) ->
      NeedsReauth(session.handle, session.did, short_reason(reason))
  }
}

/// CAP negotiated SASL; still waiting on 903/904.
pub fn on_sasl_pending(identity: Identity) -> Identity {
  case identity {
    AwaitingSasl(h, d) -> AwaitingSasl(h, d)
    Bound(h, d) -> AwaitingSasl(h, d)
    NeedsReauth(h, d, _) -> AwaitingSasl(h, d)
    Guest -> Guest
  }
}

/// Numeric 903 — bind DID on the wire.
pub fn on_sasl_ok(identity: Identity, handle: String, did: String) -> Identity {
  let handle = pick_handle(identity, handle)
  let did = pick_did(identity, did)
  case handle != "" && did != "" {
    True -> Bound(handle, did)
    False -> identity
  }
}

/// Numeric 904 / local SASL failure — never stay looking signed-in.
pub fn on_sasl_failed(identity: Identity, reason: String) -> Identity {
  let reason = short_reason(reason)
  case identity {
    Guest -> Guest
    AwaitingSasl(h, d) -> NeedsReauth(h, d, reason)
    Bound(h, d) -> NeedsReauth(h, d, reason)
    NeedsReauth(h, d, _) -> NeedsReauth(h, d, reason)
  }
}

/// Explicit logout / cookie cleared.
pub fn clear(_identity: Identity) -> Identity {
  Guest
}

// ── Queries (prefer these over field poking) ─────────────────────────────────

/// True only for SASL-bound identity. Private channels, uploads, “Sign out”.
pub fn is_bound(identity: Identity) -> Bool {
  case identity {
    Bound(_, _) -> True
    Guest | AwaitingSasl(_, _) | NeedsReauth(_, _, _) -> False
  }
}

pub fn handle(identity: Identity) -> String {
  case identity {
    Guest -> ""
    AwaitingSasl(h, _) | Bound(h, _) | NeedsReauth(h, _, _) -> h
  }
}

pub fn did(identity: Identity) -> String {
  case identity {
    Guest -> ""
    AwaitingSasl(_, d) | Bound(_, d) | NeedsReauth(_, d, _) -> d
  }
}

/// Flash / status line for the current phase (empty when idle Bound/Guest).
pub fn status_flash(identity: Identity) -> String {
  case identity {
    Guest -> ""
    AwaitingSasl(h, _) -> "Signing in as " <> h <> "…"
    Bound(_, _) -> ""
    NeedsReauth(h, _, reason) ->
      case h {
        "" -> "Sign-in failed — click Sign in to retry (" <> reason <> ")"
        handle ->
          "Sign-in failed for "
          <> handle
          <> " — click Sign in to reconnect ("
          <> reason
          <> ")"
      }
  }
}

/// Nav / sidebar label for the person chip.
pub fn display_label(identity: Identity, nick: String) -> String {
  case identity {
    Bound(h, _) if h != "" -> h
    AwaitingSasl(h, _) if h != "" -> h
    NeedsReauth(h, _, _) if h != "" -> h
    Guest | Bound(_, _) | AwaitingSasl(_, _) | NeedsReauth(_, _, _) -> nick
  }
}

/// CSS modifier for the person chip: `signed-in` | `pending` | `guest` | `reauth`.
pub fn badge_class(identity: Identity) -> String {
  case identity {
    Bound(_, _) -> "signed-in"
    AwaitingSasl(_, _) -> "pending"
    NeedsReauth(_, _, _) -> "reauth"
    Guest -> "guest"
  }
}

/// Sidebar action link: Sign out only when Bound.
/// NeedsReauth forces form (`?reauth=1`) so a stale cookie cannot bounce away.
pub fn action_href(identity: Identity) -> String {
  case identity {
    Bound(_, _) -> "/logout"
    NeedsReauth(_, _, _) -> "/login?reauth=1"
    Guest | AwaitingSasl(_, _) -> "/login"
  }
}

pub fn action_label(identity: Identity) -> String {
  case is_bound(identity) {
    True -> "Sign out"
    False ->
      case identity {
        NeedsReauth(_, _, _) -> "Sign in again"
        _ -> "Sign in"
      }
  }
}

// ── Internals ────────────────────────────────────────────────────────────────

fn pick_handle(identity: Identity, preferred: String) -> String {
  case string.trim(preferred) {
    "" -> handle(identity)
    h -> h
  }
}

fn pick_did(identity: Identity, preferred: String) -> String {
  case string.trim(preferred) {
    "" -> did(identity)
    d -> d
  }
}

fn short_reason(reason: String) -> String {
  let r = string.trim(reason)
  case r {
    "" -> "re-login required"
    _ ->
      case string.length(r) > 120 {
        True -> string.slice(r, 0, 117) <> "…"
        False -> r
      }
  }
}
