//// Port of freeq-web3 `Irc.Render` / freeq-web2 `IrcRender`.
////
//// Pure functions: channel names, IRC tags, message lines, history rows,
//// nick colours, member lists, topic changes.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

/// Visual/semantic kind of a structured chat row in the message stream.
pub type Kind {
  /// Channel PRIVMSG (user chat).
  Msg
  /// NOTICE (server or user).
  Notice
  /// JOIN presence line.
  Join
  /// PART presence line.
  Part
  /// QUIT presence line.
  Quit
  /// Local system / status line (not from IRC).
  System
}

/// Link preview card kind (YouTube / Bluesky / generic Open Graph).
pub type EmbedKind {
  /// freeq-server `/api/v1/og` metadata.
  Og
  /// YouTube watch / short / youtu.be.
  Youtube
  /// Bluesky post card (`bsky.app/profile/.../post/...`).
  Bsky
}

/// Bluesky-specific card fields.
pub type BskyMeta {
  BskyMeta(
    display: String,
    handle: String,
    text: String,
    likes: Int,
    reposts: Int,
    time: String,
    avatar_url: Option(String),
  )
}

/// Resolved Open Graph / YouTube / Bluesky card attached to a message row.
pub type Embed {
  Embed(
    kind: EmbedKind,
    href: String,
    title: Option(String),
    description: Option(String),
    site_name: Option(String),
    domain: Option(String),
    /// Same-origin `/preview-cache/:id` or remote URL fallback.
    image_url: Option(String),
    video_id: Option(String),
    bsky: Option(BskyMeta),
  )
}

/// One rendered message or presence line in the chat stream.
pub type Row {
  Row(
    id: String,
    kind: Kind,
    nick: Option(String),
    text: String,
    msgid: Option(String),
    time_label: String,
    /// Unix seconds from REST (or None for live IRC without a stored ts).
    /// Used as the cursor for `?before=` history pagination.
    timestamp: Option(Int),
    own: Bool,
    color: String,
    parent: Option(String),
    account: Option(String),
    /// emoji → reactor nicks (from `+freeq.at/reactions` or live TAGMSG).
    reactions: Dict(String, List(String)),
    /// Link preview card (resolved async; may be None until warmup).
    embed: Option(Embed),
    /// True after a `+draft/edit` / REST `replaces_msgid` update landed.
    edited: Bool,
    /// Soft-deleted via `+draft/delete` (placeholder row stays for continuity).
    deleted: Bool,
  )
}

/// Channel roster entry from 353 / JOIN / MODE (+o/+h/+v).
///
/// `did` is filled from extended-join / account-tag learning when known.
pub type Member {
  Member(
    nick: String,
    op: Bool,
    halfop: Bool,
    voice: Bool,
    color: String,
    did: Option(String),
  )
}

/// One privilege change from a channel MODE line: mode letter, adding?, target nick.
pub type ModeOp {
  ModeOp(mode: String, adding: Bool, target: String)
}

const nick_classes = ["n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8"]

/// Ensure channel has a leading `#`.
pub fn canonical_channel(s: String) -> String {
  let s = string.trim(s)
  case string.starts_with(s, "#") {
    True -> s
    False -> "#" <> s
  }
}

/// Channel name without leading `#`.
pub fn bare_channel(s: String) -> String {
  canonical_channel(s)
  |> string.trim_start
  |> drop_leading_hash
}

/// Sanitize an AT handle into a legal IRC nick (max 20, [A-Za-z0-9.\-_]).
pub fn sanitize_nick(handle: String) -> String {
  let out =
    string.to_graphemes(handle)
    |> list.filter(fn(g) {
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
        | "."
        | "-"
        | "_" -> True
        _ -> False
      }
    })
    |> list.take(20)
    |> string.concat
  case out {
    "" -> ""
    _ ->
      case string.first(out) {
        Ok(ch) ->
          case is_alpha(ch) {
            True -> out
            False -> string.slice("u" <> out, 0, 20)
          }
        Error(_) -> out
      }
  }
}

fn is_alpha(g: String) -> Bool {
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
    | "z" -> True
    _ -> False
  }
}

fn drop_leading_hash(s: String) -> String {
  case string.starts_with(s, "#") {
    True -> string.drop_start(s, 1)
    False -> s
  }
}

/// djb2 nick colour class (`n1`…`n8`).
pub fn nick_color_class(nick: String) -> String {
  let h =
    string.to_utf_codepoints(nick)
    |> list.fold(5381, fn(acc, cp) {
      let code = string.utf_codepoint_to_int(cp)
      // 32-bit wrap
      int.bitwise_and(acc * 33 + code, 0xFFFF_FFFF)
    })
  let idx = int.absolute_value(h) % 8
  case list.drop(nick_classes, idx) {
    [c, ..] -> c
    [] -> "n1"
  }
}

/// Parse `@key=value;… rest` → tags map + remainder.
pub fn parse_irc_tags(line: String) -> #(List(#(String, String)), String) {
  let line = string.trim_end(line)
  case string.starts_with(line, "@") {
    False -> #([], line)
    True -> {
      let rest = string.drop_start(line, 1)
      case string.split_once(rest, " ") {
        Ok(#(tag_part, after)) -> #(parse_tag_part(tag_part), after)
        Error(_) -> #([], line)
      }
    }
  }
}

fn parse_tag_part(tag_part: String) -> List(#(String, String)) {
  string.split(tag_part, ";")
  |> list.filter_map(fn(item) {
    case string.split_once(item, "=") {
      Ok(#(k, v)) if k != "" -> Ok(#(k, unescape_tag_value(v)))
      Error(_) if item != "" -> Ok(#(item, ""))
      _ -> Error(Nil)
    }
  })
}

pub fn unescape_tag_value(s: String) -> String {
  do_unescape(string.to_graphemes(s), [])
}

fn do_unescape(chars: List(String), acc: List(String)) -> String {
  case chars {
    [] ->
      acc
      |> list.reverse
      |> string.concat
    ["\\", ":", ..rest] -> do_unescape(rest, [";", ..acc])
    ["\\", "s", ..rest] -> do_unescape(rest, [" ", ..acc])
    ["\\", "\\", ..rest] -> do_unescape(rest, ["\\", ..acc])
    ["\\", "r", ..rest] -> do_unescape(rest, ["\r", ..acc])
    ["\\", "n", ..rest] -> do_unescape(rest, ["\n", ..acc])
    ["\\"] -> do_unescape([], ["\\", ..acc])
    ["\\", c, ..rest] -> do_unescape(rest, [c, "\\", ..acc])
    [c, ..rest] -> do_unescape(rest, [c, ..acc])
  }
}

pub fn escape_tag_value(s: String) -> String {
  string.to_graphemes(s)
  |> list.map(fn(g) {
    case g {
      ";" -> "\\:"
      " " -> "\\s"
      "\\" -> "\\\\"
      "\r" -> "\\r"
      "\n" -> "\\n"
      other -> other
    }
  })
  |> string.concat
}

/// Extract PING token from an IRC line, or `None`.
pub fn ping_token(line: String) -> Option(String) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  let rest = strip_server_prefix(rest)
  case string.split(rest, " ") {
    ["PING", token, ..] ->
      Some(
        token
        |> string.trim_end
        |> string.trim_start
        |> drop_leading_colon,
      )
    ["PING"] -> Some("")
    _ -> None
  }
}

/// IRCv3 `BATCH` open / close (message-tags batching).
///
/// freeq-server wraps CHATHISTORY replay in `BATCH +ref chathistory …` …
/// `BATCH -ref`. The Live session host suppresses per-line Diffs while a
/// batch is open and paints once on close (reaction hydration used to remount
/// `#messages` once per PRIVMSG).
pub type BatchControl {
  BatchOpen(ref: String, kind: String)
  BatchClose(ref: String)
}

/// Parse `BATCH +ref [type …]` / `BATCH -ref`, or `None` if not a BATCH frame.
pub fn parse_batch_control(line: String) -> Option(BatchControl) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  let rest = strip_server_prefix(rest)
  case string.split(rest, " ") {
    ["BATCH", marker, ..rest_parts] -> {
      let marker = string.trim(marker)
      case string.starts_with(marker, "+") {
        True -> {
          let ref = string.drop_start(marker, 1)
          case ref {
            "" -> None
            r -> {
              let kind = case rest_parts {
                [k, ..] -> string.lowercase(string.trim(k))
                [] -> ""
              }
              Some(BatchOpen(r, kind))
            }
          }
        }
        False ->
          case string.starts_with(marker, "-") {
            True -> {
              let ref = string.drop_start(marker, 1)
              case ref {
                "" -> None
                r -> Some(BatchClose(r))
              }
            }
            False -> None
          }
      }
    }
    _ -> None
  }
}

