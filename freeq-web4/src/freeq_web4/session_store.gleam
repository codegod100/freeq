//// Disk-backed OAuth session store (one file per browser session cookie).
////
//// MVP: JSON with mode 0600 (not encrypted). freeq-web3 uses AES-GCM; that
//// can land with the multi-tab registry milestone.
////
//// Also persists the client-authoritative "My channels" list so refresh
//// re-seeds the sidebar and re-JOINs upstream (web2/web3 parity).

import filepath
import freeq_web4/atproto/oauth_session.{type OAuthSession}
import freeq_web4/config
import freeq_web4/irc/render
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import logging
import simplifile

/// Save OAuth credentials for `session_id`.
pub fn save(session_id: String, oauth: OAuthSession) -> Nil {
  case session_id {
    "" -> Nil
    sid -> {
      let dir = config.sessions_dir()
      let _ = simplifile.create_directory_all(dir)
      let path = session_path(sid)
      let body = oauth_session.to_string(oauth)
      case atomic_write(path, body) {
        Ok(_) ->
          logging.log(
            logging.Info,
            "session_store save sid=" <> short(sid) <> " did=" <> oauth.did,
          )
        Error(e) ->
          logging.log(
            logging.Warning,
            "session_store save failed sid=" <> short(sid) <> ": " <> e,
          )
      }
    }
  }
}

/// Load OAuth credentials. Returns None when missing/invalid.
pub fn load(session_id: String) -> Result(OAuthSession, Nil) {
  case session_id {
    "" -> Error(Nil)
    sid ->
      case simplifile.read(session_path(sid)) {
        Error(_) -> Error(Nil)
        Ok(raw) ->
          case oauth_session.from_string(raw) {
            Ok(s) -> Ok(s)
            Error(_) -> Error(Nil)
          }
      }
  }
}

/// Drop persisted OAuth + channels for logout.
pub fn remove(session_id: String) -> Nil {
  case session_id {
    "" -> Nil
    sid -> {
      let _ = simplifile.delete(session_path(sid))
      let _ = simplifile.delete(bearer_path(sid))
      let _ = simplifile.delete(channels_path(sid))
      Nil
    }
  }
}

/// Persist client-authoritative "My channels" list (canonical `#name` strings).
pub fn save_channels(session_id: String, channels: List(String)) -> Nil {
  case session_id {
    "" -> Nil
    sid -> {
      let dir = config.sessions_dir()
      let _ = simplifile.create_directory_all(dir)
      let cleaned =
        channels
        |> list.map(fn(c) { render.canonical_channel(string.trim(c)) })
        |> list.filter(fn(c) { c != "" && c != "#" })
        |> list_unique
      let body = json.array(cleaned, of: json.string) |> json.to_string
      case atomic_write(channels_path(sid), body) {
        Ok(_) -> Nil
        Error(e) ->
          logging.log(
            logging.Warning,
            "session_store save_channels failed sid="
              <> short(sid)
              <> ": "
              <> e,
          )
      }
    }
  }
}

/// Load "My channels". Empty when missing/invalid.
pub fn load_channels(session_id: String) -> List(String) {
  case session_id {
    "" -> []
    sid ->
      case simplifile.read(channels_path(sid)) {
        Error(_) -> []
        Ok(raw) ->
          case json.parse(raw, decode.list(decode.string)) {
            Error(_) -> []
            Ok(chs) ->
              chs
              |> list.map(fn(c) { render.canonical_channel(string.trim(c)) })
              |> list.filter(fn(c) { c != "" && c != "#" })
              |> list_unique
          }
      }
  }
}

/// Persist freeq-server API-BEARER (post-SASL) for REST AV token proxy.
pub fn save_api_bearer(session_id: String, bearer: String) -> Nil {
  case session_id, string.trim(bearer) {
    "", _ -> Nil
    _, "" -> Nil
    sid, tok -> {
      let dir = config.sessions_dir()
      let _ = simplifile.create_directory_all(dir)
      let _ = atomic_write(bearer_path(sid), tok)
      Nil
    }
  }
}

/// Load API-BEARER for REST token fallback (None when guest / missing).
pub fn load_api_bearer(session_id: String) -> option.Option(String) {
  case session_id {
    "" -> option.None
    sid ->
      case simplifile.read(bearer_path(sid)) {
        Ok(raw) ->
          case string.trim(raw) {
            "" -> option.None
            t -> option.Some(t)
          }
        Error(_) -> option.None
      }
  }
}

fn session_path(session_id: String) -> String {
  let safe = safe_name(session_id)
  filepath.join(config.sessions_dir(), safe <> ".json")
}

fn bearer_path(session_id: String) -> String {
  let safe = safe_name(session_id)
  filepath.join(config.sessions_dir(), safe <> ".bearer")
}

fn channels_path(session_id: String) -> String {
  let safe = safe_name(session_id)
  filepath.join(config.sessions_dir(), safe <> ".channels")
}

fn list_unique(xs: List(String)) -> List(String) {
  list.fold(xs, [], fn(acc, x) {
    case list.contains(acc, x) {
      True -> acc
      False -> list.append(acc, [x])
    }
  })
}

fn safe_name(s: String) -> String {
  string.to_graphemes(s)
  |> list.map(fn(g) {
    case
      string.contains(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-",
        g,
      )
    {
      True -> g
      False -> "_"
    }
  })
  |> string.concat
}

fn short(sid: String) -> String {
  case string.length(sid) > 8 {
    True -> string.slice(sid, 0, 8)
    False -> sid
  }
}

fn atomic_write(path: String, text: String) -> Result(Nil, String) {
  let tmp = path <> ".tmp"
  case simplifile.write(to: tmp, contents: text) {
    Error(_) -> Error("write_failed")
    Ok(_) -> {
      let _ = simplifile.set_permissions_octal(tmp, 0o600)
      case simplifile.rename(tmp, path) {
        Ok(_) -> {
          let _ = simplifile.set_permissions_octal(path, 0o600)
          Ok(Nil)
        }
        Error(_) -> {
          let _ = simplifile.delete(tmp)
          Error("rename_failed")
        }
      }
    }
  }
}
