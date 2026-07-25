//// Short-lived disk store for in-flight AT Protocol OAuth logins.
////
//// Keyed by the OAuth `state` parameter so `/auth/callback` can recover the
//// PKCE verifier + DPoP key even when the browser drops cookies after the
//// cross-site PDS redirect. Files expire after TTL and are deleted on take.

import filepath
import freeq_web4/atproto/oauth
import freeq_web4/atproto/util as atutil
import freeq_web4/config
import gleam/list
import gleam/string
import simplifile

const ttl_seconds = 1800

/// Save a prepared-login payload. Returns state.
pub fn save(data: oauth.PendingData) -> Result(String, String) {
  case data.state {
    "" -> Error("empty state")
    state -> {
      let path = path_for(state)
      let _ = simplifile.create_directory_all(filepath.directory_name(path))
      let body = oauth.pending_to_json(data)
      case atomic_write(path, body) {
        Ok(_) -> Ok(state)
        Error(e) -> Error(e)
      }
    }
  }
}

/// Load without deleting. Returns data or None.
pub fn load(state: String) -> Result(oauth.PendingData, Nil) {
  case state {
    "" -> Error(Nil)
    _ -> {
      let path = path_for(state)
      case simplifile.read(path) {
        Error(_) -> Error(Nil)
        Ok(raw) ->
          case oauth.pending_from_json(raw) {
            Error(_) -> Error(Nil)
            Ok(data) ->
              case expired(data.created_at) {
                True -> {
                  let _ = simplifile.delete(path)
                  Error(Nil)
                }
                False -> Ok(data)
              }
          }
      }
    }
  }
}

/// Load and delete (one-shot).
pub fn take(state: String) -> Result(oauth.PendingData, Nil) {
  let data = load(state)
  let _ = remove(state)
  data
}

pub fn remove(state: String) -> Nil {
  case state {
    "" -> Nil
    _ -> {
      let _ = simplifile.delete(path_for(state))
      Nil
    }
  }
}

/// Drop expired files (best-effort).
pub fn gc() -> Nil {
  let dir = config.pending_oauth_dir()
  case simplifile.read_directory(dir) {
    Error(_) -> Nil
    Ok(names) -> {
      list.each(names, fn(name) {
        case string.ends_with(name, ".json") {
          False -> Nil
          True -> {
            let path = filepath.join(dir, name)
            case simplifile.read(path) {
              Ok(raw) ->
                case oauth.pending_from_json(raw) {
                  Ok(data) ->
                    case expired(data.created_at) {
                      True -> {
                        let _ = simplifile.delete(path)
                        Nil
                      }
                      False -> Nil
                    }
                  Error(_) -> Nil
                }
              Error(_) -> Nil
            }
          }
        }
      })
    }
  }
}

fn expired(created_at: Int) -> Bool {
  created_at <= 0 || atutil.unix_seconds() - created_at > ttl_seconds
}

fn path_for(state: String) -> String {
  let safe =
    string.to_graphemes(state)
    |> list.map(fn(g) {
      case g {
        "A"
        | "B"
        | "C"
        | "D"
        | "E"
        | "F"
        | "G"
        | "H"
        | "I"
        | "J"
        | "K"
        | "L"
        | "M"
        | "N"
        | "O"
        | "P"
        | "Q"
        | "R"
        | "S"
        | "T"
        | "U"
        | "V"
        | "W"
        | "X"
        | "Y"
        | "Z"
        | "a"
        | "b"
        | "c"
        | "d"
        | "e"
        | "f"
        | "g"
        | "h"
        | "i"
        | "j"
        | "k"
        | "l"
        | "m"
        | "n"
        | "o"
        | "p"
        | "q"
        | "r"
        | "s"
        | "t"
        | "u"
        | "v"
        | "w"
        | "x"
        | "y"
        | "z"
        | "0"
        | "1"
        | "2"
        | "3"
        | "4"
        | "5"
        | "6"
        | "7"
        | "8"
        | "9"
        | "_"
        | "-" -> g
        _ -> "_"
      }
    })
    |> string.concat
  filepath.join(config.pending_oauth_dir(), safe <> ".json")
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
