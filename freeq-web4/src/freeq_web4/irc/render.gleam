//// Port of freeq-web3 `Irc.Render` / freeq-web2 `IrcRender`.
////
//// Pure functions: channel names, IRC tags, message lines, history rows,
//// nick colours, member lists, topic changes.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
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

/// One rendered message or presence line in the chat stream.
pub type Row {
  Row(
    id: String,
    kind: Kind,
    nick: Option(String),
    text: String,
    msgid: Option(String),
    time_label: String,
    own: Bool,
    color: String,
    parent: Option(String),
    account: Option(String),
    /// emoji → reactor nicks (from `+freeq.at/reactions` or live TAGMSG).
    reactions: Dict(String, List(String)),
  )
}

/// Channel roster entry from 353 / JOIN / MODE (+o/+h/+v).
pub type Member {
  Member(nick: String, op: Bool, halfop: Bool, voice: Bool, color: String)
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

fn time_label_now() -> String {
  // SSR fallback; browser may reformat. Keep short.
  let sec = unix_seconds()
  let mins = { sec % 86_400 } / 60
  let h = mins / 60
  let m = mins % 60
  pad2(h) <> ":" <> pad2(m)
}

fn pad2(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
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
  let edit = tag_get(tags, "+draft/edit")
  let effective_msgid = case edit {
    Some(e) -> Some(e)
    None -> msgid
  }
  let time = case tag_get(tags, "time") {
    Some(iso) -> time_label_from_iso(iso)
    None -> time_label_now()
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
                  own: nick_matches(nick, own_nick),
                  color: color,
                  parent: reply_parent(tags),
                  account: case tag_get(tags, "account") {
                    Some(a) -> Some(a)
                    None -> tag_get(tags, "+account")
                  },
                  reactions: reactions,
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
                own: False,
                color: nick_color_class(nick),
                parent: None,
                account: None,
                reactions: dict.new(),
              ))
            ["PART", ..] ->
              Some(Row(
                id: unique_id(),
                kind: Part,
                nick: Some(nick),
                text: "left",
                msgid: None,
                time_label: time,
                own: False,
                color: nick_color_class(nick),
                parent: None,
                account: None,
                reactions: dict.new(),
              ))
            ["QUIT", ..] ->
              Some(Row(
                id: unique_id(),
                kind: Quit,
                nick: Some(nick),
                text: "quit",
                msgid: None,
                time_label: time,
                own: False,
                color: nick_color_class(nick),
                parent: None,
                account: None,
                reactions: dict.new(),
              ))
            // CAP / numerics / BATCH / MODE / TOPIC / etc. — not chat rows.
            _ -> None
          }
        }
      }
    }
  }
}

/// Best-effort `HH:MM` from IRCv3 `time` tag (`2026-07-24T20:06:25.000Z`).
fn time_label_from_iso(iso: String) -> String {
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
        [h, m, ..] -> h <> ":" <> m
        _ -> time_label_now()
      }
    }
    _ -> time_label_now()
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
/// `reactions` from `+freeq.at/reactions`).
pub fn history_row(
  sender: String,
  text: String,
  msgid: Option(String),
  timestamp_unix: Option(Int),
  parent: Option(String),
  reactions: Dict(String, List(String)),
) -> Row {
  let nick = case string.split_once(sender, "!") {
    Ok(#(n, _)) -> n
    Error(_) -> sender
  }
  let id = option.unwrap(msgid, unique_id())
  let time = case timestamp_unix {
    Some(sec) -> {
      let mins = { sec % 86_400 } / 60
      pad2(mins / 60) <> ":" <> pad2(mins % 60)
    }
    None -> time_label_now()
  }
  Row(
    id: id,
    kind: Msg,
    nick: Some(nick),
    text: text,
    msgid: msgid,
    time_label: time,
    own: False,
    color: nick_color_class(nick),
    parent: parent,
    account: None,
    reactions: reactions,
  )
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

/// Parse channel MODE for privilege changes → `#(channel, ops)`.
pub fn parse_mode_change(line: String) -> Option(#(String, List(ModeOp))) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  case string.starts_with(rest, ":") {
    False -> None
    True -> {
      let body = string.drop_start(rest, 1)
      case string.split_once(body, " ") {
        Error(_) -> None
        Ok(#(_prefix, cmd_args)) ->
          case string.split(cmd_args, " ") {
            ["MODE", chan, modestring, ..args] -> {
              let chan = drop_leading_colon(chan)
              case
                string.starts_with(chan, "#") || string.starts_with(chan, "&")
              {
                True ->
                  Some(#(
                    canonical_channel(chan),
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
            ["JOIN", chan, ..] ->
              Some(#(
                "join",
                nick,
                Some(canonical_channel(drop_leading_colon(chan))),
              ))
            ["PART", chan, ..] ->
              Some(#(
                "part",
                nick,
                Some(canonical_channel(drop_leading_colon(chan))),
              ))
            ["QUIT", ..] -> Some(#("quit", nick, None))
            ["NICK", new_nick, ..] ->
              Some(#("nick", nick, Some(drop_leading_colon(new_nick))))
            _ -> None
          }
        }
      }
    }
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
/// inline preview — freeq-web2 / freeq-web3 parity.
///
/// AT Protocol URIs (`at://…`) link to the Taproot record explorer at
/// atproto.at (prefix `https://atproto.` → `https://atproto.at://…`).
pub fn linkify_html(text: String) -> String {
  text
  |> escape_html
  |> linkify_escaped
}

/// True when `url` should render as an inline image preview.
pub fn is_image_url(url: String) -> Bool {
  let lower = string.lowercase(url)
  string.contains(lower, "/api/v1/media/")
  || string.contains(lower, "cdn.bsky.app/img/")
  || has_image_ext(lower)
}

fn has_image_ext(url: String) -> Bool {
  let path = case string.split_once(url, "?") {
    Ok(#(p, _)) -> p
    Error(_) -> url
  }
  let path = case string.split_once(path, "#") {
    Ok(#(p, _)) -> p
    Error(_) -> path
  }
  string.ends_with(path, ".jpg")
  || string.ends_with(path, ".jpeg")
  || string.ends_with(path, ".png")
  || string.ends_with(path, ".gif")
  || string.ends_with(path, ".webp")
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
      case is_image_url(url) {
        True ->
          anchor_tag(url, url, " class=\"msg-img-url\"")
          <> anchor_tag(
            url,
            "<img src=\""
              <> url
              <> "\" alt=\"\" class=\"msg-img\" loading=\"lazy\" referrerpolicy=\"no-referrer\">",
            " class=\"msg-img-link\"",
          )
        False -> anchor_tag(url, url, "")
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
