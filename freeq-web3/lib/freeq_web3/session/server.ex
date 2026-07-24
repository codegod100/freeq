defmodule FreeqWeb3.Session.Server do
  @moduledoc """
  Per-browser-session GenServer.

  Holds:
  - client-authoritative channel list (`channels`)
  - live IRC routing set (`joined`)
  - member maps, nick, WS state
  - outbound line queue (flushed by Upstream once registered)
  - link to the Upstream WS process

  Live updates go out via `FreeqWeb3.Session.broadcast/2` and
  `broadcast_channel/3` (Phoenix.PubSub) — the LiveView equivalent of
  freeq-web2's CableReady morph/append ops.
  """

  use GenServer
  require Logger

  alias FreeqWeb3.Atproto.OAuthSession
  alias FreeqWeb3.Irc.Render
  alias FreeqWeb3.Irc.Upstream
  alias FreeqWeb3.Session
  alias FreeqWeb3.SessionStore

  defstruct [
    :session_id,
    :upstream_pid,
    :current_nick,
    ws_state: :disconnected,
    # :guest | %OAuthSession{}
    auth: :guest,
    api_bearer: nil,
    # :none | :pending | :ok | :failed
    sasl_status: :none,
    channels: MapSet.new(),
    joined: MapSet.new(),
    join_sent: MapSet.new(),
    channel_members: %{},
    nick_to_did: %{},
    outbound: :queue.new(),
    known_nicks: MapSet.new(),
    suppress_history_batches: MapSet.new(),
    last_upstream_error: nil,
    # callers waiting on ensure_authenticated / API-BEARER
    auth_waiters: []
  ]

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {FreeqWeb3.Session.Registry, session_id}}
    )
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    state = %__MODULE__{session_id: session_id, current_nick: guest_nick()}
    state = restore_from_disk(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap = %{
      session_id: state.session_id,
      current_nick: state.current_nick,
      ws_state: state.ws_state,
      channels: MapSet.to_list(state.channels),
      joined: MapSet.to_list(state.joined),
      api_bearer: state.api_bearer,
      sasl_status: state.sasl_status,
      auth: state.auth,
      authenticated?: authenticated?(state),
      has_credentials?: has_credentials?(state),
      auth_handle: auth_handle(state),
      auth_did: auth_did(state),
      auth_nick: auth_nick(state),
      channel_members: state.channel_members,
      last_upstream_error: state.last_upstream_error
    }

    {:reply, snap, state}
  end

  def handle_call({:set_auth, %OAuthSession{} = oauth}, _from, state) do
    nick = OAuthSession.nick(oauth)

    state = %{
      state
      | auth: oauth,
        current_nick: nick || state.current_nick,
        sasl_status: if(state.api_bearer in [nil, ""], do: :pending, else: :ok)
    }

    persist_auth(state)
    Session.broadcast(state.session_id, {:auth_changed, snapshot_auth(state)})
    {:reply, :ok, state}
  end

  def handle_call(:clear_auth, _from, state) do
    SessionStore.remove(state.session_id)

    state = %{
      state
      | auth: :guest,
        api_bearer: nil,
        sasl_status: :none
    }

    state = disconnect_upstream(state, "logout")
    state = start_upstream(state, primary_channel(state))
    Session.broadcast(state.session_id, {:auth_changed, snapshot_auth(state)})
    {:reply, :ok, state}
  end

  def handle_call(:request_reconnect, _from, state) do
    state = disconnect_upstream(state, "reconnect")
    state = start_upstream(state, primary_channel(state))
    {:reply, :ok, state}
  end

  # Re-check disk for OAuth credentials (e.g. after restart, or if OAuth
  # completed under this id while we were still a guest). May reconnect
  # upstream so SASL re-runs with restored credentials.
  def handle_call(:maybe_restore_auth, _from, state) do
    if has_credentials?(state) do
      {:reply, false, state}
    else
      case apply_disk_auth(state) do
        {true, state} ->
          # apply_disk_auth clears api_bearer; if IRC is already up as guest,
          # reconnect so SASL re-runs with restored credentials.
          state =
            if state.ws_state == :ready do
              Logger.info(
                "session #{short(state.session_id)} disk credentials on guest IRC — reconnecting for SASL"
              )

              state
              |> disconnect_upstream("restore-auth")
              |> start_upstream(primary_channel(state))
            else
              state
            end

          Session.broadcast(state.session_id, {:auth_changed, snapshot_auth(state)})
          {:reply, true, state}

        {false, state} ->
          {:reply, false, state}
      end
    end
  end

  def handle_call({:ensure_authenticated, timeout_ms}, from, state) do
    cond do
      not has_credentials?(state) ->
        {:reply, false, state}

      authenticated?(state) ->
        {:reply, true, state}

      true ->
        state = %{state | sasl_status: :pending}

        state =
          cond do
            alive_upstream?(state) and state.ws_state == :ready and
                state.api_bearer in [nil, ""] ->
              # Credentials but no SASL — reconnect to re-run ATPROTO-CHALLENGE.
              state
              |> disconnect_upstream("ensure-auth")
              |> start_upstream(primary_channel(state))

            not alive_upstream?(state) or state.ws_state == :disconnected ->
              start_upstream(state, primary_channel(state))

            true ->
              # In-flight registration / SASL — wait.
              state
          end

        # Reply when API-BEARER arrives or timeout.
        ref = Process.send_after(self(), {:auth_wait_timeout, from}, timeout_ms)
        state = %{state | auth_waiters: [{from, ref} | state.auth_waiters]}
        {:noreply, state}
    end
  end

  def handle_call({:members, channel}, _from, state) do
    ch = Render.canonical_channel(channel)
    members = Map.get(state.channel_members, ch, %{})
    {:reply, members, state}
  end

  def handle_call({:add_channel, channel}, _from, state) do
    ch = Render.canonical_channel(channel)

    state = %{
      state
      | channels: MapSet.put(state.channels, ch),
        joined: MapSet.put(state.joined, ch)
    }

    persist_channels(state)
    {:reply, :ok, state}
  end

  def handle_call({:remove_channel, channel}, _from, state) do
    ch = Render.canonical_channel(channel)

    state = %{
      state
      | channels: MapSet.delete(state.channels, ch),
        joined: MapSet.delete(state.joined, ch),
        channel_members: Map.delete(state.channel_members, ch),
        join_sent: MapSet.delete(state.join_sent, ch)
    }

    persist_channels(state)
    {:reply, :ok, state}
  end

  def handle_call({:join, channel}, _from, state) do
    ch = Render.canonical_channel(channel)

    state = %{
      state
      | channels: MapSet.put(state.channels, ch),
        joined: MapSet.put(state.joined, ch)
    }

    persist_channels(state)
    state = ensure_upstream(state, ch)
    state = maybe_enqueue_join(state, ch)
    Session.broadcast(state.session_id, {:channels_changed, MapSet.to_list(state.channels)})
    {:reply, :ok, state}
  end

  def handle_call({:part, channel}, _from, state) do
    ch = Render.canonical_channel(channel)

    state = %{
      state
      | channels: MapSet.delete(state.channels, ch),
        joined: MapSet.delete(state.joined, ch),
        channel_members: Map.delete(state.channel_members, ch),
        join_sent: MapSet.delete(state.join_sent, ch)
    }

    persist_channels(state)
    state = enqueue(state, "PART #{ch}\r\n")
    Session.broadcast(state.session_id, {:channels_changed, MapSet.to_list(state.channels)})
    {:reply, :ok, state}
  end

  def handle_call({:send_message, target, text, opts}, _from, state) do
    text = String.trim(to_string(text))

    if text == "" do
      {:reply, :ok, state}
    else
      is_dm = Keyword.get(opts, :dm, false)
      reply_to = Keyword.get(opts, :reply_to, "") |> to_string() |> String.trim()
      edit_to = Keyword.get(opts, :edit_to, "") |> to_string() |> String.trim()

      target =
        if is_dm do
          target
        else
          Render.canonical_channel(target)
        end

      state =
        if is_dm do
          ensure_upstream(state, MapSet.to_list(state.channels) |> List.first() || "#freeq")
        else
          state
          |> then(fn s -> %{s | joined: MapSet.put(s.joined, target)} end)
          |> ensure_upstream(target)
          |> maybe_enqueue_join(target)
        end

      line =
        cond do
          String.match?(text, ~r{^/nick\s+\S}) ->
            "NICK #{String.trim(String.slice(text, 6..-1//1))}\r\n"

          String.match?(text, ~r{^/whois\s+\S}) ->
            "WHOIS #{String.trim(String.slice(text, 7..-1//1))}\r\n"

          String.starts_with?(text, "/") ->
            "#{String.slice(text, 1..-1//1)}\r\n"

          edit_to != "" ->
            "@+draft/edit=#{Render.escape_tag_value(edit_to)} PRIVMSG #{target} :#{text}\r\n"

          reply_to != "" ->
            "@+reply=#{Render.escape_tag_value(reply_to)} PRIVMSG #{target} :#{text}\r\n"

          true ->
            "PRIVMSG #{target} :#{text}\r\n"
        end

      {:reply, :ok, enqueue(state, line)}
    end
  end

  def handle_call({:set_topic, channel, topic}, _from, state) do
    ch = Render.canonical_channel(channel)
    state = ensure_upstream(state, ch)
    state = enqueue(state, "TOPIC #{ch} :#{topic}\r\n")
    {:reply, :ok, state}
  end

  def handle_call({:react, channel, msgid, emoji, added?}, _from, state) do
    ch = Render.canonical_channel(channel)
    msgid = msgid |> to_string() |> String.trim()
    emoji = emoji |> to_string() |> String.trim()

    if msgid == "" or emoji == "" do
      {:reply, {:error, :invalid}, state}
    else
      tag = if added?, do: "+react", else: "+freeq.at/unreact"

      line =
        "@#{tag}=#{Render.escape_tag_value(emoji)};+reply=#{Render.escape_tag_value(msgid)} TAGMSG #{ch}\r\n"

      state =
        state
        |> then(fn s -> %{s | joined: MapSet.put(s.joined, ch)} end)
        |> ensure_upstream(ch)
        |> maybe_enqueue_join(ch)
        |> enqueue(line)

      nick =
        cond do
          is_binary(state.current_nick) and state.current_nick != "" -> state.current_nick
          true -> auth_nick(state) || "me"
        end

      # Optimistic local fan-out (mirrors freeq-web2 enqueue_reaction).
      Session.broadcast_channel(state.session_id, ch, {:reaction, msgid, emoji, nick, added?})

      {:reply, {:ok, nick}, state}
    end
  end

  def handle_call({:av_start, channel, instance, opts}, _from, state) do
    ch = Render.canonical_channel(channel)
    title = Keyword.get(opts, :title, "")
    tags = "+freeq.at/av-start=;+freeq.at/av-instance=#{Render.escape_tag_value(instance)}"

    tags =
      if title != "",
        do: "#{tags};+freeq.at/av-title=#{Render.escape_tag_value(title)}",
        else: tags

    state = ensure_upstream(state, ch)
    state = maybe_enqueue_join(state, ch)
    state = enqueue(state, "@#{tags} TAGMSG #{ch}\r\n")
    {:reply, :ok, state}
  end

  def handle_call({:av_join, channel, session_id_av, instance}, _from, state) do
    ch = Render.canonical_channel(channel)

    tags =
      "+freeq.at/av-join=;+freeq.at/av-id=#{Render.escape_tag_value(session_id_av)};+freeq.at/av-instance=#{Render.escape_tag_value(instance)}"

    state = ensure_upstream(state, ch)
    state = maybe_enqueue_join(state, ch)
    state = enqueue(state, "@#{tags} TAGMSG #{ch}\r\n")
    {:reply, :ok, state}
  end

  def handle_call({:av_leave, channel, session_id_av, instance}, _from, state) do
    ch = Render.canonical_channel(channel)

    tags =
      "+freeq.at/av-leave=;+freeq.at/av-id=#{Render.escape_tag_value(session_id_av)};+freeq.at/av-instance=#{Render.escape_tag_value(instance)}"

    state = ensure_upstream(state, ch)
    state = enqueue(state, "@#{tags} TAGMSG #{ch}\r\n")
    {:reply, :ok, state}
  end

  def handle_call({:av_end, channel, session_id_av}, _from, state) do
    ch = Render.canonical_channel(channel)
    tags = "+freeq.at/av-end=;+freeq.at/av-id=#{Render.escape_tag_value(session_id_av)}"
    state = ensure_upstream(state, ch)
    state = enqueue(state, "@#{tags} TAGMSG #{ch}\r\n")
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:enqueue, line}, state) do
    {:noreply, enqueue(state, line)}
  end

  def handle_cast({:ensure_upstream, channel}, state) do
    ch = Render.canonical_channel(channel)
    state = %{state | joined: MapSet.put(state.joined, ch)}
    state = ensure_upstream(state, ch)
    state = maybe_enqueue_join(state, ch)
    {:noreply, state}
  end

  @impl true
  def handle_info({:upstream_line, line}, state) do
    {:noreply, handle_line(state, line)}
  end

  def handle_info({:upstream_state, ws_state}, state) do
    state = %{state | ws_state: ws_state}
    Session.broadcast(state.session_id, {:ws_state, ws_state, state.current_nick})
    {:noreply, state}
  end

  def handle_info({:upstream_down, reason}, state) do
    Logger.info("session #{short(state.session_id)} upstream down: #{inspect(reason)}")

    state = %{
      state
      | upstream_pid: nil,
        ws_state: :disconnected,
        join_sent: MapSet.new(),
        last_upstream_error: inspect(reason)
    }

    Session.broadcast(state.session_id, {:ws_state, :disconnected, state.current_nick})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{upstream_pid: pid} = state) do
    Logger.info("session #{short(state.session_id)} upstream EXIT: #{inspect(reason)}")

    state = %{
      state
      | upstream_pid: nil,
        ws_state: :disconnected,
        join_sent: MapSet.new(),
        last_upstream_error: inspect(reason)
    }

    Session.broadcast(state.session_id, {:ws_state, :disconnected, state.current_nick})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:upstream_ready, nick}, state) do
    state = %{state | ws_state: :ready, current_nick: nick || state.current_nick}
    Session.broadcast(state.session_id, {:ws_state, :ready, state.current_nick})
    # Drain any queued outbound lines.
    state = flush_outbound(state)
    {:noreply, state}
  end

  def handle_info({:upstream_api_bearer, bearer}, state) when is_binary(bearer) do
    state = %{
      state
      | api_bearer: bearer,
        sasl_status: if(has_credentials?(state), do: :ok, else: state.sasl_status)
    }

    Logger.info(
      "session #{short(state.session_id)} API-BEARER sasl=#{state.sasl_status} " <>
        "handle=#{auth_handle(state) || "-"}"
    )

    Session.broadcast(state.session_id, {:auth_changed, snapshot_auth(state)})
    state = reply_auth_waiters(state, authenticated?(state))
    {:noreply, state}
  end

  def handle_info({:upstream_sasl, status}, state)
      when status in [:pending, :ok, :failed, :none] do
    state = %{state | sasl_status: status}

    state =
      if status == :failed do
        %{state | api_bearer: nil}
      else
        state
      end

    Session.broadcast(state.session_id, {:auth_changed, snapshot_auth(state)})

    state =
      if status == :failed do
        reply_auth_waiters(state, false)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:upstream_auth_updated, %OAuthSession{} = oauth}, state) do
    # Token refresh / DPoP nonce update — keep disk credentials current so
    # SASL still works after process restart.
    state = %{state | auth: oauth}
    persist_auth(state)
    {:noreply, state}
  end

  def handle_info({:auth_wait_timeout, from}, state) do
    waiters =
      Enum.reject(state.auth_waiters, fn {f, ref} ->
        if f == from do
          Process.cancel_timer(ref)
          GenServer.reply(from, authenticated?(state))
          true
        else
          false
        end
      end)

    {:noreply, %{state | auth_waiters: waiters}}
  end

  def handle_info({:FLUSH_OUTBOUND}, state) do
    {:noreply, flush_outbound(state)}
  end

  def handle_info(msg, state) do
    Logger.debug("session #{short(state.session_id)} ignored: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Internals ──────────────────────────────────────────────────────────

  defp restore_from_disk(state) do
    state =
      case apply_disk_auth(state) do
        {true, s} -> s
        {false, s} -> s
      end

    restore_disk_channels(state)
  end

  # Returns `{restored?, state}`.
  defp apply_disk_auth(state) do
    if has_credentials?(state) do
      {false, state}
    else
      case SessionStore.load(state.session_id) do
        %OAuthSession{} = oauth ->
          nick = OAuthSession.nick(oauth)

          state = %{
            state
            | auth: oauth,
              current_nick: nick || state.current_nick,
              # Credentials restored — app identity still needs SASL.
              sasl_status: :pending,
              api_bearer: nil
          }

          Logger.info(
            "session #{short(state.session_id)} restored OAuth from disk did=#{oauth.did}"
          )

          {true, state}

        _ ->
          {false, state}
      end
    end
  rescue
    e ->
      Logger.warning(
        "session #{short(state.session_id)} restore_auth failed: #{Exception.message(e)}"
      )

      {false, state}
  end

  defp restore_disk_channels(state) do
    channels =
      state.session_id
      |> SessionStore.load_channels()
      |> Enum.map(&Render.canonical_channel/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    if channels == [] do
      state
    else
      set = MapSet.new(channels)

      Logger.info(
        "session #{short(state.session_id)} restored #{MapSet.size(set)} channel(s) from disk"
      )

      %{state | channels: set, joined: MapSet.union(state.joined, set)}
    end
  rescue
    e ->
      Logger.warning(
        "session #{short(state.session_id)} restore_channels failed: #{Exception.message(e)}"
      )

      state
  end

  defp persist_auth(%{auth: %OAuthSession{} = oauth, session_id: sid}) do
    SessionStore.save(sid, oauth)
  end

  defp persist_auth(_), do: :ok

  defp persist_channels(state) do
    SessionStore.save_channels(state.session_id, MapSet.to_list(state.channels))
  end

  defp authenticated?(state) do
    has_credentials?(state) and state.api_bearer not in [nil, ""] and state.sasl_status == :ok
  end

  defp has_credentials?(%{auth: %OAuthSession{}}), do: true
  defp has_credentials?(_), do: false

  defp auth_handle(%{auth: %OAuthSession{handle: h}}), do: h
  defp auth_handle(_), do: nil

  defp auth_did(%{auth: %OAuthSession{did: d}}), do: d
  defp auth_did(_), do: nil

  defp auth_nick(%{auth: %OAuthSession{} = o}), do: OAuthSession.nick(o)
  defp auth_nick(_), do: nil

  defp snapshot_auth(state) do
    %{
      authenticated?: authenticated?(state),
      has_credentials?: has_credentials?(state),
      auth_handle: auth_handle(state),
      auth_did: auth_did(state),
      auth_nick: auth_nick(state),
      current_nick: state.current_nick,
      sasl_status: state.sasl_status,
      api_bearer: state.api_bearer
    }
  end

  defp reply_auth_waiters(state, result) do
    Enum.each(state.auth_waiters, fn {from, ref} ->
      Process.cancel_timer(ref)
      GenServer.reply(from, result)
    end)

    %{state | auth_waiters: []}
  end

  defp primary_channel(state) do
    case MapSet.to_list(state.channels) do
      [ch | _] -> ch
      [] -> "#freeq"
    end
  end

  defp alive_upstream?(%{upstream_pid: pid}) when is_pid(pid), do: Process.alive?(pid)
  defp alive_upstream?(_), do: false

  defp disconnect_upstream(state, reason) do
    if alive_upstream?(state) do
      if state.ws_state == :ready do
        send(state.upstream_pid, {:send_line, "QUIT :#{reason}\r\n"})
        # Brief grace so freeq-server can release the nick.
        Process.sleep(150)
      end

      Process.exit(state.upstream_pid, :kill)
    end

    %{
      state
      | upstream_pid: nil,
        ws_state: :disconnected,
        join_sent: MapSet.new(),
        api_bearer: nil,
        sasl_status: if(has_credentials?(state), do: :pending, else: :none)
    }
  end

  defp ensure_upstream(%{upstream_pid: pid} = state, primary) when is_pid(pid) do
    if Process.alive?(pid) do
      state
    else
      start_upstream(%{state | upstream_pid: nil, join_sent: MapSet.new()}, primary)
    end
  end

  defp ensure_upstream(state, primary) do
    start_upstream(state, primary)
  end

  defp start_upstream(state, primary) do
    primary = Render.canonical_channel(primary)
    extras = MapSet.to_list(state.channels) -- [primary]

    nick =
      case state.auth do
        %OAuthSession{} = oauth -> OAuthSession.nick(oauth)
        _ -> state.current_nick || guest_nick()
      end

    case Upstream.start_link(
           session_pid: self(),
           session_id: state.session_id,
           primary: primary,
           nick: nick,
           extras: extras,
           auth: state.auth
         ) do
      {:ok, pid} ->
        Process.monitor(pid)

        state = %{
          state
          | upstream_pid: pid,
            current_nick: nick,
            ws_state: :connecting,
            join_sent: MapSet.put(MapSet.new([primary | extras]), primary),
            joined: Enum.reduce([primary | extras], state.joined, &MapSet.put(&2, &1)),
            sasl_status: if(has_credentials?(state), do: :pending, else: state.sasl_status)
        }

        Session.broadcast(state.session_id, {:ws_state, :connecting, state.current_nick})
        state

      {:error, reason} ->
        Logger.warning("upstream start failed: #{inspect(reason)}")
        %{state | last_upstream_error: inspect(reason), ws_state: :disconnected}
    end
  end

  defp maybe_enqueue_join(state, channel) do
    ch = Render.canonical_channel(channel)

    cond do
      MapSet.member?(state.join_sent, ch) ->
        state

      state.ws_state == :ready ->
        state
        |> Map.update!(:join_sent, &MapSet.put(&1, ch))
        |> enqueue("JOIN #{ch}\r\n")

      true ->
        # Will be JOINed on registration (primary) or re-asserted later.
        %{state | join_sent: MapSet.put(state.join_sent, ch)}
    end
  end

  defp enqueue(state, line) do
    state = %{state | outbound: :queue.in(line, state.outbound)}
    flush_outbound(state)
  end

  defp flush_outbound(%{upstream_pid: pid, ws_state: :ready} = state) when is_pid(pid) do
    drain_queue(state, pid)
  end

  defp flush_outbound(state), do: state

  defp drain_queue(state, pid) do
    case :queue.out(state.outbound) do
      {{:value, line}, rest} ->
        send(pid, {:send_line, line})
        drain_queue(%{state | outbound: rest}, pid)

      {:empty, _} ->
        state
    end
  end

  defp handle_line(state, line) do
    line = String.trim_trailing(line, "\r")

    # Forced nick rename notice.
    state =
      case Render.parse_forced_nick_rename(line) do
        nil ->
          state

        nick ->
          state = %{state | current_nick: nick, known_nicks: MapSet.put(state.known_nicks, nick)}
          Session.broadcast(state.session_id, {:nick, nick})
          state
      end

    # BATCH tracking (suppress JOIN chathistory when REST already filled pane).
    state =
      case Render.parse_batch_line(line) do
        {id, true, type, _ch} ->
          if type && String.downcase(to_string(type)) == "chathistory" do
            %{state | suppress_history_batches: MapSet.put(state.suppress_history_batches, id)}
          else
            state
          end

        {id, false, _, _} ->
          %{state | suppress_history_batches: MapSet.delete(state.suppress_history_batches, id)}

        nil ->
          state
      end

    {tags, _} = Render.parse_irc_tags(line)
    bid = tags["batch"] || ""

    in_history_batch =
      cond do
        bid == "" -> MapSet.size(state.suppress_history_batches) > 0
        MapSet.member?(state.suppress_history_batches, bid) -> true
        String.starts_with?(bid, "hist") -> true
        true -> false
      end

    # Reactions.
    state =
      case Render.parse_tagmsg_reaction(line) do
        {msgid, emoji, nick, added, ch} ->
          Session.broadcast_channel(state.session_id, ch, {:reaction, msgid, emoji, nick, added})
          state

        nil ->
          state
      end

    # AV call state / token.
    # Broadcast on the session topic (not channel) so LiveView still receives
    # call updates after the user patches to another text channel.
    state =
      case Render.parse_av_state_tagmsg(line) do
        {ch, av_state, session_id_av, actor, participants, instance, title} ->
          Session.broadcast(
            state.session_id,
            {:av_state,
             %{
               channel: ch,
               state: av_state,
               session_id: session_id_av,
               actor: actor,
               participants: participants,
               instance: instance,
               title: title
             }}
          )

          state

        nil ->
          state
      end

    state =
      case Render.parse_av_token_tagmsg(line, av_token_nicks(state)) do
        {session_id_av, token} ->
          Logger.info(
            "session #{short(state.session_id)} AV token TAGMSG for sid=#{session_id_av}"
          )

          Session.broadcast(
            state.session_id,
            {:av_token, %{session_id: session_id_av, token: token}}
          )

          state

        nil ->
          # Debug missed tokens (nick mismatch is the usual cause).
          if String.contains?(line, "av-token") do
            Logger.debug(
              "session #{short(state.session_id)} ignored av-token line " <>
                "nick=#{state.current_nick} line=#{String.slice(line, 0, 160)}"
            )
          end

          state
      end

    # NAMES roster.
    state =
      if Render.is_353?(line) do
        ch = Render.channel_from_353(line)

        if ch do
          ch = Render.canonical_channel(ch)
          members = Render.parse_353_members(line)
          map = Map.new(members, fn m -> {m.nick, m} end)
          # Merge into existing (353 can be multi-line).
          existing = Map.get(state.channel_members, ch, %{})
          merged = Map.merge(existing, map)
          state = %{state | channel_members: Map.put(state.channel_members, ch, merged)}
          Session.broadcast_channel(state.session_id, ch, {:members, merged})
          state
        else
          state
        end
      else
        state
      end

    # Member join/part/quit/mode.
    state =
      case Render.parse_member_change(line) do
        nil ->
          state

        change ->
          apply_member_change(state, change)
      end

    # Topic.
    for ch <- state.joined do
      if topic = Render.parse_topic_change(line, ch) do
        Session.broadcast_channel(state.session_id, ch, {:topic, topic})
      end

      if err = Render.parse_channel_error(line, ch) do
        row = %{
          id: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false),
          kind: :notice,
          nick: nil,
          text: err,
          time: DateTime.utc_now(),
          msgid: nil,
          tags: %{},
          own: false
        }

        Session.broadcast_channel(state.session_id, ch, {:message, row})
      end
    end

    # Message pane rows.
    unless in_history_batch do
      for ch <- state.joined do
        if Render.should_emit?(line, ch) do
          row = Render.parse_message_line(line, own_nick: state.current_nick)

          if row do
            Session.broadcast_channel(state.session_id, ch, {:message, row})
          end
        end
      end
    end

    state
  end

  defp apply_member_change(state, %{kind: :join, channel: ch, nick: nick} = change) do
    ch = Render.canonical_channel(ch)
    entry = %{nick: nick, op: false, halfop: false, voiced: false, account: change[:account]}
    map = Map.get(state.channel_members, ch, %{}) |> Map.put(nick, entry)
    state = %{state | channel_members: Map.put(state.channel_members, ch, map)}
    Session.broadcast_channel(state.session_id, ch, {:members, map})
    state
  end

  defp apply_member_change(state, %{kind: :part, channel: ch, nick: nick}) do
    ch = Render.canonical_channel(ch)
    map = Map.get(state.channel_members, ch, %{}) |> Map.delete(nick)
    state = %{state | channel_members: Map.put(state.channel_members, ch, map)}
    Session.broadcast_channel(state.session_id, ch, {:members, map})
    state
  end

  defp apply_member_change(state, %{kind: :quit, nick: nick}) do
    members =
      Map.new(state.channel_members, fn {ch, map} ->
        map = Map.delete(map, nick)
        Session.broadcast_channel(state.session_id, ch, {:members, map})
        {ch, map}
      end)

    %{state | channel_members: members}
  end

  defp apply_member_change(state, %{kind: :mode, channel: ch, ops: ops}) do
    ch = Render.canonical_channel(ch)
    map = Map.get(state.channel_members, ch, %{})

    map =
      Enum.reduce(ops, map, fn {mode, adding, target}, map ->
        entry =
          Map.get(map, target, %{
            nick: target,
            op: false,
            halfop: false,
            voiced: false,
            account: nil
          })

        entry =
          case mode do
            "o" -> %{entry | op: adding}
            "h" -> %{entry | halfop: adding}
            "v" -> %{entry | voiced: adding}
            _ -> entry
          end

        Map.put(map, target, entry)
      end)

    state = %{state | channel_members: Map.put(state.channel_members, ch, map)}
    Session.broadcast_channel(state.session_id, ch, {:members, map})
    state
  end

  defp apply_member_change(state, _), do: state

  defp guest_nick do
    "web" <> Integer.to_string(:rand.uniform(90_000) + 10_000)
  end

  defp short(sid), do: String.slice(sid, 0, 8)

  # Nick candidates the server may address +freeq.at/av-token TAGMSG to.
  defp av_token_nicks(state) do
    auth_nick =
      case state.auth do
        %OAuthSession{} = o -> OAuthSession.nick(o)
        _ -> nil
      end

    auth_handle =
      case state.auth do
        %OAuthSession{handle: h} -> h
        _ -> nil
      end

    [state.current_nick, auth_nick, auth_handle]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end
end