fn strip_server_prefix(line: String) -> String {
  case string.starts_with(line, ":") {
    False -> line
    True ->
      case string.split_once(line, " ") {
        Ok(#(_, rest)) -> rest
        Error(_) -> line
      }
  }
}

fn tag_get(tags: List(#(String, String)), key: String) -> Option(String) {
  case list.find(tags, fn(pair) { pair.0 == key }) {
    Ok(#(_, v)) -> Some(v)
    Error(_) -> None
  }
}

@external(erlang, "os", "system_time")
fn os_system_time() -> Int

fn unix_seconds() -> Int {
  // os:system_time/0 returns native time unit (ns on most BEAMs).
  os_system_time() / 1_000_000_000
}

fn unique_id() -> String {
  let sec = unix_seconds()
  let nanos = os_system_time() % 1_000_000_000
  "row-" <> int.to_string(sec) <> "-" <> int.to_string(nanos % 1_000_000)
}

/// Local system / status row (connection, server notices, errors).
///
/// Used by the System channel tab — not from a channel PRIVMSG.
pub fn system_row(text: String) -> Row {
  let now = unix_seconds()
  Row(
    id: unique_id(),
    kind: System,
    nick: None,
    text: text,
    msgid: None,
    time_label: time_label_from_unix(now),
    timestamp: Some(now),
    own: False,
    color: "",
    parent: None,
    account: None,
    reactions: dict.new(),
    embed: None,
    edited: False,
    deleted: False,
  )
}

fn time_label_now() -> String {
  // UTC 12h SSR fallback; browser rewrites via data-ts → local 12h.
  time_label_from_unix(unix_seconds())
}

/// UTC 12-hour clock for a unix timestamp (`4:05 PM` with NBSP).
/// Browser `localizeTimes` rewrites to the user's local zone when `data-ts` is set.
pub fn time_label_from_unix(sec: Int) -> String {
  let day_sec = positive_mod(sec, 86_400)
  let h = day_sec / 3600
  let m = { day_sec % 3600 } / 60
  format_12h(h, m)
}

/// `hour` 0–23, `minute` 0–59 → `"12:05 PM"` (NBSP before meridiem, web3 parity).
fn format_12h(hour24: Int, minute: Int) -> String {
  let period = case hour24 >= 12 {
    True -> "PM"
    False -> "AM"
  }
  let hour12 = case hour24 % 12 {
    0 -> 12
    h -> h
  }
  int.to_string(hour12) <> ":" <> pad2(minute) <> "\u{00A0}" <> period
}

fn positive_mod(n: Int, m: Int) -> Int {
  let r = n % m
  case r < 0 {
    True -> r + m
    False -> r
  }
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

/// Parse IRCv3 `time` / RFC3339 (`2026-07-24T20:06:25.000Z`) → unix seconds (UTC).
pub fn parse_iso_unix(iso: String) -> Option(Int) {
  let s = string.trim(iso)
  // Drop trailing Z or numeric offset (+00:00 / -05:00) for freeq's Zulu stamps.
  let s = case string.ends_with(s, "Z") || string.ends_with(s, "z") {
    True -> string.drop_end(s, 1)
    False -> drop_numeric_offset(s)
  }
  case string.split_once(s, "T") {
    Error(_) -> None
    Ok(#(date, time)) -> {
      let time = case string.split_once(time, ".") {
        Ok(#(hms, _)) -> hms
        Error(_) -> time
      }
      case string.split(date, "-"), string.split(time, ":") {
        [ys, ms, ds], [hs, mis, ss] ->
          case
            int.parse(ys),
            int.parse(ms),
            int.parse(ds),
            int.parse(hs),
            int.parse(mis),
            int.parse(ss)
          {
            Ok(y), Ok(mo), Ok(d), Ok(h), Ok(mi), Ok(sec) ->
              Some(unix_from_civil(y, mo, d, h, mi, sec))
            _, _, _, _, _, _ -> None
          }
        _, _ -> None
      }
    }
  }
}

/// Strip a trailing `+HH:MM` / `-HH:MM` offset when present (not applied to the clock).
fn drop_numeric_offset(s: String) -> String {
  // Look for the last + or - after the T (time part).
  case string.split_once(s, "T") {
    Error(_) -> s
    Ok(#(date, time)) -> {
      let time = case string.split_once(time, "+") {
        Ok(#(hms, _)) -> hms
        Error(_) ->
          // Minus only after HH:MM:SS (avoid date dashes).
          case string.split(time, "-") {
            [hms] -> hms
            [hms, ..] -> hms
            [] -> time
          }
      }
      date <> "T" <> time
    }
  }
}

/// Days since Unix epoch for civil date, then add clock → unix seconds (UTC).
/// Howard Hinnant civil-from-days inverse (proleptic Gregorian).
fn unix_from_civil(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int,
) -> Int {
  let y = case month <= 2 {
    True -> year - 1
    False -> year
  }
  let era = case y >= 0 {
    True -> y / 400
    False -> { y - 399 } / 400
  }
  let yoe = y - era * 400
  let mp = case month > 2 {
    True -> month - 3
    False -> month + 9
  }
  let doy = { 153 * mp + 2 } / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  let days = era * 146_097 + doe - 719_468
  days * 86_400 + hour * 3600 + minute * 60 + second
}

fn nick_matches(nick: String, own: Option(String)) -> Bool {
  case own {
    Some(o) -> string.lowercase(nick) == string.lowercase(o)
    None -> False
  }
}

/// Parent msgid from IRCv3 reply tags (`+reply` / `reply` / `draft/reply`).
pub fn reply_parent(tags: List(#(String, String))) -> Option(String) {
  case tag_get(tags, "+reply") {
    Some(v) -> non_empty(v)
    None ->
      case tag_get(tags, "reply") {
        Some(v) -> non_empty(v)
        None ->
          case tag_get(tags, "draft/reply") {
            Some(v) -> non_empty(v)
            None -> None
          }
      }
  }
}

fn non_empty(s: String) -> Option(String) {
  case string.trim(s) {
    "" -> None
    t -> Some(t)
  }
}

/// Collapse whitespace and cap length for reply-badge / banner snippets.
pub fn preview_text(text: String) -> String {
  let collapsed =
    text
    |> string.replace("\n", " ")
    |> string.replace("\r", " ")
    |> string.replace("\t", " ")
    |> collapse_spaces
    |> string.trim
  case string.length(collapsed) > 80 {
    True -> string.slice(collapsed, 0, 80) <> "…"
    False -> collapsed
  }
}

fn collapse_spaces(s: String) -> String {
  // Repeated passes for runs of spaces left by whitespace replacement.
  case string.contains(s, "  ") {
    True -> collapse_spaces(string.replace(s, "  ", " "))
    False -> s
  }
}

/// Parse a PRIVMSG/NOTICE/JOIN/PART/QUIT line into a row.
///
/// Protocol noise (CAP, numerics, BATCH, MOTD, MODE, …) returns `None` so the
/// chat stream never dumps raw IRC registration / chathistory framing.
pub fn parse_message_line(
  line: String,
  own_nick: Option(String),
) -> Option(Row) {
  let line = string.trim_end(line)
  let #(tags, rest) = parse_irc_tags(line)
  // IRCv3 chathistory arrives inside BATCH with a `batch=` tag. freeq-web4
  // already loads history via REST — rendering the batch again doubles the
  // stream and scrambles chronology. Live traffic is untagged.
  // Reaction tallies on batch lines are recovered via `parse_history_reactions`.
  case tag_get(tags, "batch") {
    Some(_) -> None
    None -> parse_message_line_body(tags, rest, own_nick)
  }
}

/// Extract `msgid` + `+freeq.at/reactions` from a PRIVMSG line, including
/// CHATHISTORY `batch=` lines that `parse_message_line` otherwise skips.
///
/// Used to hydrate REST-loaded rows with server-persisted tallies without
/// re-inserting history as live messages.
pub fn parse_history_reactions(
  line: String,
) -> Option(#(String, Dict(String, List(String)))) {
  let #(tags, _rest) = parse_irc_tags(string.trim_end(line))
  case tag_get(tags, "+freeq.at/reactions") {
    None | Some("") -> None
    Some(raw) -> {
      let reactions = parse_reactions_tag(raw)
      case dict.size(reactions) {
        0 -> None
        _ -> {
          let msgid = case tag_get(tags, "+draft/edit") {
            Some(e) if e != "" -> Some(e)
            _ -> tag_get(tags, "msgid")
          }
          case msgid {
            Some(mid) if mid != "" -> Some(#(mid, reactions))
            _ -> None
          }
        }
      }
    }
  }
}

/// Union two reaction maps (emoji → nicks), case-insensitive nick de-dupe.
pub fn merge_reaction_dicts(
  base: Dict(String, List(String)),
  extra: Dict(String, List(String)),
) -> Dict(String, List(String)) {
  dict.fold(extra, base, fn(acc, emoji, nicks) {
    list.fold(nicks, acc, fn(acc2, nick) {
      apply_reaction_map(acc2, emoji, nick, True)
    })
  })
}

fn parse_message_line_body(
  tags: List(#(String, String)),
  rest: String,
  own_nick: Option(String),
) -> Option(Row) {
  let msgid = tag_get(tags, "msgid")
  let edit = case tag_get(tags, "+draft/edit") {
    Some(e) if e != "" -> Some(e)
    _ -> None
  }
  // Edits keep the *original* msgid as the row identity (IRCv3 draft/edit).
  let effective_msgid = case edit {
    Some(e) -> Some(e)
    None -> msgid
  }
  let is_edit = case edit {
    Some(_) -> True
    None -> False
  }
  // Prefer IRCv3 `time` → unix + 12h label; else "now" so live rows still get data-ts.
  let #(time, ts) = case tag_get(tags, "time") {
    Some(iso) -> {
      let unix = case parse_iso_unix(iso) {
        Some(u) -> Some(u)
        None -> Some(unix_seconds())
      }
      let label = case unix {
        Some(u) -> time_label_from_unix(u)
        None -> time_label_from_iso(iso)
      }
      #(label, unix)
    }
    None -> {
      let now = unix_seconds()
      #(time_label_from_unix(now), Some(now))
    }
  }

  case string.starts_with(rest, ":") {
    // Unprefixed client-style commands are not chat content.
    False -> None
    True -> {
      let body = string.drop_start(rest, 1)
      case string.split_once(body, " ") {
        Error(_) -> None
        Ok(#(prefix, cmd_and_args)) -> {
          let nick = case string.split_once(prefix, "!") {
            Ok(#(n, _)) -> n
            Error(_) -> prefix
          }
          let parts = string.split(cmd_and_args, " ")
          case parts {
            ["PRIVMSG", _target, ..text_parts]
            | ["NOTICE", _target, ..text_parts] -> {
              let cmd = case parts {
                ["NOTICE", ..] -> Notice
                _ -> Msg
              }
              let text =
                text_parts
                |> string.join(" ")
                |> string.trim_start
                |> drop_leading_colon
              let color = nick_color_class(nick)
              let id = option.unwrap(effective_msgid, unique_id())
              let reactions = case tag_get(tags, "+freeq.at/reactions") {
                Some(raw) -> parse_reactions_tag(raw)
                None -> dict.new()
              }
              Some(
                Row(
                  id: id,
                  kind: cmd,
                  nick: Some(nick),
                  text: text,
                  msgid: effective_msgid,
                  time_label: time,
                  timestamp: ts,
                  own: nick_matches(nick, own_nick),
                  color: color,
                  parent: reply_parent(tags),
                  account: case tag_get(tags, "account") {
                    Some(a) -> Some(a)
                    None -> tag_get(tags, "+account")
                  },
                  reactions: reactions,
                  embed: None,
                  edited: is_edit,
                  deleted: False,
                ),
              )
            }
            ["JOIN", ..] ->
              Some(Row(
                id: unique_id(),
                kind: Join,
                nick: Some(nick),
                text: "joined",
                msgid: None,
                time_label: time,
                timestamp: ts,
                own: False,
                color: nick_color_class(nick),
                parent: None,
                account: None,
                reactions: dict.new(),
                embed: None,
                edited: False,
                deleted: False,
              ))
            ["PART", ..] ->
              Some(Row(
                id: unique_id(),
                kind: Part,
                nick: Some(nick),
                text: "left",
                msgid: None,
                time_label: time,
                timestamp: ts,
                own: False,
                color: nick_color_class(nick),
                parent: None,
                account: None,
                reactions: dict.new(),
                embed: None,
                edited: False,
                deleted: False,
              ))
            ["QUIT", ..] ->
              Some(Row(
                id: unique_id(),
                kind: Quit,
                nick: Some(nick),
                text: "quit",
                msgid: None,
                time_label: time,
                timestamp: ts,
                own: False,
                color: nick_color_class(nick),
                parent: None,
                account: None,
                reactions: dict.new(),
                embed: None,
                edited: False,
                deleted: False,
              ))
            // CAP / numerics / BATCH / MODE / TOPIC / etc. — not chat rows.
            _ -> None
          }
        }
      }
    }
  }
}

/// Best-effort 12h label from IRCv3 `time` when full ISO parse fails.
fn time_label_from_iso(iso: String) -> String {
  case parse_iso_unix(iso) {
    Some(u) -> time_label_from_unix(u)
    None ->
      case string.split(iso, "T") {
        [_, clock, ..] -> {
          let clock = case string.split_once(clock, ".") {
            Ok(#(hms, _)) -> hms
            Error(_) ->
              case string.split_once(clock, "Z") {
                Ok(#(hms, _)) -> hms
                Error(_) -> clock
              }
          }
          case string.split(clock, ":") {
            [h, m, ..] ->
              case int.parse(h), int.parse(m) {
                Ok(hh), Ok(mm) -> format_12h(hh, mm)
                _, _ -> time_label_now()
              }
            _ -> time_label_now()
          }
        }
        _ -> time_label_now()
      }
  }
}

fn drop_leading_colon(s: String) -> String {
  case string.starts_with(s, ":") {
    True -> string.drop_start(s, 1)
    False -> s
  }
}

/// Convert a REST history message JSON object into a row.
///
/// Expects decoded dynamic fields already as a string map-like list of pairs
/// from the REST client (`sender`, `text`, `msgid`, `timestamp`, optional
/// `parent` from tags `+reply` / `reply` / `draft/reply`, optional
/// `reactions` from `+freeq.at/reactions`, optional `account` DID).
pub fn history_row(
  sender: String,
  text: String,
  msgid: Option(String),
  timestamp_unix: Option(Int),
  parent: Option(String),
  reactions: Dict(String, List(String)),
) -> Row {
  history_row_with_account(
    sender,
    text,
    msgid,
    timestamp_unix,
    parent,
    reactions,
    None,
  )
}

/// Like `history_row` but with an explicit sender DID (`account` tag).
pub fn history_row_with_account(
  sender: String,
  text: String,
  msgid: Option(String),
  timestamp_unix: Option(Int),
  parent: Option(String),
  reactions: Dict(String, List(String)),
  account: Option(String),
) -> Row {
  let nick = case string.split_once(sender, "!") {
    Ok(#(n, _)) -> n
    Error(_) -> sender
  }
  let id = option.unwrap(msgid, unique_id())
  let time = case timestamp_unix {
    Some(sec) -> time_label_from_unix(sec)
    None -> time_label_now()
  }
  Row(
    id: id,
    kind: Msg,
    nick: Some(nick),
    text: text,
    msgid: msgid,
    time_label: time,
    timestamp: timestamp_unix,
    own: False,
    color: nick_color_class(nick),
    parent: parent,
    account: account,
    reactions: reactions,
    embed: None,
    edited: False,
    deleted: False,
  )
}

/// Mark a row as an applied edit of `original` (identity stays on original msgid).
///
/// Edits do not revive a soft-deleted message.
pub fn apply_edit_to_row(row: Row, new_text: String) -> Row {
  case row.deleted {
    True -> row
    False -> {
      let text = case string.trim(new_text) {
        "" -> "[message cleared]"
        t -> t
      }
      Row(..row, text: text, edited: True)
    }
  }
}

/// Soft-delete a row in place (keep msgid for continuity / scroll targets).
pub fn mark_row_deleted(row: Row) -> Row {
  Row(
    ..row,
    deleted: True,
    text: "",
    reactions: dict.new(),
    embed: None,
  )
}

/// Collapse REST history rows that carry `replaces_msgid` into their originals.
///
/// freeq-server stores each edit as a *new* row pointing at the root msgid.
/// Clients keep a single row per original identity and show an (edited) badge.
pub fn collapse_history_edits(
  rows: List(#(Row, Option(String))),
) -> List(Row) {
  let empty: List(Row) = []
  list.fold(rows, empty, fn(acc, pair) {
    let #(row, replaces) = pair
    case replaces {
      Some(orig) if orig != "" ->
        case list.any(acc, fn(r) { r.msgid == Some(orig) }) {
          True ->
            list.map(acc, fn(r) {
              case r.msgid {
                Some(m) if m == orig -> apply_edit_to_row(r, row.text)
                _ -> r
              }
            })
          False -> {
            // Orphan edit (original outside the page): show as that msgid.
            let collapsed =
              Row(
                ..row,
                id: orig,
                msgid: Some(orig),
                edited: True,
              )
            list.append(acc, [collapsed])
          }
        }
      _ -> list.append(acc, [row])
    }
  })
}

/// Smallest unix timestamp among rows that have one (for REST `?before=`).
pub fn oldest_timestamp(rows: List(Row)) -> Option(Int) {
  list.fold(rows, None, fn(acc, row) {
    case row.timestamp, acc {
      Some(t), None -> Some(t)
      Some(t), Some(min) if t < min -> Some(t)
      _, _ -> acc
    }
  })
}

/// Parse server-persisted reaction tallies: `👍:alice,bob;❤️:carol`.
pub fn parse_reactions_tag(value: String) -> Dict(String, List(String)) {
  case string.trim(value) {
    "" -> dict.new()
    v ->
      string.split(v, ";")
      |> list.fold(dict.new(), fn(acc, group) {
        case string.split_once(group, ":") {
          Ok(#(emoji, nicks)) if emoji != "" -> {
            let nick_list =
              string.split(nicks, ",")
              |> list.filter(fn(n) { string.trim(n) != "" })
            case nick_list {
              [] -> acc
              _ -> dict.insert(acc, emoji, nick_list)
            }
          }
          _ -> acc
        }
      })
  }
}

/// Live reaction TAGMSG: `+react` / `+draft/react` add, `+freeq.at/unreact` remove.
///
/// Returns `#(msgid, emoji, nick, added, channel)`.
pub fn parse_tagmsg_reaction(
  line: String,
) -> Option(#(String, String, String, Bool, String)) {
  let #(tags, after) = parse_irc_tags(string.trim_end(line))
  let emoji_added = case tag_get(tags, "+react") {
    Some(e) if e != "" -> Some(#(e, True))
    _ ->
      case tag_get(tags, "+draft/react") {
        Some(e) if e != "" -> Some(#(e, True))
        _ ->
          case tag_get(tags, "+freeq.at/unreact") {
            Some(e) if e != "" -> Some(#(e, False))
            _ -> None
          }
      }
  }
  case emoji_added, tag_get(tags, "+reply") {
    Some(#(emoji, added)), Some(msgid) ->
      case string.trim(msgid) {
        "" -> None
        mid -> {
          let rest = case string.starts_with(after, ":") {
            True -> string.drop_start(after, 1)
            False -> after
          }
          let parts = string.split(rest, " ")
          case parts {
            [prefix, cmd, ch, ..] ->
              case string.uppercase(cmd) == "TAGMSG" {
                False -> None
                True -> {
                  let nick = case string.split_once(prefix, "!") {
                    Ok(#(n, _)) -> n
                    Error(_) -> prefix
                  }
                  let channel =
                    ch
                    |> drop_leading_colon
                    |> canonical_channel
                  Some(#(mid, emoji, nick, added, channel))
                }
              }
            _ -> None
          }
        }
      }
    _, _ -> None
  }
}

/// Add or remove a nick under an emoji key (idempotent).
pub fn apply_reaction_map(
  reactions: Dict(String, List(String)),
  emoji: String,
  nick: String,
  added: Bool,
) -> Dict(String, List(String)) {
  let nick_l = string.lowercase(nick)
  let nicks = case dict.get(reactions, emoji) {
    Ok(ns) -> ns
    Error(_) -> []
  }
  let nicks = case added {
    True ->
      case list.any(nicks, fn(n) { string.lowercase(n) == nick_l }) {
        True -> nicks
        False -> list.append(nicks, [nick])
      }
    False -> list.filter(nicks, fn(n) { string.lowercase(n) != nick_l })
  }
  case nicks {
    [] -> dict.delete(reactions, emoji)
    _ -> dict.insert(reactions, emoji, nicks)
  }
}

/// Stable emoji → nicks entries for chip rendering (sorted by emoji).
pub fn reaction_entries(
  reactions: Dict(String, List(String)),
) -> List(#(String, List(String))) {
  dict.to_list(reactions)
  |> list.filter(fn(pair) {
    let #(_, nicks) = pair
    nicks != []
  })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

/// Chip label: emoji alone, or `emoji N` when multiple reactors.
pub fn reaction_chip_label(emoji: String, nicks: List(String)) -> String {
  case list.length(nicks) {
    n if n <= 1 -> emoji
    n -> emoji <> " " <> int.to_string(n)
  }
}

/// Default reaction palette (freeq-web2 / web3 parity).
pub fn react_emojis() -> List(String) {
  ["👍", "❤️", "😂", "🎉", "🔥", "👀", "💯", "✨"]
}

/// Client → server: add or remove a reaction via TAGMSG.
pub fn react_line(
  channel: String,
  msgid: String,
  emoji: String,
  added: Bool,
) -> String {
  let ch = canonical_channel(channel)
  let tag = case added {
    True -> "+react"
    False -> "+freeq.at/unreact"
  }
  let tags =
    tag
    <> "="
    <> escape_tag_value(emoji)
    <> ";+reply="
    <> escape_tag_value(msgid)
  "@" <> tags <> " TAGMSG " <> ch <> "\r\n"
}

/// Client → server: soft-delete a message (`@+draft/delete=<msgid> TAGMSG`).
pub fn delete_line(channel: String, msgid: String) -> String {
  let ch = canonical_channel(channel)
  "@+draft/delete="
  <> escape_tag_value(msgid)
  <> " TAGMSG "
  <> ch
  <> "\r\n"
}

/// Live delete TAGMSG: `+draft/delete=<msgid>`.
///
/// Returns `#(msgid, deleter_nick, channel)`.
pub fn parse_tagmsg_delete(
  line: String,
) -> Option(#(String, String, String)) {
  let #(tags, after) = parse_irc_tags(string.trim_end(line))
  case tag_get(tags, "+draft/delete") {
    Some(mid) ->
      case string.trim(mid) {
        "" -> None
        msgid -> {
          let rest = case string.starts_with(after, ":") {
            True -> string.drop_start(after, 1)
            False -> after
          }
          let parts = string.split(rest, " ")
          case parts {
            [prefix, cmd, ch, ..] ->
              case string.uppercase(cmd) == "TAGMSG" {
                False -> None
                True -> {
                  let nick = case string.split_once(prefix, "!") {
                    Ok(#(n, _)) -> n
                    Error(_) -> prefix
                  }
                  let channel =
                    ch
                    |> drop_leading_colon
                    |> canonical_channel
                  Some(#(msgid, nick, channel))
                }
              }
            _ -> None
          }
        }
      }
    None -> None
  }
}

/// Request latest N messages (IRCv3 draft/chathistory). freeq-server attaches
/// `+freeq.at/reactions` on the batch PRIVMSGs — used to hydrate REST history.
pub fn chathistory_latest_line(channel: String, count: Int) -> String {
  let n = case count > 0 {
    True -> count
    False -> 50
  }
  "CHATHISTORY LATEST "
  <> canonical_channel(channel)
  <> " * "
  <> int.to_string(n)
  <> "\r\n"
}

/// Request N messages strictly before a unix timestamp (scroll-up pagination).
///
/// freeq-server also attaches `+freeq.at/reactions` on the batch lines so
/// REST-prepended bodies can pick up chips the same way as LATEST.
pub fn chathistory_before_line(
  channel: String,
  before_ts: Int,
  count: Int,
) -> String {
  let n = case count > 0 {
    True -> count
    False -> 50
  }
  "CHATHISTORY BEFORE "
  <> canonical_channel(channel)
  <> " timestamp="
  <> int.to_string(before_ts)
  <> " "
  <> int.to_string(n)
  <> "\r\n"
}

/// Channel target of a live PRIVMSG/NOTICE, if the target is a channel.
///
/// Returns canonical `#name` for channel messages; `None` for DMs, numerics,
/// or non-chat lines. Used to scope the message stream and unread badges.
pub fn message_target_channel(line: String) -> Option(String) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  case string.starts_with(rest, ":") {
    False -> None
    True -> {
      let body = string.drop_start(rest, 1)
      case string.split_once(body, " ") {
        Error(_) -> None
        Ok(#(_prefix, cmd_and_args)) -> {
          let parts = string.split(cmd_and_args, " ")
          case parts {
            ["PRIVMSG", target, ..] | ["NOTICE", target, ..] -> {
              let t = drop_leading_colon(target)
              case string.starts_with(t, "#") || string.starts_with(t, "&") {
                True -> Some(canonical_channel(t))
                False -> None
              }
            }
            _ -> None
          }
        }
      }
    }
  }
}

/// Whether the line is RPL_NAMREPLY (353).
pub fn is_353(line: String) -> Bool {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  string.contains(rest, " 353 ")
}

/// Channel name from a 353 line (`353 me = #chan :names`).
pub fn channel_from_353(line: String) -> Option(String) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  let rest = strip_server_prefix(rest)
  // Drop trailing names segment so channel tokens stay in the middle.
  let head = case string.split_once(rest, " :") {
    Ok(#(h, _)) -> h
    Error(_) -> rest
  }
  string.split(head, " ")
  |> list.find(fn(p) {
    string.starts_with(p, "#") || string.starts_with(p, "&")
  })
  |> option.from_result
  |> option.map(canonical_channel)
}

/// Parse RPL_NAMREPLY (353) member tokens → members.
pub fn parse_353_members(line: String) -> List(Member) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  // :server 353 me = #chan :@op +voice nick
  case string.split_once(rest, " :") {
    Ok(#(_, names)) ->
      string.split(names, " ")
      |> list.filter(fn(t) { t != "" })
      |> list.map(parse_member_token)
    Error(_) ->
      case string.split(rest, ":") {
        parts ->
          case list.last(parts) {
            Ok(names) ->
              string.split(names, " ")
              |> list.filter(fn(t) { t != "" })
              |> list.map(parse_member_token)
            Error(_) -> []
          }
      }
  }
}

fn parse_member_token(token: String) -> Member {
  // Multi-prefix tokens: ~&@%+ (founder/admin/op/halfop/voice).
  let #(prefixes, nick) = split_nick_prefixes(token)
  let op =
    string.contains(prefixes, "@")
    || string.contains(prefixes, "~")
    || string.contains(prefixes, "&")
  let halfop = string.contains(prefixes, "%")
  let voice = string.contains(prefixes, "+")
  Member(
    nick: nick,
    op: op,
    halfop: halfop,
    voice: voice,
    color: nick_color_class(nick),
    did: None,
  )
}

fn split_nick_prefixes(token: String) -> #(String, String) {
  do_split_prefixes(string.to_graphemes(token), [])
}

fn do_split_prefixes(
  chars: List(String),
  acc: List(String),
) -> #(String, String) {
  case chars {
    ["@" as c, ..rest]
    | ["%" as c, ..rest]
    | ["+" as c, ..rest]
    | ["~" as c, ..rest]
    | ["&" as c, ..rest] -> do_split_prefixes(rest, [c, ..acc])
    _ -> #(string.concat(list.reverse(acc)), string.concat(chars))
  }
}

/// Sort members: ops → halfops → voice → plain, then nick (case-insensitive).
pub fn sort_members(members: List(Member)) -> List(Member) {
  list.sort(members, fn(a, b) {
    let ra = member_rank(a)
    let rb = member_rank(b)
    case int.compare(ra, rb) {
      order.Eq ->
        string.compare(string.lowercase(a.nick), string.lowercase(b.nick))
      other -> other
    }
  })
}

fn member_rank(m: Member) -> Int {
  case m.op, m.halfop, m.voice {
    True, _, _ -> 0
    False, True, _ -> 1
    False, False, True -> 2
    False, False, False -> 3
  }
}

/// Display prefix character for the userlist (`@` / `%` / `+` / empty).
pub fn member_prefix_char(m: Member) -> String {
  case m.op, m.halfop, m.voice {
    True, _, _ -> "@"
    False, True, _ -> "%"
    False, False, True -> "+"
    False, False, False -> ""
  }
}

/// CSS class on `.pfx` for privilege colouring.
pub fn member_prefix_class(m: Member) -> String {
  case m.op, m.halfop, m.voice {
    True, _, _ -> "op"
    False, True, _ -> "halfop"
    False, False, True -> "voice"
    False, False, False -> ""
  }
}

/// Apply MODE o/h/v ops to a member list (current channel only).
pub fn apply_mode_ops(
  members: List(Member),
  ops: List(ModeOp),
) -> List(Member) {
  list.fold(ops, members, fn(acc, op) {
    apply_one_mode(acc, op.mode, op.adding, op.target)
  })
}

fn apply_one_mode(
  members: List(Member),
  mode: String,
  adding: Bool,
  target: String,
) -> List(Member) {
  case list.any(members, fn(m) { m.nick == target }) {
    True ->
      list.map(members, fn(m) {
        case m.nick == target {
          True ->
            case mode {
              "o" -> Member(..m, op: adding)
              "h" -> Member(..m, halfop: adding)
              "v" -> Member(..m, voice: adding)
              _ -> m
            }
          False -> m
        }
      })
    False ->
      case mode {
        "o" | "h" | "v" -> {
          let base =
            Member(
              nick: target,
              op: False,
              halfop: False,
              voice: False,
              color: nick_color_class(target),
              did: None,
            )
          let entry = case mode {
            "o" -> Member(..base, op: adding)
            "h" -> Member(..base, halfop: adding)
            "v" -> Member(..base, voice: adding)
            _ -> base
          }
          list.append(members, [entry])
        }
        _ -> members
      }
  }
}

/// Parse channel MODE → `#(channel, from, modestring, args, ops)`.
///
/// `ops` are privilege letters o/h/v for roster updates; `modestring` + `args`
/// are the full mode for meta display (e.g. `+m`, `+o eve`).
pub fn parse_mode_change(
  line: String,
) -> Option(#(String, String, String, List(String), List(ModeOp))) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  case string.starts_with(rest, ":") {
    False -> None
    True -> {
      let body = string.drop_start(rest, 1)
      case string.split_once(body, " ") {
        Error(_) -> None
        Ok(#(prefix, cmd_args)) -> {
          let from = case string.split_once(prefix, "!") {
            Ok(#(n, _)) -> n
            Error(_) -> prefix
          }
          case string.split(cmd_args, " ") {
            ["MODE", chan, modestring, ..args] -> {
              let chan = drop_leading_colon(chan)
              case
                string.starts_with(chan, "#") || string.starts_with(chan, "&")
              {
                True ->
                  Some(#(
                    canonical_channel(chan),
                    from,
                    modestring,
                    args,
                    parse_mode_ops(modestring, args),
                  ))
                False -> None
              }
            }
            _ -> None
          }
        }
      }
    }
  }
}

/// freeq-app / SDK style: `— nandi.uk set mode +o eve`.
pub fn format_mode_meta(
  from: String,
  modestring: String,
  args: List(String),
) -> String {
  let args_s = case args {
    [] -> ""
    _ -> " " <> string.join(args, " ")
  }
  "— " <> from <> " set mode " <> modestring <> args_s
}

/// Channel KICK → `#(channel, kicker, kicked, reason)`.
pub fn parse_kick(
  line: String,
) -> Option(#(String, String, String, String)) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  case string.starts_with(rest, ":") {
    False -> None
    True -> {
      let body = string.drop_start(rest, 1)
      case string.split_once(body, " ") {
        Error(_) -> None
        Ok(#(prefix, cmd_args)) -> {
          let kicker = case string.split_once(prefix, "!") {
            Ok(#(n, _)) -> n
            Error(_) -> prefix
          }
          case string.split(cmd_args, " ") {
            ["KICK", chan, kicked, ..reason_parts] -> {
              let chan = drop_leading_colon(chan)
              case
                string.starts_with(chan, "#") || string.starts_with(chan, "&")
              {
                True -> {
                  let reason =
                    reason_parts
                    |> string.join(" ")
                    |> drop_leading_colon
                  Some(#(
                    canonical_channel(chan),
                    kicker,
                    drop_leading_colon(kicked),
                    reason,
                  ))
                }
                False -> None
              }
            }
            _ -> None
          }
        }
      }
    }
  }
}

/// freeq-app / SDK style: `— eve kicked by nandi.uk: spam`.
pub fn format_kick_meta(
  kicker: String,
  kicked: String,
  reason: String,
) -> String {
  case string.trim(reason) {
    "" -> "— " <> kicked <> " kicked by " <> kicker
    r -> "— " <> kicked <> " kicked by " <> kicker <> ": " <> r
  }
}

fn parse_mode_ops(modestring: String, args: List(String)) -> List(ModeOp) {
  let #(ops, _) =
    list.fold(string.to_graphemes(modestring), #([], #(True, args)), fn(acc, c) {
      let #(ops, #(adding, remaining)) = acc
      case c {
        "+" -> #(ops, #(True, remaining))
        "-" -> #(ops, #(False, remaining))
        "o" | "h" | "v" ->
          case remaining {
            [target, ..rest] -> #(
              [ModeOp(mode: c, adding: adding, target: target), ..ops],
              #(adding, rest),
            )
            [] -> #(ops, #(adding, remaining))
          }
        _ -> #(ops, #(adding, remaining))
      }
    })
  list.reverse(ops)
}

/// Parse JOIN/PART/QUIT/NICK for member roster updates.
/// Returns `#(kind, nick, channel_opt)`.
pub fn parse_member_change(
  line: String,
) -> Option(#(String, String, Option(String))) {
  case parse_member_change_ex(line) {
    Some(#(kind, nick, ch, _account)) -> Some(#(kind, nick, ch))
    None -> None
  }
}

/// Like `parse_member_change` but also returns extended-join account (DID).
///
/// Extended-join shape: `JOIN #chan did:plc:… :Real Name` or `JOIN #chan * :…`.
/// Account is `None` when missing, `*`, or a trailing realname (`:…`).
pub fn parse_member_change_ex(
  line: String,
) -> Option(#(String, String, Option(String), Option(String))) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  case string.starts_with(rest, ":") {
    False -> None
    True -> {
      let body = string.drop_start(rest, 1)
      case string.split_once(body, " ") {
        Error(_) -> None
        Ok(#(prefix, cmd_args)) -> {
          let nick = case string.split_once(prefix, "!") {
            Ok(#(n, _)) -> n
            Error(_) -> prefix
          }
          case string.split(cmd_args, " ") {
            ["JOIN", chan, ..rest] ->
              Some(#(
                "join",
                nick,
                Some(canonical_channel(drop_leading_colon(chan))),
                join_account_param(rest),
              ))
            ["PART", chan, ..] ->
              Some(#(
                "part",
                nick,
                Some(canonical_channel(drop_leading_colon(chan))),
                None,
              ))
            ["QUIT", ..] -> Some(#("quit", nick, None, None))
            ["NICK", new_nick, ..] ->
              Some(#(
                "nick",
                nick,
                Some(drop_leading_colon(new_nick)),
                None,
              ))
            _ -> None
          }
        }
      }
    }
  }
}

/// Extended-join account token: skip `*` and realname (`:…`).
fn join_account_param(rest: List(String)) -> Option(String) {
  case rest {
    [] -> None
    [first, ..] -> {
      case first {
        "" | "*" -> None
        a ->
          case string.starts_with(a, ":") {
            True -> None
            False -> Some(a)
          }
      }
    }
  }
}

/// Extract `account` tag value from an IRC tags list (or `+account`).
pub fn account_from_tags(tags: List(#(String, String))) -> Option(String) {
  case tag_get(tags, "account") {
    Some(a) -> Some(a)
    None -> tag_get(tags, "+account")
  }
}

/// Account / DID string suitable for avatar lookup (`did:…` preferred).
pub fn normalize_account(raw: String) -> Option(String) {
  let s = string.trim(raw)
  case s == "" || s == "*" {
    True -> None
    False -> Some(s)
  }
}

/// Parse JOIN-failure numerics (471/473/474/475/477).
/// Returns `#(channel, numeric, trailing)` or None.
pub fn parse_join_failure(line: String) -> Option(#(String, String, String)) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  let rest = strip_server_prefix(rest)
  let tokens = string.split(rest, " ")
  case tokens {
    [numeric, _me, chan, ..] ->
      case numeric {
        "471" | "473" | "474" | "475" | "477" ->
          case string.starts_with(chan, "#") || string.starts_with(chan, "&") {
            True -> {
              let trailing = case string.split_once(rest, " :") {
                Ok(#(_, t)) -> t
                Error(_) -> ""
              }
              Some(#(canonical_channel(chan), numeric, trailing))
            }
            False -> None
          }
        _ -> None
      }
    _ -> None
  }
}

/// ERR_CANNOTSENDTOCHAN (404) — PRIVMSG rejected (not joined, +n, ban, …).
/// Returns `#(channel, trailing)`.
pub fn parse_cannot_send(line: String) -> Option(#(String, String)) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  let rest = strip_server_prefix(rest)
  let tokens = string.split(rest, " ")
  case tokens {
    ["404", _me, chan, ..] ->
      case string.starts_with(chan, "#") || string.starts_with(chan, "&") {
        True -> {
          let trailing = case string.split_once(rest, " :") {
            Ok(#(_, t)) -> t
            Error(_) -> "Cannot send to channel"
          }
          Some(#(canonical_channel(chan), trailing))
        }
        False -> None
      }
    _ -> None
  }
}

/// freeq-server demotes a claimed handle nick to Guest when SASL did not bind:
/// `Nick nandi.uk is registered — renamed to Guest15100. Authenticate to reclaim.`
/// Returns the new Guest nick when present.
pub fn parse_guest_nick_rename(line: String) -> Option(String) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  let lower = string.lowercase(rest)
  case string.contains(lower, "renamed to guest") {
    False -> None
    True -> {
      // Take the token after "renamed to" (case-insensitive scan on original).
      case string.split_once(lower, "renamed to ") {
        Error(_) -> None
        Ok(#(_, after)) -> {
          let token =
            after
            |> string.split(" ")
            |> list.first
            |> result.unwrap("")
            |> string.trim_end
            |> string.replace(".", "")
            |> string.replace(",", "")
          // Recover original casing from the un-lowercased line when possible.
          case token {
            "" -> None
            t ->
              case string.contains(string.lowercase(t), "guest") {
                True -> Some(recover_token_case(rest, t))
                False -> None
              }
          }
        }
      }
    }
  }
}

fn recover_token_case(original: String, lower_token: String) -> String {
  // Scan original words for a case-insensitive match.
  let words = string.split(original, " ")
  case
    list.find(words, fn(w) {
      string.lowercase(string.replace(string.replace(w, ".", ""), ",", ""))
      == lower_token
    })
  {
    Ok(w) -> string.replace(string.replace(w, ".", ""), ",", "")
    Error(_) -> lower_token
  }
}

/// TOPIC change / 332 RPL_TOPIC.
pub fn parse_topic(line: String) -> Option(#(String, String)) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  let rest = strip_server_prefix(rest)
  case string.split(rest, " ") {
    ["TOPIC", chan, ..text_parts] -> {
      let topic =
        text_parts
        |> string.join(" ")
        |> drop_leading_colon
      Some(#(canonical_channel(chan), topic))
    }
    // 332 me #chan :topic
    ["332", _me, chan, ..text_parts] -> {
      let topic =
        text_parts
        |> string.join(" ")
        |> drop_leading_colon
      Some(#(canonical_channel(chan), topic))
    }
    _ -> None
  }
}

/// Whether the line is a welcome numeric (001–004) after CAP END.
pub fn welcome_numeric(line: String) -> Bool {
  let #(_, rest) = parse_irc_tags(string.trim_end(line))
  let rest = strip_server_prefix(rest)
  case string.split(rest, " ") {
    ["001", ..] | ["002", ..] | ["003", ..] | ["004", ..] -> True
    _ -> False
  }
}

/// Format an IRC status line for the System buffer (numerics, ERROR, FAIL).
///
/// Returns `None` for protocol noise (NAMES, CAP, PING, chat already handled
/// elsewhere) so the System tab stays readable while still showing command
/// errors and WHOIS replies.
pub fn parse_system_status_line(line: String) -> Option(String) {
  let line = string.trim_end(line)
  let #(_tags, rest) = parse_irc_tags(line)
  let rest = string.trim(rest)
  case rest {
    "" -> None
    _ -> {
      // Unprefixed ERROR / FAIL / PONG noise.
      case string.split(rest, " ") {
        ["PING", ..] | ["PONG", ..] -> None
        ["ERROR", ..parts] ->
          Some(
            "ERROR "
            <> parts
            |> string.join(" ")
            |> drop_leading_colon,
          )
        ["FAIL", cmd, code, ..parts] -> {
          let detail =
            parts
            |> string.join(" ")
            |> drop_leading_colon
          Some("FAIL " <> cmd <> " " <> code <> case detail {
            "" -> ""
            d -> " " <> d
          })
        }
        ["FAIL", ..parts] ->
          Some("FAIL " <> string.join(parts, " ") |> drop_leading_colon)
        _ -> parse_system_status_prefixed(rest)
      }
    }
  }
}

fn parse_system_status_prefixed(rest: String) -> Option(String) {
  case string.starts_with(rest, ":") {
    False -> None
    True -> {
      let body = string.drop_start(rest, 1)
      case string.split_once(body, " ") {
        Error(_) -> None
        Ok(#(prefix, cmd_and_args)) -> {
          let server = case string.split_once(prefix, "!") {
            Ok(#(n, _)) -> n
            Error(_) -> prefix
          }
          let parts = string.split(cmd_and_args, " ")
          case parts {
            ["ERROR", ..text] ->
              Some(
                "ERROR "
                <> text
                |> string.join(" ")
                |> drop_leading_colon,
              )
            ["FAIL", cmd, code, ..rest_parts] -> {
              let detail =
                rest_parts
                |> string.join(" ")
                |> drop_leading_colon
              Some("FAIL " <> cmd <> " " <> code <> case detail {
                "" -> ""
                d -> " " <> d
              })
            }
            [numeric, ..params] ->
              case is_irc_numeric(numeric) {
                False -> None
                True ->
                  case is_noise_numeric(numeric) {
                    True -> None
                    False ->
                      Some(format_system_numeric(server, numeric, params))
                  }
              }
            _ -> None
          }
        }
      }
    }
  }
}

fn is_irc_numeric(token: String) -> Bool {
  case string.to_utf_codepoints(token) {
    [a, b, c] ->
      is_digit_cp(a) && is_digit_cp(b) && is_digit_cp(c)
    _ -> False
  }
}

fn is_digit_cp(cp: UtfCodepoint) -> Bool {
  let n = string.utf_codepoint_to_int(cp)
  n >= 48 && n <= 57
}

/// Numerics already handled elsewhere or pure protocol noise.
fn is_noise_numeric(n: String) -> Bool {
  case n {
    // NAMES / WHO / LIST framing
    "353" | "366" | "352" | "315" | "321" | "322" | "323"
    // Topic (handled by parse_topic) + channel mode query spam
    | "332" | "333" | "324" | "329"
    // ISUPPORT / myinfo spam
    | "004" | "005"
    // SASL machine-readable (client handles; NOTICEs already surface)
    | "900" | "901" | "902" | "903" | "904" | "905" | "906" | "907" | "908" ->
      True
    _ -> False
  }
}

fn format_system_numeric(
  server: String,
  numeric: String,
  params: List(String),
) -> String {
  // Drop the target nick (params[0]) when present; keep channel + trailing.
  let useful = case params {
    [_me, ..rest] -> rest
    other -> other
  }
  let trailing = case string.split_once(string.join(useful, " "), " :") {
    Ok(#(head, tail)) -> {
      let head = string.trim(head)
      case head {
        "" -> tail
        h -> h <> " — " <> tail
      }
    }
    Error(_) ->
      useful
      |> string.join(" ")
      |> drop_leading_colon
  }
  let body = case string.trim(trailing) {
    "" -> numeric
    t -> numeric <> " " <> t
  }
  case server {
    "" -> body
    s -> s <> " " <> body
  }
}

/// CAP * ACK :caps…
pub fn parse_cap_ack(line: String) -> Option(List(String)) {
  let #(_, rest) = parse_irc_tags(string.trim_end(line))
  let rest = strip_server_prefix(rest)
  case
    string.contains(string.uppercase(rest), "CAP")
    && string.contains(string.uppercase(rest), "ACK")
  {
    False -> None
    True ->
      case string.split_once(rest, ":") {
        Ok(#(_, caps)) ->
          Some(
            string.split(caps, " ")
            |> list.filter(fn(c) { c != "" }),
          )
        Error(_) -> Some([])
      }
  }
}

/// Kind CSS class for message rows (web2/web3 names).
pub fn kind_class(kind: Kind) -> String {
  case kind {
    Msg -> "msg"
    Notice -> "notice"
    Join -> "join"
    Part -> "part"
    Quit -> "part"
    System -> "notice"
  }
}

/// HTML-escape text for safe embedding.
pub fn escape_html(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
}

/// Escape message text and turn http(s) / `at://` URIs into clickable anchors.
///
/// Direct image URLs (file extension, freeq media, bsky CDN) also get an
/// inline preview — freeq-web2 / freeq-web3 parity. Direct video URLs
/// (`.mp4` / `.webm` / `.mov` / `.m4v`, including freeq media) get an
/// inline `<video controls>` player — freeq-app parity.
///
/// AT Protocol URIs (`at://…`) link to the Taproot record explorer at
/// atproto.at (prefix `https://atproto.` → `https://atproto.at://…`).
pub fn linkify_html(text: String) -> String {
  text
  |> escape_html
  |> linkify_escaped
}

/// True when `url` should render as an inline `<video controls>` player.
pub fn is_video_url(url: String) -> Bool {
  has_video_ext(string.lowercase(url))
}

/// True when `url` should render as an inline image preview.
///
/// Video URLs (by extension) are never treated as images, even when they
/// live under `/api/v1/media/`.
pub fn is_image_url(url: String) -> Bool {
  case is_video_url(url) {
    True -> False
    False -> {
      let lower = string.lowercase(url)
      string.contains(lower, "/api/v1/media/")
      || string.contains(lower, "cdn.bsky.app/img/")
      || has_image_ext(lower)
    }
  }
}

fn url_path_only(url: String) -> String {
  let path = case string.split_once(url, "?") {
    Ok(#(p, _)) -> p
    Error(_) -> url
  }
  case string.split_once(path, "#") {
    Ok(#(p, _)) -> p
    Error(_) -> path
  }
}

fn has_image_ext(url: String) -> Bool {
  let path = url_path_only(url)
  string.ends_with(path, ".jpg")
  || string.ends_with(path, ".jpeg")
  || string.ends_with(path, ".png")
  || string.ends_with(path, ".gif")
  || string.ends_with(path, ".webp")
}

fn has_video_ext(url: String) -> Bool {
  let path = url_path_only(url)
  string.ends_with(path, ".mp4")
  || string.ends_with(path, ".webm")
  || string.ends_with(path, ".mov")
  || string.ends_with(path, ".m4v")
}

fn linkify_escaped(escaped: String) -> String {
  linkify_loop(escaped, "")
}

fn linkify_loop(rest: String, acc: String) -> String {
  case next_url_split(rest) {
    None -> acc <> rest
    Some(#(before, scheme, after_scheme)) -> {
      let #(raw_url, after_url) = take_url_body(after_scheme)
      let #(url, trailing) = trim_url_punctuation(raw_url)
      let full = scheme <> url
      let link = case url {
        "" -> scheme <> raw_url
        _ -> link_anchor(full) <> trailing
      }
      linkify_loop(after_url, acc <> before <> link)
    }
  }
}

/// Earliest `http://`, `https://`, or `at://` in `rest` →
/// `#(before, scheme, after)`.
fn next_url_split(rest: String) -> Option(#(String, String, String)) {
  let https = split_scheme(rest, "https://")
  let http = case split_scheme(rest, "http://") {
    // `http://` match may be the start of `https://` (same offset).
    Some(#(pre, after)) ->
      case string.starts_with(after, "s://") {
        True -> None
        False -> Some(#(pre, after))
      }
    None -> None
  }
  let at = split_scheme(rest, "at://")
  earliest_scheme([
    #(https, "https://"),
    #(http, "http://"),
    #(at, "at://"),
  ])
}

fn split_scheme(
  rest: String,
  scheme: String,
) -> Option(#(String, String)) {
  case string.split_once(rest, scheme) {
    Ok(#(pre, after)) -> Some(#(pre, after))
    Error(_) -> None
  }
}

/// Among candidate scheme hits, pick the one with the shortest `before` prefix.
fn earliest_scheme(
  candidates: List(#(Option(#(String, String)), String)),
) -> Option(#(String, String, String)) {
  list.fold(candidates, None, fn(best, candidate) {
    let #(hit, scheme) = candidate
    case hit {
      None -> best
      Some(#(pre, after)) ->
        case best {
          None -> Some(#(pre, scheme, after))
          Some(#(best_pre, _, _)) ->
            case string.length(pre) < string.length(best_pre) {
              True -> Some(#(pre, scheme, after))
              False -> best
            }
        }
    }
  })
}

/// Consume until whitespace or `<` (web2 end-of-URL markers).
fn take_url_body(rest: String) -> #(String, String) {
  take_url_body_loop(rest, "")
}

fn take_url_body_loop(rest: String, acc: String) -> #(String, String) {
  case string.pop_grapheme(rest) {
    Error(Nil) -> #(acc, "")
    Ok(#(g, more)) ->
      case g {
        " " | "\t" | "\n" | "\r" | "<" -> #(acc, rest)
        _ -> take_url_body_loop(more, acc <> g)
      }
  }
}

/// Strip trailing punctuation commonly glued onto URLs (web2 parity).
/// Returns `#(clean_url, trailing_chars_kept_as_text)`.
fn trim_url_punctuation(url: String) -> #(String, String) {
  trim_url_punctuation_loop(url, "")
}

fn trim_url_punctuation_loop(url: String, trailing: String) -> #(String, String) {
  case string.pop_grapheme(string.reverse(url)) {
    Error(Nil) -> #("", trailing)
    Ok(#(last, rev_rest)) ->
      case is_url_trailing_punct(last) {
        True ->
          trim_url_punctuation_loop(string.reverse(rev_rest), last <> trailing)
        False -> #(url, trailing)
      }
  }
}

fn is_url_trailing_punct(g: String) -> Bool {
  case g {
    "." | "," | ")" | "]" | "!" | "?" | ";" | "'" | "\"" -> True
    _ -> False
  }
}

fn link_anchor(url: String) -> String {
  case string.starts_with(url, "at://") {
    // Taproot explorer: prefix `https://atproto.` → `https://atproto.at://…`
    True ->
      anchor_tag("https://atproto." <> url, url, "")
    False ->
      case is_video_url(url) {
        True -> file_video_card(url)
        False ->
          case is_image_url(url) {
            True -> file_image_card(url)
            False -> anchor_tag(url, url, "")
          }
      }
  }
}

/// Direct image URL as an OG-style card (media + title/domain footer).
fn file_image_card(url: String) -> String {
  let #(title, domain) = file_card_meta(url)
  "<a href=\""
  <> url
  <> "\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"link-embed file-embed\">"
  <> "<img class=\"link-embed-img file-embed-img\" src=\""
  <> url
  <> "\" alt=\"\" loading=\"lazy\" referrerpolicy=\"no-referrer\">"
  <> file_card_body(title, domain)
  <> "</a>"
}

/// Direct video URL as an OG-style card. Outer is a `<div>` (not `<a>`) so
/// native video controls stay clickable; footer links to the file.
fn file_video_card(url: String) -> String {
  let #(title, domain) = file_card_meta(url)
  "<div class=\"link-embed file-embed\">"
  <> "<video class=\"link-embed-video\" src=\""
  <> url
  <> "\" controls preload=\"metadata\" playsinline></video>"
  <> "<a href=\""
  <> url
  <> "\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"link-embed-body file-embed-footer\">"
  <> file_card_body_inner(title, domain)
  <> "</a>"
  <> "</div>"
}

fn file_card_body(title: String, domain: String) -> String {
  "<div class=\"link-embed-body\">"
  <> file_card_body_inner(title, domain)
  <> "</div>"
}

fn file_card_body_inner(title: String, domain: String) -> String {
  let title_html = case title {
    "" -> ""
    t -> "<div class=\"link-embed-title\">" <> t <> "</div>"
  }
  let domain_html = case domain {
    "" -> ""
    d -> "<div class=\"link-embed-domain\">" <> d <> "</div>"
  }
  title_html <> domain_html
}

/// `#(filename_or_host, domain)` for the card footer. `url` is already
/// HTML-escaped (linkify runs after escape_html).
fn file_card_meta(url: String) -> #(String, String) {
  let domain = url_host(url)
  let name = url_filename(url)
  let title = case name {
    "" -> domain
    n -> n
  }
  #(title, domain)
}

fn url_host(url: String) -> String {
  let after_scheme = case string.split_once(url, "://") {
    Ok(#(_, rest)) -> rest
    Error(_) -> url
  }
  let host_path = case string.split_once(after_scheme, "/") {
    Ok(#(host, _)) -> host
    Error(_) -> after_scheme
  }
  let host = case string.split_once(host_path, "?") {
    Ok(#(h, _)) -> h
    Error(_) -> host_path
  }
  case string.split_once(host, "#") {
    Ok(#(h, _)) -> h
    Error(_) -> host
  }
}

fn url_filename(url: String) -> String {
  let path = url_path_only(url)
  let after_scheme = case string.split_once(path, "://") {
    Ok(#(_, rest)) -> rest
    Error(_) -> path
  }
  // Drop host, keep path segments.
  let path_only = case string.split_once(after_scheme, "/") {
    Ok(#(_, rest)) -> rest
    Error(_) -> ""
  }
  case path_only {
    "" -> ""
    p -> last_path_segment(p)
  }
}

fn last_path_segment(path: String) -> String {
  case string.split(path, "/") {
    [] -> ""
    segs ->
      case list.last(segs) {
        Ok(s) -> s
        Error(_) -> ""
      }
  }
}

fn anchor_tag(href: String, body: String, extra_attrs: String) -> String {
  "<a href=\""
  <> href
  <> "\" target=\"_blank\" rel=\"noopener noreferrer\""
  <> extra_attrs
  <> ">"
  <> body
  <> "</a>"
}

// ── AV call TAGMSG (control plane) ───────────────────────────────────────────

/// Parsed `+freeq.at/av-state` TAGMSG broadcast (call lifecycle on a channel).
pub type AvState {
  AvState(
    /// Canonical channel name (e.g. `#freeq`).
    channel: String,
    /// Lifecycle token: `started`, `ended`, `joined`, etc.
    state: String,
    /// freeq-server AV session id.
    session_id: String,
    /// Nick or DID of the actor who emitted the event.
    actor: String,
    /// Reported participant count.
    participants: Int,
    /// Per-device instance id of the actor.
    instance: String,
    /// Optional call title.
    title: String,
  )
}

/// Parse an AV state broadcast TAGMSG.
/// Returns `Some(AvState)` when `+freeq.at/av-state` is present.
pub fn parse_av_state_tagmsg(line: String) -> Option(AvState) {
  let #(tags, after) = parse_irc_tags(string.trim_end(line))
  case tag_get(tags, "+freeq.at/av-state") {
    None | Some("") -> None
    Some(state) -> {
      let rest = case string.starts_with(after, ":") {
        True -> string.drop_start(after, 1)
        False -> after
      }
      let parts = string.split(rest, " ")
      // :nick!u@h TAGMSG #channel
      let channel = case parts {
        [_, _, ch, ..] ->
          ch
          |> drop_leading_colon
          |> canonical_channel
        _ -> ""
      }
      let participants = case tag_get(tags, "+freeq.at/av-participants") {
        Some(raw) ->
          case int.parse(raw) {
            Ok(n) -> n
            Error(_) -> 0
          }
        None -> 0
      }
      Some(AvState(
        channel: channel,
        state: state,
        session_id: option.unwrap(tag_get(tags, "+freeq.at/av-id"), ""),
        actor: option.unwrap(tag_get(tags, "+freeq.at/av-actor"), ""),
        participants: participants,
        instance: option.unwrap(tag_get(tags, "+freeq.at/av-instance"), ""),
        title: option.unwrap(tag_get(tags, "+freeq.at/av-title"), ""),
      ))
    }
  }
}

/// Parse a directed `+freeq.at/av-token` TAGMSG for one of `own_nicks`.
/// Returns `Some(#(session_id, token))`.
pub fn parse_av_token_tagmsg(
  line: String,
  own_nicks: List(String),
) -> Option(#(String, String)) {
  let own =
    list.filter(own_nicks, fn(n) { string.trim(n) != "" })
    |> list.map(string.lowercase)
  case own {
    [] -> None
    _ -> {
      let #(tags, after) = parse_irc_tags(string.trim_end(line))
      case tag_get(tags, "+freeq.at/av-token") {
        None | Some("") -> None
        Some(token) -> {
          let rest = case string.starts_with(after, ":") {
            True -> string.drop_start(after, 1)
            False -> after
          }
          let parts = string.split(rest, " ")
          case parts {
            [_, cmd, target, ..] ->
              case string.uppercase(cmd) == "TAGMSG" {
                False -> None
                True -> {
                  let t = string.lowercase(drop_leading_colon(target))
                  case list.contains(own, t) {
                    True ->
                      Some(#(
                        option.unwrap(tag_get(tags, "+freeq.at/av-id"), ""),
                        token,
                      ))
                    False -> None
                  }
                }
              }
            _ -> None
          }
        }
      }
    }
  }
}

/// Client → server: open a new call.
pub fn av_start_line(channel: String, instance: String) -> String {
  let ch = canonical_channel(channel)
  let tags =
    "+freeq.at/av-start=;+freeq.at/av-instance="
    <> escape_tag_value(instance)
  "@" <> tags <> " TAGMSG " <> ch <> "\r\n"
}

/// Client → server: join an existing call.
pub fn av_join_line(
  channel: String,
  session_id: String,
  instance: String,
) -> String {
  let ch = canonical_channel(channel)
  let tags =
    "+freeq.at/av-join=;+freeq.at/av-id="
    <> escape_tag_value(session_id)
    <> ";+freeq.at/av-instance="
    <> escape_tag_value(instance)
  "@" <> tags <> " TAGMSG " <> ch <> "\r\n"
}

/// Client → server: leave a call.
pub fn av_leave_line(
  channel: String,
  session_id: String,
  instance: String,
) -> String {
  let ch = canonical_channel(channel)
  let tags =
    "+freeq.at/av-leave=;+freeq.at/av-id="
    <> escape_tag_value(session_id)
    <> ";+freeq.at/av-instance="
    <> escape_tag_value(instance)
  "@" <> tags <> " TAGMSG " <> ch <> "\r\n"
}
