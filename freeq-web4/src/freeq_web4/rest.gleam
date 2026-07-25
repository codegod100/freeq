//// Thin client for freeq-server REST (`/api/v1/...`).
////
//// Mirrors freeq-web3 `Rest` / freeq-web2 SessionRegistry fetch helpers.

import freeq_web4/config
import freeq_web4/irc/render
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import logging

/// Public channel summary from `GET /api/v1/channels`.
pub type ChannelInfo {
  ChannelInfo(name: String, topic: String, members: Int)
}

/// GET /api/v1/channels → list of public channels.
pub fn fetch_channels() -> List(ChannelInfo) {
  let url = config.upstream_rest() <> "/api/v1/channels"
  case get_json(url, None) {
    Ok(body) -> decode_channels(body)
    Error(reason) -> {
      logging.log(logging.Warning, "fetch_channels failed: " <> reason)
      []
    }
  }
}

/// GET /api/v1/channels/:name/history?limit=
pub fn fetch_history(
  channel: String,
  limit: Int,
  bearer: Option(String),
) -> List(render.Row) {
  let bare = render.bare_channel(channel)
  let encoded = uri.percent_encode(bare)
  let url =
    config.upstream_rest()
    <> "/api/v1/channels/"
    <> encoded
    <> "/history?limit="
    <> int.to_string(limit)
  case get_json(url, bearer) {
    Ok(body) -> decode_history(body)
    Error(reason) -> {
      logging.log(
        logging.Info,
        "fetch_history " <> channel <> " failed: " <> reason,
      )
      []
    }
  }
}

/// GET /api/v1/channels/:name/topic → topic text.
///
/// The public `/api/v1/channels` list omits +i/+k/policy rooms (e.g. `#freeq`),
/// so their topics never appear there. This per-channel endpoint still returns
/// the topic (used when opening a private channel the user has already joined).
pub fn fetch_channel_topic(channel: String) -> Option(String) {
  let ch = render.canonical_channel(channel)
  // Encode `#` as %23 so it is not treated as a URL fragment.
  let encoded = encode_channel_path(ch)
  let url = config.upstream_rest() <> "/api/v1/channels/" <> encoded <> "/topic"
  case get_json(url, None) {
    Ok(body) ->
      case
        json.parse(body, {
          use topic <- decode.optional_field("topic", "", nullable_string())
          decode.success(topic)
        })
      {
        Ok(t) if t != "" -> Some(t)
        _ -> None
      }
    Error(_) -> None
  }
}

/// Topic from the public directory list for `channel`, or `""` if missing.
pub fn topic_for(all: List(ChannelInfo), channel: String) -> String {
  let want = string.lowercase(render.canonical_channel(channel))
  case
    list.find(all, fn(c) {
      string.lowercase(render.canonical_channel(c.name)) == want
    })
  {
    Ok(c) -> c.topic
    Error(_) -> ""
  }
}

/// Resolve channel topic for the nav bar: public list first, then per-channel
/// REST. Mirrors freeq-web3 `resolve_topic` so private rooms like `#freeq`
/// (absent from the directory) still show their topic when opened.
pub fn resolve_topic(all: List(ChannelInfo), channel: String) -> String {
  case topic_for(all, channel) {
    "" ->
      case fetch_channel_topic(channel) {
        Some(t) -> t
        None -> ""
      }
    t -> t
  }
}

fn get_json(url: String, bearer: Option(String)) -> Result(String, String) {
  case request.to(url) {
    Error(_) -> Error("bad_url")
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
        |> request.set_header("accept", "application/json")
      let req = case bearer {
        Some(token) if token != "" ->
          request.set_header(req, "authorization", "Bearer " <> token)
        _ -> req
      }
      case httpc.send(req) {
        Ok(resp) ->
          case resp.status {
            200 -> Ok(resp.body)
            status -> Error("http_" <> int.to_string(status))
          }
        Error(_) -> Error("request_failed")
      }
    }
  }
}

/// JSON string or `null` → String (null/missing become `""`).
/// freeq-server returns `"topic": null` for channels without a topic; a plain
/// `decode.string` fails there and would drop the entire channel list.
fn nullable_string() -> decode.Decoder(String) {
  decode.optional(decode.string)
  |> decode.map(fn(opt) {
    case opt {
      Some(s) -> s
      None -> ""
    }
  })
}

fn decode_channels(body: String) -> List(ChannelInfo) {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use topic <- decode.optional_field("topic", "", nullable_string())
    use members <- decode.optional_field("members", 0, decode.int)
    decode.success(ChannelInfo(name:, topic:, members:))
  }
  case json.parse(body, decode.list(decoder)) {
    Ok(list) -> list
    Error(err) -> {
      logging.log(
        logging.Warning,
        "decode_channels failed: " <> string.inspect(err),
      )
      []
    }
  }
}

