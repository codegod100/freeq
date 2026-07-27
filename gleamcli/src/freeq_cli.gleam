//// freeq-cli — terminal IRC client for irc.freeq.at.

import freeq_cli/client
import freeq_cli/config
import gleam/io
import gleam/string

pub fn main() -> Nil {
  case config.parse() {
    Error(help_or_err) -> {
      io.println(help_or_err)
      // clip returns help text for --help; treat unknown flags as failure.
      case string.starts_with(help_or_err, "freeq-cli") {
        True -> halt(0)
        False -> halt(2)
      }
    }
    Ok(cfg) ->
      case client.run(cfg) {
        Ok(Nil) -> halt(0)
        Error(e) -> {
          io.println_error("error: " <> client.error_to_string(e))
          halt(1)
        }
      }
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil
