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
import gleam/uri
import logging

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
pub fn fetch_channel_topic(channel: String) -> Option(String) {
  let ch = render.canonical_channel(channel)
  let encoded = uri.percent_encode(ch)
  let url = config.upstream_rest() <> "/api/v1/channels/" <> encoded <> "/topic"
  case get_json(url, None) {
    Ok(body) ->
      case
        json.parse(body, {
          use topic <- decode.optional_field("topic", "", decode.string)
          decode.success(topic)
        })
      {
        Ok(t) if t != "" -> Some(t)
        _ -> None
      }
    Error(_) -> None
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

fn decode_channels(body: String) -> List(ChannelInfo) {
  let decoder = {
    use name <- decode.field("name", decode.string)
    use topic <- decode.optional_field("topic", "", decode.string)
    use members <- decode.optional_field("members", 0, decode.int)
    decode.success(ChannelInfo(name:, topic:, members:))
  }
  case json.parse(body, decode.list(decoder)) {
    Ok(list) -> list
    Error(_) -> []
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
