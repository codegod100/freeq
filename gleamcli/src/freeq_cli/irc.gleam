//// IRC message parser and formatter (IRCv3 tags supported).

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A parsed IRC message with optional IRCv3 tags.
pub type Message {
  Message(
    tags: Dict(String, String),
    prefix: Option(String),
    command: String,
    params: List(String),
  )
}

/// Parse a raw IRC line (with or without trailing CRLF).
pub fn parse(line: String) -> Option(Message) {
  let line =
    line
    |> string.trim_end
    |> strip_cr

  case line {
    "" -> None
    _ -> parse_body(line)
  }
}

fn strip_cr(line: String) -> String {
  case string.ends_with(line, "\r") {
    True -> string.drop_end(line, 1)
    False -> line
  }
}

fn parse_body(line: String) -> Option(Message) {
  let #(tags, rest) = case string.starts_with(line, "@") {
    True -> {
      case string.split_once(line, " ") {
        Ok(#(tag_str, after)) -> #(
          parse_tags(string.drop_start(tag_str, 1)),
          after,
        )
        Error(Nil) -> #(dict.new(), "")
      }
    }
    False -> #(dict.new(), line)
  }

  case rest {
    "" -> None
    _ -> {
      let #(prefix, rest) = case string.starts_with(rest, ":") {
        True -> {
          case string.split_once(rest, " ") {
            Ok(#(pfx, after)) -> #(Some(string.drop_start(pfx, 1)), after)
            Error(Nil) -> #(None, "")
          }
        }
        False -> #(None, rest)
      }

      case rest {
        "" -> None
        _ -> {
          case string.split_once(rest, " ") {
            Ok(#(command, params_raw)) ->
              Some(Message(
                tags:,
                prefix:,
                command: string.uppercase(command),
                params: parse_params(params_raw),
              ))
            Error(Nil) ->
              Some(Message(
                tags:,
                prefix:,
                command: string.uppercase(rest),
                params: [],
              ))
          }
        }
      }
    }
  }
}

fn parse_tags(tag_str: String) -> Dict(String, String) {
  tag_str
  |> string.split(";")
  |> list.fold(dict.new(), fn(acc, pair) {
    case string.split_once(pair, "=") {
      Ok(#(k, v)) -> dict.insert(acc, k, unescape_tag_value(v))
      Error(Nil) ->
        case pair {
          "" -> acc
          _ -> dict.insert(acc, pair, "")
        }
    }
  })
}

fn unescape_tag_value(value: String) -> String {
  value
  |> string.replace("\\:", ";")
  |> string.replace("\\s", " ")
  |> string.replace("\\\\", "\\")
  |> string.replace("\\r", "\r")
  |> string.replace("\\n", "\n")
}

fn parse_params(rest: String) -> List(String) {
  parse_params_loop(rest, [])
}

fn parse_params_loop(rest: String, acc: List(String)) -> List(String) {
  case rest {
    "" -> list.reverse(acc)
    _ ->
      case string.starts_with(rest, ":") {
        True -> list.reverse([string.drop_start(rest, 1), ..acc])
        False ->
          case string.split_once(rest, " ") {
            Ok(#(word, after)) -> parse_params_loop(after, [word, ..acc])
            Error(Nil) -> list.reverse([rest, ..acc])
          }
      }
  }
}

/// Format a message for the wire (without trailing CRLF).
pub fn format(msg: Message) -> String {
  let tags_part = case dict.size(msg.tags) {
    0 -> ""
    _ -> {
      let body =
        dict.to_list(msg.tags)
        |> list.map(fn(pair) {
          let #(k, v) = pair
          case v {
            "" -> k
            _ -> k <> "=" <> escape_tag_value(v)
          }
        })
        |> string.join(";")
      "@" <> body <> " "
    }
  }

  let prefix_part = case msg.prefix {
    Some(p) -> ":" <> p <> " "
    None -> ""
  }

  tags_part <> prefix_part <> msg.command <> format_params(msg.params)
}

fn escape_tag_value(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace(";", "\\:")
  |> string.replace(" ", "\\s")
  |> string.replace("\r", "\\r")
  |> string.replace("\n", "\\n")
}

fn format_params(params: List(String)) -> String {
  case params {
    [] -> ""
    [only] ->
      case string.contains(only, " ") || string.starts_with(only, ":") {
        True -> " :" <> only
        False -> " " <> only
      }
    _ -> {
      let assert Ok(last) = list.last(params)
      let middles = list.take(params, list.length(params) - 1)
      let middle_str =
        middles
        |> list.map(fn(p) { " " <> p })
        |> string.concat
      middle_str <> " :" <> last
    }
  }
}

/// Build a simple command line (no tags/prefix).
pub fn command(cmd: String, params: List(String)) -> String {
  format(Message(tags: dict.new(), prefix: None, command: cmd, params: params))
}

/// Nick from a prefix like `nick!user@host`.
pub fn nick_from_prefix(prefix: Option(String)) -> String {
  case prefix {
    None -> ""
    Some(p) ->
      case string.split_once(p, "!") {
        Ok(#(nick, _)) -> nick
        Error(Nil) -> p
      }
  }
}

/// Extract CAP subcommand and capability list from a CAP message.
/// Params look like: `* LS :cap1 cap2` or `nick ACK :cap1 cap2`
pub fn cap_subcmd(msg: Message) -> Option(String) {
  case msg.params {
    [_, sub, ..] -> Some(string.uppercase(sub))
    _ -> None
  }
}

/// Last param of a message (often the text / cap list).
pub fn trailing(msg: Message) -> String {
  case list.last(msg.params) {
    Ok(t) -> t
    Error(Nil) -> ""
  }
}