fn decode_history(body: String) -> List(render.Row) {
  let decoder = {
    use sender <- decode.optional_field("sender", "", decode.string)
    use text <- decode.optional_field("text", "", decode.string)
    use msgid <- decode.optional_field(
      "msgid",
      None,
      decode.optional(decode.string),
    )
    use ts <- decode.optional_field(
      "timestamp",
      None,
      decode.optional(decode.int),
    )
    decode.success(#(sender, text, msgid, ts))
  }
  case json.parse(body, decode.list(decoder)) {
    Ok(rows) ->
      list.map(rows, fn(row) {
        let #(sender, text, msgid, ts) = row
        render.history_row(sender, text, msgid, ts)
      })
    Error(_) -> []
  }
}

/// Human-readable size helper for tests.
pub fn channel_count(channels: List(ChannelInfo)) -> Int {
  list.length(channels)
}

/// Decode channel list JSON (exported for unit tests).
pub fn parse_channels_json(body: String) -> List(ChannelInfo) {
  decode_channels(body)
}

// ── AV sessions ──────────────────────────────────────────────────────────────

/// Active AV call discovered via channel sessions REST probe.
pub type ActiveCall {
  ActiveCall(session_id: String, participant_count: Int, title: String)
}

/// GET /api/v1/channels/:name/sessions (channel name includes `#`).
///
/// Restricted rooms (+i / +k / policy, e.g. `#freeq`) require the freeq-server
/// API-BEARER from post-SASL NOTICE — same rule as history. Without it the
/// upstream returns 403 and active-call discovery silently fails.
pub fn fetch_channel_sessions(
  channel: String,
  bearer: Option(String),
) -> Option(String) {
  let ch = render.canonical_channel(channel)
  // Encode `#` as %23 so it is not treated as a URL fragment.
  let encoded = encode_channel_path(ch)
  let url = config.upstream_rest() <> "/api/v1/channels/" <> encoded <> "/sessions"
  case get_json(url, bearer) {
    Ok(body) -> Some(body)
    Error(reason) -> {
      logging.log(
        logging.Warning,
        "fetch_channel_sessions " <> ch <> " failed: " <> reason,
      )
      None
    }
  }
}

/// Extract active call info from a channel sessions JSON body.
pub fn active_call_from_sessions(body: Option(String)) -> Option(ActiveCall) {
  case body {
    None -> None
    Some(raw) ->
      case
        json.parse(raw, {
          use active <- decode.optional_field(
            "active",
            None,
            decode.optional(active_session_map()),
          )
          decode.success(active)
        })
      {
        Ok(Some(call)) -> call
        _ -> None
      }
  }
}

/// Decode freeq-server `active` session object → Option(ActiveCall).
fn active_session_map() -> decode.Decoder(Option(ActiveCall)) {
  use id <- decode.optional_field("id", "", decode.string)
  use state <- decode.optional_field("state", "", decode.string)
  use title <- decode.optional_field("title", "", nullable_string())
  use participant_count <- decode.optional_field(
    "participant_count",
    0,
    decode.int,
  )
  let state_ok =
    string.lowercase(state) == "active" || string.lowercase(state) == "started"
  case id != "" && state_ok {
    True ->
      decode.success(
        Some(ActiveCall(
          session_id: id,
          participant_count: participant_count,
          title: title,
        )),
      )
    False -> decode.success(None)
  }
}

/// GET /api/v1/sessions/:id — raw JSON body (for BFF proxy / roster).
pub fn fetch_session_detail(session_id: String) -> Option(String) {
  let encoded = uri.percent_encode(session_id)
  let url = config.upstream_rest() <> "/api/v1/sessions/" <> encoded
  case get_json(url, None) {
    Ok(body) -> Some(body)
    Error(reason) -> {
      logging.log(
        logging.Warning,
        "fetch_session_detail failed: " <> reason,
      )
      None
    }
  }
}

/// GET /api/v1/av/sessions/:id/token — MoQ JWT (requires SASL API-BEARER).
pub fn fetch_av_token(
  session_id: String,
  bearer: Option(String),
) -> Option(String) {
  let encoded = uri.percent_encode(session_id)
  let url =
    config.upstream_rest() <> "/api/v1/av/sessions/" <> encoded <> "/token"
  case get_json(url, bearer) {
    Ok(body) ->
      case
        json.parse(body, {
          use token <- decode.optional_field("token", "", decode.string)
          decode.success(token)
        })
      {
        Ok(t) if t != "" -> Some(t)
        _ -> None
      }
    Error(reason) -> {
      logging.log(logging.Warning, "fetch_av_token failed: " <> reason)
      None
    }
  }
}

/// Path-encode a channel name so `#` becomes `%23`.
fn encode_channel_path(channel: String) -> String {
  string.to_graphemes(channel)
  |> list.map(fn(g) {
    case g {
      "#" -> "%23"
      " " -> "%20"
      _ -> uri.percent_encode(g)
    }
  })
  |> string.concat
}

/// Discover active call on a channel (REST probe used on navigate).
/// Pass `api_bearer` so private channels authorize (see freeq-app `authedFetch`).
pub fn probe_active_call(
  channel: String,
  bearer: Option(String),
) -> Option(ActiveCall) {
  fetch_channel_sessions(channel, bearer)
  |> active_call_from_sessions
}
