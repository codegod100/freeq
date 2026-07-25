//// Port of freeq-web3 `Irc.Render` / freeq-web2 `IrcRender`.
////
//// Pure functions: channel names, IRC tags, message lines, history rows,
//// nick colours, member lists, topic changes.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Structured chat row shown in the message stream.
pub type Kind {
  Msg
  Notice
  Join
  Part
  Quit
  System
}

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
  )
}

pub type Member {
  Member(nick: String, op: Bool, voice: Bool, color: String)
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

fn reply_parent(tags: List(#(String, String))) -> Option(String) {
  case tag_get(tags, "+reply") {
    Some(v) -> Some(v)
    None ->
      case tag_get(tags, "reply") {
        Some(v) -> Some(v)
        None -> tag_get(tags, "draft/reply")
      }
  }
}

/// Parse a PRIVMSG/NOTICE/JOIN/PART/QUIT line into a row.
pub fn parse_message_line(
  line: String,
  own_nick: Option(String),
) -> Option(Row) {
  let line = string.trim_end(line)
  let #(tags, rest) = parse_irc_tags(line)
  let msgid = tag_get(tags, "msgid")
  let edit = tag_get(tags, "+draft/edit")
  let effective_msgid = case edit {
    Some(e) -> Some(e)
    None -> msgid
  }
  let time = time_label_now()

  case string.starts_with(rest, ":") {
    False ->
      Some(Row(
        id: option.unwrap(effective_msgid, unique_id()),
        kind: Notice,
        nick: None,
        text: rest,
        msgid: effective_msgid,
        time_label: time,
        own: False,
        color: "n1",
        parent: reply_parent(tags),
        account: tag_get(tags, "account"),
      ))
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
              ))
            _ ->
              Some(Row(
                id: unique_id(),
                kind: Notice,
                nick: None,
                text: line,
                msgid: None,
                time_label: time,
                own: False,
                color: "n1",
                parent: None,
                account: None,
              ))
          }
        }
      }
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
/// from the REST client (`sender`, `text`, `msgid`, `timestamp`).
pub fn history_row(
  sender: String,
  text: String,
  msgid: Option(String),
  timestamp_unix: Option(Int),
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
    parent: None,
    account: None,
  )
}

/// Parse RPL_NAMREPLY (353) member tokens → members.
pub fn parse_353_members(line: String) -> List(Member) {
  let #(_tags, rest) = parse_irc_tags(string.trim_end(line))
  // :server 353 me = #chan :@op +voice nick
  case string.split(rest, " :") {
    [_, names] ->
      string.split(names, " ")
      |> list.filter(fn(t) { t != "" })
      |> list.map(parse_member_token)
    _ ->
      // try last colon segment
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
  let #(op, voice, nick) = case string.to_graphemes(token) {
    ["@", ..rest] -> #(True, False, string.concat(rest))
    ["+", ..rest] -> #(False, True, string.concat(rest))
    ["%", ..rest] -> #(True, False, string.concat(rest))
    _ -> #(False, False, token)
  }
  Member(nick: nick, op: op, voice: voice, color: nick_color_class(nick))
}

/// Parse JOIN/PART/QUIT for member roster updates.
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
