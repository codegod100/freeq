defmodule FreeqWeb3.Irc.Upstream do
  @moduledoc """
  Upstream IRC WebSocket client (Mint + Mint.WebSocket).

  One process per browser session. Performs CAP/NICK/USER registration,
  optional SASL `ATPROTO-CHALLENGE` when OAuth credentials are present,
  JOINs channels, then relays lines between freeq-server and the Session
  GenServer.
  """

  use GenServer
  require Logger

  alias FreeqWeb3.Atproto.OAuth
  alias FreeqWeb3.Atproto.OAuthSession
  alias FreeqWeb3.Atproto.Sasl
  alias FreeqWeb3.Irc.Render

  defstruct [
    :session_pid,
    :session_id,
    :primary,
    :nick,
    :desired_nick,
    :extras,
    :conn,
    :websocket,
    :request_ref,
    :status,
    :headers,
    # :guest | %OAuthSession{}
    auth: :guest,
    reg_phase: :wait_cap_ack,
    ready?: false,
    nick_collision_tries: 0
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    auth = Keyword.get(opts, :auth, :guest)

    nick =
      case auth do
        %OAuthSession{} = oauth -> OAuthSession.nick(oauth)
        _ -> Keyword.get(opts, :nick) || guest_nick()
      end

    desired =
      case auth do
        %OAuthSession{} = oauth -> OAuthSession.nick(oauth)
        _ -> nil
      end

    state = %__MODULE__{
      session_pid: Keyword.fetch!(opts, :session_pid),
      session_id: Keyword.fetch!(opts, :session_id),
      primary: Render.canonical_channel(Keyword.fetch!(opts, :primary)),
      nick: nick,
      desired_nick: desired,
      extras: Keyword.get(opts, :extras, []),
      auth: auth
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

  def handle_info({:update_auth, auth}, state) do
    {:noreply, %{state | auth: auth}}
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
      nil -> :ok
      token -> _ = send_text(state, "PONG :#{token}\r\n")
    end

    # API-BEARER notice (after successful SASL)
    state =
      case parse_api_bearer_notice(line) do
        nil ->
          state

        bearer ->
          send(state.session_pid, {:upstream_api_bearer, bearer})
          state
      end

    # Registration / SASL state machine
    {state, consumed} = reg_machine(state, line)

    # Nick collision
    state =
      if not consumed and String.contains?(line, " 433 ") do
        handle_433(state, line)
      else
        state
      end

    unless consumed do
      send(state.session_pid, {:upstream_line, line})
    end

    state
  end

  defp reg_machine(%{reg_phase: :wait_cap_ack} = state, line) do
    cond do
      caps = parse_cap_ack(line) ->
        if has_credentials?(state) and Enum.any?(caps, &(String.downcase(&1) == "sasl")) do
          state = refresh_oauth_before_sasl(state)
          send(state.session_pid, {:upstream_sasl, :pending})
          _ = send_text(state, "AUTHENTICATE ATPROTO-CHALLENGE\r\n")
          Logger.info("SASL ATPROTO-CHALLENGE for #{auth_handle(state)}")
          {%{state | reg_phase: :sasl_challenge}, true}
        else
          if has_credentials?(state) do
            send(state.session_pid, {:upstream_sasl, :failed})
          end

          case finish_registration(state, after_sasl: false) do
            {:ok, st} -> {st, true}
            {:error, st, _} -> {st, true}
          end
        end

      welcome_numeric?(line) ->
        if has_credentials?(state) do
          send(state.session_pid, {:upstream_sasl, :failed})
        end

        case finish_registration(state, after_sasl: false) do
          {:ok, st} -> {st, false}
          {:error, st, _} -> {st, false}
        end

      true ->
        {state, false}
    end
  end

  defp reg_machine(%{reg_phase: :sasl_challenge} = state, line) do
    cond do
      nonce = parse_dpop_nonce_notice(line) ->
        state = update_dpop_nonce(state, nonce)
        {state, true}

      challenge_b64 = parse_authenticate_challenge(line) ->
        try do
          challenge = Sasl.parse_challenge(challenge_b64)
          response = Sasl.build_response(challenge.nonce, state.auth)
          _ = send_text(state, "AUTHENTICATE #{response}\r\n")
          Logger.info("SASL challenge response sent for #{auth_handle(state)}")
          {%{state | reg_phase: :sasl_result}, true}
        rescue
          e ->
            Logger.warning("SASL challenge response failed: #{Exception.message(e)}")
            send(state.session_pid, {:upstream_sasl, :failed})

            case finish_registration(state, after_sasl: false) do
              {:ok, st} -> {st, true}
              {:error, st, _} -> {st, true}
            end
        end

      String.contains?(line, " 904 ") ->
        Logger.warning("SASL 904 during challenge: #{String.slice(line, 0, 200)}")
        send(state.session_pid, {:upstream_sasl, :failed})

        case finish_registration(state, after_sasl: false) do
          {:ok, st} -> {st, true}
          {:error, st, _} -> {st, true}
        end

      true ->
        {state, false}
    end
  end

  defp reg_machine(%{reg_phase: :sasl_result} = state, line) do
    cond do
      String.contains?(line, " 903 ") ->
        Logger.info("SASL 903 success for #{auth_handle(state)}")
        send(state.session_pid, {:upstream_sasl, :ok})
        state = reclaim_preferred_nick(state, force: true)

        case finish_registration(state, after_sasl: true) do
          {:ok, st} -> {st, true}
          {:error, st, _} -> {st, true}
        end

      String.contains?(line, " 904 ") ->
        Logger.warning("SASL 904 for #{auth_handle(state)}: #{String.slice(line, 0, 200)}")

        send(state.session_pid, {:upstream_sasl, :failed})

        case finish_registration(state, after_sasl: false) do
          {:ok, st} -> {st, true}
          {:error, st, _} -> {st, true}
        end

      nonce = parse_dpop_nonce_notice(line) ->
        state = update_dpop_nonce(state, nonce)
        {state, true}

      challenge_b64 = parse_authenticate_challenge(line) ->
        # Server re-issues challenge (DPoP retry).
        try do
          challenge = Sasl.parse_challenge(challenge_b64)
          response = Sasl.build_response(challenge.nonce, state.auth)
          _ = send_text(state, "AUTHENTICATE #{response}\r\n")
          {state, true}
        rescue
          e ->
            Logger.warning("SASL retry failed: #{Exception.message(e)}")
            send(state.session_pid, {:upstream_sasl, :failed})

            case finish_registration(state, after_sasl: false) do
              {:ok, st} -> {st, true}
              {:error, st, _} -> {st, true}
            end
        end

      true ->
        {state, false}
    end
  end

  defp reg_machine(state, _line), do: {state, false}

  defp handle_433(state, _line) do
    if has_credentials?(state) and state.desired_nick not in [nil, ""] do
      if state.ready? or state.reg_phase in [:ready, :sasl_result] do
        reclaim_preferred_nick(state, force: true)
      else
        tries = state.nick_collision_tries + 1
        base = state.desired_nick
        new_nick = base <> String.duplicate("_", min(tries, 3))
        state = %{state | nick: new_nick, nick_collision_tries: tries}
        _ = send_text(state, "NICK #{new_nick}\r\n")
        send(state.session_pid, {:upstream_line, "NICK collision — trying #{new_nick}"})
        state
      end
    else
      nick = guest_nick()
      state = %{state | nick: nick}
      _ = send_text(state, "NICK #{nick}\r\n")
      state
    end
  end

  defp send_registration(state) do
    if has_credentials?(state) do
      send(state.session_pid, {:upstream_sasl, :pending})
    end

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

  defp finish_registration(state, opts) do
    after_sasl = Keyword.get(opts, :after_sasl, false)

    join_lines =
      if after_sasl do
        # Re-JOIN primary + extras (guest-time 477 may have blocked).
        channels =
          [state.primary | state.extras]
          |> Enum.map(&Render.canonical_channel/1)
          |> Enum.uniq()

        Enum.map(channels, fn ch -> "JOIN #{ch}\r\n" end)
      else
        ["JOIN #{state.primary}\r\n"] ++
          Enum.map(state.extras, fn ch -> "JOIN #{Render.canonical_channel(ch)}\r\n" end)
      end

    lines = ["CAP END\r\n" | join_lines]

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

  defp refresh_oauth_before_sasl(%{auth: %OAuthSession{} = oauth} = state) do
    case OAuth.refresh(oauth) do
      {:ok, new_oauth} ->
        Logger.info("OAuth access token refreshed for #{new_oauth.handle}")
        send(state.session_pid, {:upstream_auth_updated, new_oauth})
        %{state | auth: new_oauth}

      {:error, :missing_refresh} ->
        state

      {:error, reason} ->
        Logger.warning(
          "OAuth refresh failed for #{oauth.handle}: #{inspect(reason)} — SASL may fail"
        )

        state
    end
  rescue
    e ->
      Logger.warning("OAuth refresh error: #{Exception.message(e)}")
      state
  end

  defp refresh_oauth_before_sasl(state), do: state

  defp update_dpop_nonce(%{auth: %OAuthSession{} = oauth} = state, nonce) do
    oauth = %{oauth | dpop_nonce: nonce}
    send(state.session_pid, {:upstream_auth_updated, oauth})
    %{state | auth: oauth}
  end

  defp update_dpop_nonce(state, _), do: state

  defp reclaim_preferred_nick(state, opts) do
    force = Keyword.get(opts, :force, false)
    desired = state.desired_nick || auth_nick(state)

    if desired in [nil, ""] do
      state
    else
      same = String.downcase(to_string(state.nick)) == String.downcase(desired)
      temp = temporary_nick?(state.nick)

      if force or not same or temp do
        _ = send_text(state, "NICK #{desired}\r\n")
        if temp or state.nick in [nil, ""], do: %{state | nick: desired}, else: state
      else
        state
      end
    end
  end

  defp temporary_nick?(nick) do
    n = to_string(nick || "")

    n == "" or String.ends_with?(n, "_") or
      Regex.match?(~r/\AGuest\d+\z/i, n) or
      Regex.match?(~r/\Aweb[0-9a-fA-F]+\z/i, n)
  end

  defp has_credentials?(%{auth: %OAuthSession{}}), do: true
  defp has_credentials?(_), do: false

  defp auth_handle(%{auth: %OAuthSession{handle: h}}), do: h
  defp auth_handle(_), do: nil

  defp auth_nick(%{auth: %OAuthSession{} = o}), do: OAuthSession.nick(o)
  defp auth_nick(_), do: nil

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

  defp parse_cap_ack(line) do
    payload = irc_command_payload(line)
    parts = String.split(payload)

    if length(parts) >= 3 and String.downcase(Enum.at(parts, 0)) == "cap" do
      ack_i = Enum.find_index(parts, fn p -> String.downcase(p) == "ack" end)

      if ack_i do
        parts
        |> Enum.drop(ack_i + 1)
        |> Enum.map(&String.trim_leading(&1, ":"))
      end
    end
  end

  defp parse_authenticate_challenge(line) do
    payload = irc_command_payload(line)

    if String.starts_with?(payload, "AUTHENTICATE ") do
      challenge = payload |> String.replace_prefix("AUTHENTICATE ", "") |> String.trim()

      if challenge != "" and challenge != "+" do
        challenge
      end
    end
  end

  defp parse_dpop_nonce_notice(line) do
    if String.contains?(line, "NOTICE") and String.contains?(line, "DPOP_NONCE") do
      case Regex.run(~r/DPOP_NONCE\s+(\S+)/, line) do
        [_, nonce] -> nonce
        _ -> nil
      end
    end
  end

  defp parse_api_bearer_notice(line) do
    if String.contains?(line, "NOTICE") and String.contains?(line, "API-BEARER") do
      case Regex.run(~r/API-BEARER\s+(\S+)/, line) do
        [_, bearer] -> bearer
        _ -> nil
      end
    end
  end

  defp irc_command_payload(line) do
    line =
      line
      |> String.trim_trailing("\r")
      |> String.replace(~r/\A@\S+\s+/, "")
      |> String.replace(~r/\A:[^\s]+\s+/, "")

    line
  end

  defp welcome_numeric?(line), do: Regex.match?(~r/ 00[1-4] /, line)

  defp scheme_ws(:https), do: :wss
  defp scheme_ws(:http), do: :ws

  defp transport_opts(:https), do: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
  defp transport_opts(:http), do: []

  defp guest_nick do
    "web" <> Integer.to_string(:rand.uniform(90_000) + 10_000)
  end
end
