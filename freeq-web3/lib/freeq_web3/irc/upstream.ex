defmodule FreeqWeb3.Irc.Upstream do
  @moduledoc """
  Upstream IRC WebSocket client (Mint + Mint.WebSocket).

  One process per browser session. Performs guest CAP/NICK/USER registration
  (SASL ATPROTO-CHALLENGE is stubbed for a later OAuth port), JOINs the primary
  channel, then relays lines between freeq-server and the Session GenServer.
  """

  use GenServer
  require Logger

  alias FreeqWeb3.Irc.Render

  defstruct [
    :session_pid,
    :session_id,
    :primary,
    :nick,
    :extras,
    :conn,
    :websocket,
    :request_ref,
    :status,
    :headers,
    reg_phase: :wait_cap_ack,
    ready?: false
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_pid: Keyword.fetch!(opts, :session_pid),
      session_id: Keyword.fetch!(opts, :session_id),
      primary: Render.canonical_channel(Keyword.fetch!(opts, :primary)),
      nick: Keyword.get(opts, :nick) || guest_nick(),
      extras: Keyword.get(opts, :extras, [])
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    url = FreeqWeb3.upstream_ws()
    uri = URI.parse(url)
    scheme = if uri.scheme == "wss", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = uri.path || "/irc"
    path = if uri.query, do: path <> "?" <> uri.query, else: path

    send(state.session_pid, {:upstream_state, :connecting})

    case Mint.HTTP.connect(scheme, uri.host, port,
           protocols: [:http1],
           transport_opts: transport_opts(scheme)
         ) do
      {:ok, conn} ->
        case Mint.WebSocket.upgrade(scheme_ws(scheme), conn, path, []) do
          {:ok, conn, ref} ->
            {:noreply, %{state | conn: conn, request_ref: ref}}

          {:error, conn, reason} ->
            Logger.warning("WS upgrade failed: #{inspect(reason)}")
            send(state.session_pid, {:upstream_down, reason})
            Mint.HTTP.close(conn)
            {:stop, :normal, state}
        end

      {:error, reason} ->
        Logger.warning("WS connect failed: #{inspect(reason)}")
        send(state.session_pid, {:upstream_down, reason})
        {:stop, :normal, state}
    end
  end

  def handle_info({:send_line, line}, %{ready?: true} = state) do
    case send_text(state, line) do
      {:ok, state} ->
        {:noreply, state}

      {:error, state, reason} ->
        send(state.session_pid, {:upstream_down, reason})
        {:stop, :normal, state}
    end
  end

  def handle_info({:send_line, _line}, state) do
    # Not ready yet — Session GenServer re-queues; drop here.
    {:noreply, state}
  end

  def handle_info(message, state) do
    case state.conn do
      nil ->
        {:noreply, state}

      conn ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            {:noreply, state}

          {:ok, conn, responses} ->
            state = %{state | conn: conn}
            {:noreply, Enum.reduce(responses, state, &handle_response/2)}

          {:error, conn, reason, _responses} ->
            Logger.warning("WS stream error: #{inspect(reason)}")
            _ = Mint.HTTP.close(conn)
            send(state.session_pid, {:upstream_down, reason})
            {:stop, :normal, %{state | conn: conn}}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  # ── Response handling ──────────────────────────────────────────────────

  defp handle_response({:status, ref, status}, %{request_ref: ref} = state) do
    %{state | status: status}
  end

  defp handle_response({:headers, ref, headers}, %{request_ref: ref} = state) do
    %{state | headers: headers}
  end

  defp handle_response({:done, ref}, %{request_ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket, reg_phase: :wait_cap_ack}
        send(state.session_pid, {:upstream_state, :registering})

        case send_registration(state) do
          {:ok, state} ->
            state

          {:error, state, reason} ->
            send(state.session_pid, {:upstream_down, reason})
            state
        end

      {:error, conn, reason} ->
        Logger.warning("WS new failed: #{inspect(reason)}")
        send(state.session_pid, {:upstream_down, reason})
        %{state | conn: conn}
    end
  end

  defp handle_response({:data, ref, data}, %{request_ref: ref, websocket: ws} = state)
       when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &handle_frame/2)

      {:error, websocket, reason} ->
        Logger.warning("WS decode error: #{inspect(reason)}")
        send(state.session_pid, {:upstream_down, reason})
        %{state | websocket: websocket}
    end
  end

  defp handle_response({:data, ref, _data}, %{request_ref: ref} = state) do
    # Data before upgrade complete — ignore.
    state
  end

  defp handle_response(_other, state), do: state

  defp handle_frame({:text, text}, state) do
    text
    |> String.split("\n")
    |> Enum.reduce(state, fn raw, st ->
      raw = String.trim_trailing(raw, "\r")
      if raw == "", do: st, else: handle_line(st, raw)
    end)
  end

  defp handle_frame({:ping, data}, state) do
    case encode_and_stream(state, {:pong, data}) do
      {:ok, state} -> state
      {:error, state, _} -> state
    end
  end

  defp handle_frame({:close, _, _}, state) do
    send(state.session_pid, {:upstream_down, :closed})
    state
  end

  defp handle_frame(_frame, state), do: state

  defp handle_line(state, line) do
    # PING keepalive
    case ping_token(line) do
      nil ->
        :ok

      token ->
        _ = send_text(state, "PONG :#{token}\r\n")
    end

    # Registration state machine (guest only for now).
    state =
      case state.reg_phase do
        :wait_cap_ack ->
          cond do
            cap_ack?(line) ->
              case finish_registration(state) do
                {:ok, st} -> st
                {:error, st, _} -> st
              end

            welcome_numeric?(line) ->
              case finish_registration(state) do
                {:ok, st} ->
                  send(st.session_pid, {:upstream_line, line})
                  st

                {:error, st, _} ->
                  st
              end

            true ->
              send(state.session_pid, {:upstream_line, line})
              state
          end

        :ready ->
          # 433 nick in use — pick a new guest nick.
          if String.contains?(line, " 433 ") do
            nick = guest_nick()
            state = %{state | nick: nick}
            _ = send_text(state, "NICK #{nick}\r\n")
            send(state.session_pid, {:upstream_line, line})
            state
          else
            send(state.session_pid, {:upstream_line, line})
            state
          end

        _ ->
          send(state.session_pid, {:upstream_line, line})
          state
      end

    state
  end

  defp send_registration(state) do
    lines = [
      "CAP LS 302\r\n",
      "NICK #{state.nick}\r\n",
      "USER web3 0 * :freeq-web3\r\n",
      "CAP REQ :sasl account-notify extended-join account-tag message-tags batch server-time echo-message draft/chathistory\r\n"
    ]

    Enum.reduce_while(lines, {:ok, state}, fn line, {:ok, st} ->
      case send_text(st, line) do
        {:ok, st} -> {:cont, {:ok, st}}
        err -> {:halt, err}
      end
    end)
  end

  defp finish_registration(state) do
    lines =
      ["CAP END\r\n", "JOIN #{state.primary}\r\n"] ++
        Enum.map(state.extras, fn ch -> "JOIN #{Render.canonical_channel(ch)}\r\n" end)

    result =
      Enum.reduce_while(lines, {:ok, state}, fn line, {:ok, st} ->
        case send_text(st, line) do
          {:ok, st} -> {:cont, {:ok, st}}
          err -> {:halt, err}
        end
      end)

    case result do
      {:ok, state} ->
        state = %{state | reg_phase: :ready, ready?: true}
        send(state.session_pid, {:upstream_ready, state.nick})
        {:ok, state}

      err ->
        err
    end
  end

  defp send_text(state, text) do
    encode_and_stream(state, {:text, text})
  end

  defp encode_and_stream(%{websocket: nil} = state, _frame) do
    {:error, state, :no_websocket}
  end

  defp encode_and_stream(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:error, %{state | conn: conn, websocket: websocket}, reason}
        end

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end

  defp ping_token(line) do
    {_tags, after_line} = Render.parse_irc_tags(line)

    rest =
      if String.starts_with?(after_line, ":"),
        do: String.slice(after_line, 1..-1//1),
        else: after_line

    cond do
      String.starts_with?(rest, "PING ") ->
        rest |> String.slice(5..-1//1) |> String.trim_leading(":")

      String.starts_with?(line, "PING ") ->
        line |> String.slice(5..-1//1) |> String.trim_leading(":")

      true ->
        nil
    end
  end

  defp cap_ack?(line), do: String.contains?(line, " CAP ") and String.contains?(line, " ACK ")
  defp welcome_numeric?(line), do: Regex.match?(~r/ 00[1-4] /, line)

  defp scheme_ws(:https), do: :wss
  defp scheme_ws(:http), do: :ws

  defp transport_opts(:https), do: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
  defp transport_opts(:http), do: []

  defp guest_nick do
    "web" <> Integer.to_string(:rand.uniform(90_000) + 10_000)
  end
end
