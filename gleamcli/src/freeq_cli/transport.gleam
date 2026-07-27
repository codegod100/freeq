//// TCP / TLS transport over neon.

import gleam/bit_array
import gleam/erlang/process.{type Selector}
import gleam/result
import gleam/string
import neon/net
import neon/ssl
import neon/tcp

pub type Transport {
  Tcp(tcp.Tcp)
  Ssl(ssl.Ssl)
}

pub type TransportError {
  Closed
  Timeout
  ConnectFailed(String)
  SendFailed(String)
  ReceiveFailed(String)
  NotStarted(String)
}

pub type PacketMessage {
  Data(BitArray)
  PeerClosed
  SocketError(String)
}

pub type ConnectConfig {
  ConnectConfig(
    host: String,
    port: Int,
    tls: Bool,
    tls_insecure: Bool,
    timeout_ms: Int,
  )
}

/// Open a TCP or TLS connection.
pub fn connect(cfg: ConnectConfig) -> Result(Transport, TransportError) {
  use port <- result.try(
    net.port(cfg.port)
    |> result.replace_error(ConnectFailed("invalid port")),
  )
  use timeout <- result.try(
    net.timeout(cfg.timeout_ms)
    |> result.replace_error(ConnectFailed("invalid timeout")),
  )
  let address = net.hostname(cfg.host)

  case cfg.tls {
    True -> {
      use _ <- result.try(
        ssl.start()
        |> result.map_error(fn(e) {
          NotStarted("ssl: " <> string_inspect(e))
        }),
      )
      let opts =
        ssl.new(address, port)
        |> ssl.timeout(timeout)
      let opts = case cfg.tls_insecure {
        True -> ssl.verify_none(opts)
        False -> ssl.verify_peer(opts)
      }
      case ssl.connect(opts) {
        Ok(sock) -> Ok(Ssl(sock))
        Error(e) -> Error(ConnectFailed("tls: " <> string_inspect(e)))
      }
    }
    False -> {
      case
        tcp.new(address, port)
        |> tcp.timeout(timeout)
        |> tcp.connect
      {
        Ok(sock) -> Ok(Tcp(sock))
        Error(e) -> Error(ConnectFailed("tcp: " <> string_inspect(e)))
      }
    }
  }
}

pub fn send(t: Transport, line: String) -> Result(Nil, TransportError) {
  let payload = bit_array.from_string(line <> "\r\n")
  case t {
    Tcp(sock) ->
      tcp.send(sock, payload)
      |> result.map_error(fn(e) { SendFailed(string_inspect(e)) })
    Ssl(sock) ->
      ssl.send(sock, payload)
      |> result.map_error(fn(e) { SendFailed(string_inspect(e)) })
  }
}

pub fn send_raw(t: Transport, bytes: BitArray) -> Result(Nil, TransportError) {
  case t {
    Tcp(sock) ->
      tcp.send(sock, bytes)
      |> result.map_error(fn(e) { SendFailed(string_inspect(e)) })
    Ssl(sock) ->
      ssl.send(sock, bytes)
      |> result.map_error(fn(e) { SendFailed(string_inspect(e)) })
  }
}

/// Passive receive of whatever data is available (length 0).
pub fn receive(
  t: Transport,
  timeout_ms: Int,
) -> Result(BitArray, TransportError) {
  use timeout <- result.try(
    net.timeout(timeout_ms)
    |> result.replace_error(ReceiveFailed("invalid timeout")),
  )
  case t {
    Tcp(sock) ->
      case tcp.receive(sock, 0, timeout) {
        Ok(data) -> Ok(data)
        Error(tcp.Closed) -> Error(Closed)
        Error(tcp.Timeout) -> Error(Timeout)
        Error(e) -> Error(ReceiveFailed(string_inspect(e)))
      }
    Ssl(sock) ->
      case ssl.receive(sock, 0, timeout) {
        Ok(data) -> Ok(data)
        Error(ssl.Closed) -> Error(Closed)
        Error(ssl.Timeout) -> Error(Timeout)
        Error(e) -> Error(ReceiveFailed(string_inspect(e)))
      }
  }
}

/// Enable active mode so packets arrive as process messages.
pub fn set_active(t: Transport) -> Result(Transport, TransportError) {
  case t {
    Tcp(sock) ->
      tcp.active(sock)
      |> result.map(Tcp)
      |> result.map_error(fn(e) { ReceiveFailed(string_inspect(e)) })
    Ssl(sock) ->
      ssl.active(sock)
      |> result.map(Ssl)
      |> result.map_error(fn(e) { ReceiveFailed(string_inspect(e)) })
  }
}

/// Register selector handlers for active-mode socket messages.
pub fn select(
  selector: Selector(a),
  mapper: fn(PacketMessage) -> a,
) -> Selector(a) {
  // We always attach both TCP and SSL handlers; only the live transport fires.
  selector
  |> tcp.select(fn(msg) {
    mapper(case msg {
      tcp.Packet(_, data) -> Data(data)
      tcp.SocketClosed(_) -> PeerClosed
      tcp.SocketError(_, e) -> SocketError(string_inspect(e))
    })
  })
  |> ssl.select(fn(msg) {
    mapper(case msg {
      ssl.Packet(_, data) -> Data(data)
      ssl.SocketClosed(_) -> PeerClosed
      ssl.SocketError(_, e) -> SocketError(string_inspect(e))
    })
  })
}

pub fn close(t: Transport) -> Nil {
  case t {
    Tcp(sock) -> {
      let _ = tcp.shutdown(sock)
      tcp.close(sock)
    }
    Ssl(sock) -> {
      let _ = ssl.shutdown(sock)
      let _ = ssl.close(sock)
      Nil
    }
  }
}

pub fn error_to_string(e: TransportError) -> String {
  case e {
    Closed -> "connection closed"
    Timeout -> "timeout"
    ConnectFailed(s) -> "connect failed: " <> s
    SendFailed(s) -> "send failed: " <> s
    ReceiveFailed(s) -> "receive failed: " <> s
    NotStarted(s) -> "not started: " <> s
  }
}

fn string_inspect(value: a) -> String {
  string.inspect(value)
}
