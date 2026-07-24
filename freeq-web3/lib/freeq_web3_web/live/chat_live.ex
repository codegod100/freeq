defmodule FreeqWeb3Web.ChatLive do
  @moduledoc """
  Chat shell: channel list (`/chat`) and per-channel pane (`/chat/:channel`).

  Both routes share this LiveView so an active AV call (AvCall hook) is not
  destroyed when browsing "All channels".
  """
  use FreeqWeb3Web, :live_view

  alias FreeqWeb3.Irc.Render
  alias FreeqWeb3.LinkPreview
  alias FreeqWeb3.Rest
  alias FreeqWeb3.Session

  @impl true
  def mount(_params, _session, socket) do
    sid = socket.assigns.freeq_session

    if connected?(socket) do
      Session.subscribe(sid)
    end

    snap = Session.snapshot(sid)
    all = Rest.fetch_channels()
    my = my_channel_entries(snap.channels, all)

    socket =
      socket
      |> assign(:view, :index)
      |> assign(:page_title, "channels")
      |> assign(:channel, nil)
      |> assign(:bare, "")
      |> assign(:snap, snap)
      |> assign(:topic, "")
      |> assign(:editing_topic, false)
      |> assign(:all_channels, all)
      |> assign(:my_channels, my)
      |> assign(:members, %{})
      |> assign(:compose, "")
      |> assign(:reply_to, nil)
      |> assign(:edit_to, nil)
      |> assign(:reply_preview_nick, nil)
      |> assign(:reply_preview_text, nil)
      |> assign(:parent_lookup, %{})
      |> assign(:rows_by_msgid, %{})
      |> assign(:react_picker_msgid, nil)
      |> assign(:av_active, false)
      |> assign(:av_call_present, false)
      |> assign(:av_session_id, nil)
      |> assign(:av_channel, nil)
      |> assign(:av_participant_count, 0)
      |> assign(:av_muted, false)
      |> assign(:av_camera, false)
      |> assign(:av_instance, generate_av_instance())
      |> stream(:messages, [], reset: true)
      |> assign(:message_count, 0)

    if connected?(socket) do
      send(self(), :poll_channel_call)
      # Keep discovering live calls while the page is open.
      :timer.send_interval(4_000, self(), :poll_channel_call)
    end

    # handle_params loads :index or :channel after mount.
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"channel" => channel}, _uri, socket) do
    ch = Render.canonical_channel(channel)

    if socket.assigns.view == :channel and ch == socket.assigns.channel do
      {:noreply, socket}
    else
      {:noreply, load_channel(socket, ch)}
    end
  end

  def handle_params(_params, _uri, socket) do
    # Channel list — keep AV assigns / AvCall panel mounted.
    {:noreply, show_channel_list(socket)}
  end

  @impl true
  def handle_event("send", %{"msg" => msg}, socket) do
    sid = socket.assigns.freeq_session
    ch = socket.assigns.channel

    if ch in [nil, ""] do
      {:noreply, socket}
    else
      opts =
        []
        |> then(fn o ->
          if socket.assigns.reply_to,
            do: Keyword.put(o, :reply_to, socket.assigns.reply_to),
            else: o
        end)
        |> then(fn o ->
          if socket.assigns.edit_to, do: Keyword.put(o, :edit_to, socket.assigns.edit_to), else: o
        end)

      Session.send_message(sid, ch, msg, opts)

      {:noreply,
       socket
       |> assign(:compose, "")
       |> assign(:reply_to, nil)
       |> assign(:edit_to, nil)
       |> assign(:reply_preview_nick, nil)
       |> assign(:reply_preview_text, nil)
       |> focus_compose()}
    end
  end

  def handle_event("join", %{"channel" => raw}, socket) do
    ch = raw |> to_string() |> String.trim()

    if ch == "" do
      {:noreply, socket}
    else
      Session.join(socket.assigns.freeq_session, ch)
      bare = Render.bare_channel(ch)
      # push_patch (not navigate) so an active AV call survives channel switches.
      {:noreply, push_patch(socket, to: ~p"/chat/#{bare}")}
    end
  end

  def handle_event("part", %{"channel" => ch}, socket) do
    Session.part(socket.assigns.freeq_session, ch)

    if socket.assigns.view == :channel and
         Render.canonical_channel(ch) == socket.assigns.channel do
      # Stay on this LiveView — do not navigate to ChatIndexLive (would kill AV).
      {:noreply, push_patch(socket, to: ~p"/chat")}
    else
      snap = Session.snapshot(socket.assigns.freeq_session)

      {:noreply,
       socket
       |> assign(:snap, snap)
       |> assign(:my_channels, my_channel_entries(snap.channels, socket.assigns.all_channels))}
    end
  end

  def handle_event("edit_topic", _params, socket) do
    if can_edit_topic?(socket.assigns.members, socket.assigns.snap) do
      {:noreply, assign(socket, :editing_topic, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_topic_edit", _params, socket) do
    {:noreply, assign(socket, :editing_topic, false)}
  end

  def handle_event("set_topic", %{"topic" => topic}, socket) do
    ch = socket.assigns.channel
    topic = topic |> to_string() |> String.trim()

    cond do
      ch in [nil, ""] ->
        {:noreply, socket}

      not can_edit_topic?(socket.assigns.members, socket.assigns.snap) ->
        {:noreply, assign(socket, :editing_topic, false)}

      true ->
        Session.set_topic(socket.assigns.freeq_session, ch, topic)

        {:noreply,
         socket
         |> assign(:topic, topic)
         |> assign(:editing_topic, false)}
    end
  end

  def handle_event("av_start", _params, socket) do
    sid = socket.assigns.freeq_session
    ch = socket.assigns.channel
    instance = socket.assigns.av_instance

    cond do
      socket.assigns.av_active ->
        {:noreply, socket}

      ch in [nil, ""] ->
        # Channel list view — start requires an open channel.
        {:noreply, socket}

      true ->
        # Guests may start calls — freeq-server uses did "guest:{nick}".
        # If a live session already exists, join it instead of erroring.
        socket = apply_channel_call(socket, ch)

        if socket.assigns.av_call_present and socket.assigns.av_session_id not in [nil, ""] do
          Session.av_join(sid, ch, socket.assigns.av_session_id, instance)

          {:noreply,
           socket
           |> assign(:av_active, true)
           |> assign(:av_channel, ch)}
        else
          Session.av_start(sid, ch, instance)

          {:noreply,
           socket
           |> assign(:av_active, true)
           |> assign(:av_channel, ch)}
        end
    end
  end

  def handle_event("av_join", _params, socket) do
    sid = socket.assigns.freeq_session
    ch = socket.assigns.channel
    instance = socket.assigns.av_instance

    cond do
      socket.assigns.av_active ->
        {:noreply, socket}

      ch in [nil, ""] ->
        {:noreply, socket}

      true ->
        # Refresh discovery in case session id arrived after page load.
        socket = apply_channel_call(socket, ch)
        session_id_av = socket.assigns.av_session_id

        if session_id_av not in [nil, ""] do
          Session.av_join(sid, ch, session_id_av, instance)

          {:noreply,
           socket
           |> assign(:av_active, true)
           |> assign(:av_channel, ch)}
        else
          # No known session — fall back to start (server may still reject if race).
          Session.av_start(sid, ch, instance)

          {:noreply,
           socket
           |> assign(:av_active, true)
           |> assign(:av_channel, ch)}
        end
    end
  end

  def handle_event("av_leave", _params, socket) do
    sid = socket.assigns.freeq_session
    # Leave the AV channel (may differ from the text channel currently open).
    ch = socket.assigns.av_channel || socket.assigns.channel
    session_id_av = socket.assigns.av_session_id
    instance = socket.assigns.av_instance

    if session_id_av do
      Session.av_leave(sid, ch, session_id_av, instance)
    end

    socket =
      socket
      |> assign(:av_active, false)
      |> assign(:av_call_present, false)
      |> assign(:av_session_id, nil)
      |> assign(:av_channel, nil)
      |> assign(:av_participant_count, 0)
      |> assign(:av_muted, false)
      |> assign(:av_camera, false)
      |> push_event("av_ended", %{})
      # Re-discover whether the *viewed* text channel has a call.
      |> apply_channel_call(socket.assigns.channel)

    {:noreply, socket}
  end

  def handle_event("av_toggle_mute", _params, socket) do
    muted = not socket.assigns.av_muted
    {:noreply, socket |> assign(:av_muted, muted) |> push_event("av_muted", %{muted: muted})}
  end

  def handle_event("av_toggle_camera", _params, socket) do
    camera = not socket.assigns.av_camera

    {:noreply,
     socket
     |> assign(:av_camera, camera)
     |> push_event("av_camera", %{camera: camera})}
  end

  def handle_event("av_roster", %{"count" => count}, socket) do
    n =
      case count do
        n when is_integer(n) -> n
        n when is_binary(n) -> String.to_integer(n)
        _ -> socket.assigns.av_participant_count
      end

    {:noreply, assign(socket, :av_participant_count, n)}
  rescue
    _ -> {:noreply, socket}
  end

  def handle_event("reply", params, socket) do
    msgid = params["msgid"] || ""
    nick = params["nick"] || "message"
    text = params["text"] || ""

    {:noreply,
     socket
     |> assign(:reply_to, msgid)
     |> assign(:edit_to, nil)
     |> assign(:reply_preview_nick, nick)
     |> assign(:reply_preview_text, preview_text(text))
     |> focus_compose()}
  end

  def handle_event("edit", params, socket) do
    msgid = params["msgid"] || ""
    text = params["text"] || ""

    {:noreply,
     socket
     |> assign(:edit_to, msgid)
     |> assign(:reply_to, nil)
     |> assign(:reply_preview_nick, nil)
     |> assign(:reply_preview_text, preview_text(text))
     |> assign(:compose, text)
     |> focus_compose()}
  end

  def handle_event("cancel_reply", _, socket) do
    # Cancelling an edit clears the compose draft; cancelling a reply keeps typed text.
    was_editing? = not is_nil(socket.assigns.edit_to)

    socket =
      socket
      |> assign(:reply_to, nil)
      |> assign(:edit_to, nil)
      |> assign(:reply_preview_nick, nil)
      |> assign(:reply_preview_text, nil)
      |> then(fn s -> if was_editing?, do: assign(s, :compose, ""), else: s end)
      |> focus_compose()

    {:noreply, socket}
  end

  def handle_event("compose_change", %{"msg" => msg}, socket) do
    {:noreply, assign(socket, :compose, msg)}
  end

  def handle_event("scroll_to_message", %{"msgid" => msgid}, socket) do
    {:noreply, push_event(socket, "scroll_to_message", %{msgid: msgid})}
  end

  def handle_event("open_react_picker", %{"msgid" => msgid}, socket) do
    {:noreply, assign(socket, :react_picker_msgid, msgid)}
  end

  def handle_event("close_react_picker", _, socket) do
    {:noreply, assign(socket, :react_picker_msgid, nil)}
  end

  def handle_event("toggle_reaction", %{"msgid" => msgid, "emoji" => emoji}, socket) do
    msgid = to_string(msgid || "")
    emoji = to_string(emoji || "")

    if msgid == "" or emoji == "" do
      {:noreply, assign(socket, :react_picker_msgid, nil)}
    else
      aliases = my_reaction_aliases(socket)
      row = Map.get(socket.assigns.rows_by_msgid || %{}, msgid)
      reactions = (row && row[:reactions]) || %{}
      nicks = Map.get(reactions, emoji, [])
      mine? = nick_in_list?(nicks, aliases)
      added? = not mine?

      # Enqueue TAGMSG + optimistic channel broadcast (Session.react).
      _ = Session.react(socket.assigns.freeq_session, socket.assigns.channel, msgid, emoji, added?)

      {:noreply, assign(socket, :react_picker_msgid, nil)}
    end
  end

  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    socket =
      cond do
        socket.assigns.react_picker_msgid ->
          assign(socket, :react_picker_msgid, nil)

        socket.assigns.reply_to || socket.assigns.edit_to ->
          was_editing? = not is_nil(socket.assigns.edit_to)

          socket
          |> assign(:reply_to, nil)
          |> assign(:edit_to, nil)
          |> assign(:reply_preview_nick, nil)
          |> assign(:reply_preview_text, nil)
          |> then(fn s -> if was_editing?, do: assign(s, :compose, ""), else: s end)

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("keydown", _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:message, row}, socket) do
    # Prefer cache-only for the first paint; resolve+download off the LV process.
    lookup = remember_parent(socket.assigns.parent_lookup || %{}, row)
    row_fast =
      row
      |> LinkPreview.attach_cache_only()
      |> attach_parent_info(lookup)
      |> ensure_reactions()

    socket =
      socket
      |> assign(:parent_lookup, lookup)
      |> track_row(row_fast)
      |> stream_insert(:messages, row_fast, at: -1)
      |> assign(:message_count, socket.assigns.message_count + 1)
      |> push_event("scroll_bottom", %{})

    if row_fast.kind == :msg and is_nil(row_fast[:embed]) and is_binary(row_fast[:text]) do
      lv = self()

      Task.start(fn ->
        full =
          row
          |> LinkPreview.attach()
          |> attach_parent_info(lookup)
          |> ensure_reactions()

        if full[:embed] do
          send(lv, {:message_embed, full})
        end
      end)
    end

    {:noreply, socket}
  end

  def handle_info({:message_embed, row}, socket) do
    # Update the existing stream row with a fully resolved local preview.
    # Re-attach parent info so the reply badge survives the embed patch.
    row =
      row
      |> attach_parent_info(socket.assigns.parent_lookup || %{})
      |> ensure_reactions()
      |> merge_tracked_reactions(socket.assigns.rows_by_msgid || %{})

    socket =
      socket
      |> track_row(row)
      |> stream_insert(:messages, row, update_only: true)

    {:noreply, socket}
  end

  def handle_info({:reaction, msgid, emoji, nick, added}, socket) do
    msgid = to_string(msgid || "")
    emoji = to_string(emoji || "")
    nick = to_string(nick || "")

    if msgid == "" or emoji == "" do
      {:noreply, socket}
    else
      {:noreply, apply_reaction(socket, msgid, emoji, nick, added)}
    end
  end

  def handle_info({:preview_warmup, rows}, socket) when is_list(rows) do
    # Background: resolve uncached previews and patch stream rows in place.
    # Does not block mount / first paint.
    lv = self()

    Task.start(fn ->
      rows
      |> Enum.filter(fn row ->
        row[:kind] == :msg and is_nil(row[:embed]) and is_binary(row[:text]) and
          String.contains?(row[:text], "http")
      end)
      # Newest-looking rows last in history list — warm a reasonable batch.
      |> Enum.take(30)
      |> Task.async_stream(&LinkPreview.attach/1,
        max_concurrency: 3,
        timeout: 8_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.each(fn
        {:ok, row} ->
          if is_map(row) and row[:embed] do
            send(lv, {:message_embed, row})
          end

        _ ->
          :ok
      end)
    end)

    {:noreply, socket}
  end

  def handle_info({:av_state, %{channel: ch} = av}, socket) do
    ch_canon = String.downcase(Render.canonical_channel(ch))

    view_ch =
      case socket.assigns.channel do
        nil -> nil
        "" -> nil
        c -> String.downcase(Render.canonical_channel(c))
      end

    av_ch =
      case socket.assigns[:av_channel] do
        nil -> nil
        c -> String.downcase(Render.canonical_channel(c))
      end

    our_call? = socket.assigns.av_active == true and av_ch != nil and av_ch == ch_canon
    view_channel? = view_ch != nil and ch_canon == view_ch

    # Ignore call signals for channels we are neither viewing nor in a call on.
    if not our_call? and not view_channel? do
      {:noreply, socket}
    else
      state = String.downcase(to_string(av.state))

      socket =
        cond do
          state in ["started", "joined"] ->
            # If we are already in a call on another channel, do not clobber
            # that session with discovery for the channel we are only viewing.
            if socket.assigns.av_active and not our_call? do
              socket
            else
              socket
              |> assign(:av_call_present, true)
              |> assign(:av_session_id, av.session_id)
              |> assign(:av_participant_count, av.participants || 0)
              |> then(fn s ->
                if s.assigns.av_active or av_state_is_self?(av, s) do
                  s
                  |> assign(:av_active, true)
                  |> assign(:av_channel, Render.canonical_channel(ch))
                else
                  s
                end
              end)
              |> push_event("av_state", %{
                channel: ch,
                state: av.state,
                session_id: av.session_id,
                participants: av.participants || 0,
                actor: av.actor,
                instance: av.instance
              })
            end

          state == "ended" and (our_call? or (view_channel? and not socket.assigns.av_active)) ->
            # Full call end on our call channel, or discovery clear on the viewed channel.
            socket
            |> assign(:av_active, false)
            |> assign(:av_call_present, false)
            |> assign(:av_session_id, nil)
            |> assign(:av_channel, nil)
            |> assign(:av_participant_count, 0)
            |> push_event("av_ended", %{session_id: av.session_id})

          state in ["ended", "left"] ->
            # Peer left (or end of a call we are not in) — refresh discovery count.
            if our_call? or (view_channel? and not socket.assigns.av_active) do
              send(self(), :poll_channel_call)
            end

            socket

          true ->
            socket
        end

      {:noreply, socket}
    end
  end

  def handle_info({:av_token, %{session_id: sid, token: token}}, socket) do
    {:noreply,
     socket
     |> assign(:av_session_id, sid)
     |> push_event("av_token", %{session_id: sid, token: token})}
  end

  def handle_info({:members, members}, socket) do
    {:noreply, assign(socket, :members, members)}
  end

  def handle_info({:topic, topic}, socket) do
    {:noreply, assign(socket, :topic, topic)}
  end

  def handle_info({:ws_state, ws_state, nick}, socket) do
    snap =
      socket.assigns.snap
      |> Map.put(:ws_state, ws_state)
      |> Map.put(:current_nick, nick)

    socket = assign(socket, :snap, snap)

    socket =
      cond do
        ws_state == :disconnected ->
          assign(socket, :needs_history_backfill, true)

        ws_state == :ready and socket.assigns[:needs_history_backfill] ->
          socket
          |> assign(:needs_history_backfill, false)
          # Messages that arrived while the upstream was dead never hit PubSub.
          |> backfill_history_gap()

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:channels_changed, channels}, socket) do
    {:noreply,
     socket
     |> update(:snap, &Map.put(&1, :channels, channels))
     |> assign(:my_channels, my_channel_entries(channels, socket.assigns.all_channels))}
  end

  def handle_info({:nick, nick}, socket) do
    {:noreply, update(socket, :snap, &Map.put(&1, :current_nick, nick))}
  end

  def handle_info({:auth_changed, auth}, socket) do
    {:noreply, update(socket, :snap, &Map.merge(&1, auth))}
  end

  def handle_info(:poll_channel_call, socket) do
    # Don't clobber local "in call" state (including when viewing another
    # text channel or the channel list while still in the AV call).
    cond do
      socket.assigns.av_active ->
        {:noreply, socket}

      socket.assigns.view != :channel or socket.assigns.channel in [nil, ""] ->
        {:noreply, socket}

      true ->
        {:noreply, apply_channel_call(socket, socket.assigns.channel)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp my_channel_entries(channels, all) do
    by_name =
      Map.new(all, fn c ->
        name = c["name"] || c[:name] || ""
        {String.downcase(Render.canonical_channel(name)), c}
      end)

    channels
    |> Enum.map(&Render.canonical_channel/1)
    |> Enum.sort_by(&String.downcase/1)
    |> Enum.map(fn ch ->
      meta = Map.get(by_name, String.downcase(ch), %{})

      %{
        name: ch,
        bare: Render.bare_channel(ch),
        topic: meta["topic"] || "",
        members: meta["members"] || 0
      }
    end)
  end

  defp topic_for(all, ch) do
    Enum.find_value(all, "", fn c ->
      name = c["name"] || c[:name] || ""

      if String.downcase(Render.canonical_channel(name)) == String.downcase(ch) do
        c["topic"] || c[:topic] || ""
      end
    end)
  end

  # Public channel list hides +i/+k/policy channels, so private rooms like
  # #freeq never get a topic from that list. Fall back to the per-channel
  # topic endpoint (and IRC 332 still updates live via PubSub).
  defp resolve_topic(all, ch) do
    case topic_for(all, ch) do
      t when is_binary(t) and t != "" -> t
      _ -> Rest.fetch_channel_topic(ch) || ""
    end
  end

  # Channel +o (and half-op) can set topic when +t is on; server enforces 482.
  defp can_edit_topic?(members, snap) when is_map(members) do
    nick = to_string(snap[:current_nick] || "")
    if nick == "" do
      false
    else
      entry =
        Enum.find_value(members, fn {k, v} ->
          if String.downcase(to_string(k)) == String.downcase(nick), do: v
        end)

      case entry do
        %{op: true} -> true
        %{halfop: true} -> true
        _ -> false
      end
    end
  end

  defp can_edit_topic?(_, _), do: false

  defp member_list(members) do
    members
    |> Map.values()
    |> Enum.sort_by(fn m ->
      rank =
        cond do
          m[:op] -> 0
          m[:halfop] -> 1
          m[:voiced] -> 2
          true -> 3
        end

      {rank, String.downcase(m.nick)}
    end)
  end

  defp ws_label(:ready), do: "connected"
  defp ws_label(:connecting), do: "connecting…"
  defp ws_label(:registering), do: "registering…"
  defp ws_label(_), do: "offline"

  defp generate_av_instance do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  # ── View modes (index list vs channel pane) ───────────────────────────

  defp show_channel_list(socket) do
    sid = socket.assigns.freeq_session
    snap = Session.snapshot(sid)
    all = socket.assigns[:all_channels] || Rest.fetch_channels()

    socket
    |> assign(:view, :index)
    |> assign(:page_title, "channels")
    # Keep last text channel in assigns only as a soft hint; UI uses :view.
    # Do not clear :channel if we want? Clear for nav title but keep av_channel.
    |> assign(:channel, nil)
    |> assign(:bare, "")
    |> assign(:topic, "")
    |> assign(:editing_topic, false)
    |> assign(:snap, snap)
    |> assign(:all_channels, all)
    |> assign(:my_channels, my_channel_entries(snap.channels, all))
    |> assign(:members, %{})
    |> assign(:compose, "")
    |> assign(:reply_to, nil)
    |> assign(:edit_to, nil)
    |> assign(:reply_preview_nick, nil)
    |> assign(:reply_preview_text, nil)
    |> assign(:react_picker_msgid, nil)
    # Empty stream — index has no message pane. AV panel (if any) stays.
    |> stream(:messages, [], reset: true)
    |> assign(:message_count, 0)
    # AV state deliberately unchanged — browsing the directory must not leave.
  end

  defp load_channel(socket, ch) do
    bare = Render.bare_channel(ch)
    sid = socket.assigns.freeq_session
    Session.subscribe_channel(sid, ch)
    Session.add_channel(sid, ch)
    Session.ensure_upstream(sid, ch)

    snap = Session.snapshot(sid)
    all = socket.assigns[:all_channels] || Rest.fetch_channels()
    topic = resolve_topic(all, ch)

    # Fast path: history + cache-only embeds. Network preview resolution
    # must NOT block navigation.
    history =
      (Rest.fetch_history(ch, 50, bearer: snap.api_bearer) || [])
      |> Enum.map(&LinkPreview.attach_cache_only/1)

    parent_lookup = parent_lookup_from_rows(history)

    history =
      history
      |> Enum.map(&attach_parent_info(&1, parent_lookup))
      |> Enum.map(&ensure_reactions/1)

    rows_by_msgid = rows_by_msgid_from(history)
    members = Session.members(sid, ch)
    schedule_preview_warmup(history)

    keep_av? = socket.assigns.av_active == true
    prev_channel = socket.assigns.channel
    prev_av_channel = socket.assigns[:av_channel]

    socket
    |> assign(:view, :channel)
    |> assign(:page_title, ch)
    |> assign(:channel, ch)
    |> assign(:bare, bare)
    |> assign(:snap, snap)
    |> assign(:topic, topic)
    |> assign(:editing_topic, false)
    |> assign(:all_channels, all)
    |> assign(:my_channels, my_channel_entries(snap.channels, all))
    |> assign(:members, members)
    |> assign(:compose, "")
    |> assign(:reply_to, nil)
    |> assign(:edit_to, nil)
    |> assign(:reply_preview_nick, nil)
    |> assign(:reply_preview_text, nil)
    |> assign(:parent_lookup, parent_lookup)
    |> assign(:rows_by_msgid, rows_by_msgid)
    |> assign(:react_picker_msgid, nil)
    |> stream(:messages, history, reset: true)
    |> assign(:message_count, length(history))
    |> then(fn s ->
      if keep_av? do
        # Pin av_channel if missing so leave/signaling still target the call.
        if s.assigns[:av_channel] in [nil, ""] do
          assign(s, :av_channel, prev_av_channel || prev_channel)
        else
          s
        end
      else
        s
        |> assign(:av_active, false)
        |> assign(:av_call_present, false)
        |> assign(:av_session_id, nil)
        |> assign(:av_channel, nil)
        |> assign(:av_participant_count, 0)
        |> assign(:av_muted, false)
        |> assign(:av_camera, false)
        |> assign(:av_instance, generate_av_instance())
        |> apply_channel_call(ch)
      end
    end)
    # Hook is not remounted on live channel nav — force scroll after reset.
    |> push_event("scroll_bottom", %{})
  end

  # Defer network-heavy preview work until after the page is interactive.
  defp schedule_preview_warmup(history) when is_list(history) do
    send(self(), {:preview_warmup, history})
  end

  defp schedule_preview_warmup(_), do: :ok

  # Banner / badge snippet of a parent message (matches freeq-web2 ~80 char cap).
  defp preview_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp preview_text(_), do: ""

  defp focus_compose(socket) do
    push_event(socket, "focus_compose", %{})
  end

  # msgid → %{nick:, text:} so reply badges can show the original in-channel.
  defp parent_lookup_from_rows(rows) when is_list(rows) do
    Enum.reduce(rows, %{}, &remember_parent(&2, &1))
  end

  defp parent_lookup_from_rows(_), do: %{}

  defp remember_parent(lookup, %{msgid: mid, nick: nick, text: text})
       when is_binary(mid) and mid != "" and is_map(lookup) do
    lookup = Map.put(lookup, mid, %{nick: to_string(nick || ""), text: to_string(text || "")})

    # Bound growth (same idea as freeq-web2 SessionState#parent_lookup).
    if map_size(lookup) > 2000 do
      lookup
      |> Enum.take(-1000)
      |> Map.new()
    else
      lookup
    end
  end

  defp remember_parent(lookup, _), do: lookup || %{}

  defp attach_parent_info(%{parent: parent} = row, lookup)
       when is_binary(parent) and parent != "" and is_map(lookup) do
    case Map.get(lookup, parent) do
      %{nick: nick, text: text} ->
        Map.merge(row, %{parent_nick: nick, parent_text: text})

      _ ->
        Map.merge(row, %{parent_nick: nil, parent_text: nil})
    end
  end

  defp attach_parent_info(row, _), do: row

  # freeq-web2 reaction palette.
  defp react_emojis, do: ~w(👍 ❤️ 😂 🎉 🔥 👀 💯 ✨)

  defp ensure_reactions(%{} = row) do
    Map.update(row, :reactions, %{}, fn
      m when is_map(m) -> m
      _ -> %{}
    end)
  end

  defp ensure_reactions(row), do: row

  defp rows_by_msgid_from(rows) when is_list(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      case row do
        %{msgid: mid} when is_binary(mid) and mid != "" -> Map.put(acc, mid, row)
        _ -> acc
      end
    end)
  end

  defp rows_by_msgid_from(_), do: %{}

  # After upstream reconnect, pull recent REST history and append any rows we
  # do not already have (by msgid). Dedupes against the live stream.
  defp backfill_history_gap(socket) do
    ch = socket.assigns.channel

    if socket.assigns.view != :channel or ch in [nil, ""] do
      socket
    else
      do_backfill_history_gap(socket, ch)
    end
  end

  defp do_backfill_history_gap(socket, ch) do
    bearer = socket.assigns.snap[:api_bearer]

    case Rest.fetch_history(ch, 50, bearer: bearer) do
      rows when is_list(rows) and rows != [] ->
        {socket, inserted} =
          Enum.reduce(rows, {socket, 0}, fn row, {sock, n} ->
            mid = row[:msgid]
            known = sock.assigns.rows_by_msgid || %{}

            if is_binary(mid) and mid != "" and Map.has_key?(known, mid) do
              {sock, n}
            else
              lookup = remember_parent(sock.assigns.parent_lookup || %{}, row)

              row =
                row
                |> LinkPreview.attach_cache_only()
                |> attach_parent_info(lookup)
                |> ensure_reactions()

              sock =
                sock
                |> assign(:parent_lookup, lookup)
                |> track_row(row)
                |> stream_insert(:messages, row, at: -1)
                |> assign(:message_count, sock.assigns.message_count + 1)

              {sock, n + 1}
            end
          end)

        if inserted > 0 do
          push_event(socket, "scroll_bottom", %{})
        else
          socket
        end

      _ ->
        socket
    end
  rescue
    _ -> socket
  end

  defp track_row(socket, %{msgid: mid} = row) when is_binary(mid) and mid != "" do
    update(socket, :rows_by_msgid, fn map -> Map.put(map || %{}, mid, row) end)
  end

  defp track_row(socket, _), do: socket

  # Keep live reaction chips when a link-preview patch rebuilds the row.
  defp merge_tracked_reactions(%{msgid: mid} = row, rows_by_msgid)
       when is_binary(mid) and mid != "" and is_map(rows_by_msgid) do
    case Map.get(rows_by_msgid, mid) do
      %{reactions: rx} when is_map(rx) and map_size(rx) > 0 ->
        Map.put(row, :reactions, rx)

      _ ->
        row
    end
  end

  defp merge_tracked_reactions(row, _), do: row

  defp my_reaction_aliases(%Phoenix.LiveView.Socket{} = socket) do
    my_reaction_aliases(socket.assigns[:snap] || %{})
  end

  defp my_reaction_aliases(snap) when is_map(snap) do
    [snap[:current_nick], snap[:auth_nick], snap[:auth_handle]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp my_reaction_aliases(_), do: []

  defp nick_in_list?(nicks, aliases) when is_list(nicks) and is_list(aliases) do
    Enum.any?(nicks, fn n -> String.downcase(to_string(n)) in aliases end)
  end

  defp nick_in_list?(_, _), do: false

  defp apply_reaction(socket, msgid, emoji, nick, added) do
    rows = socket.assigns.rows_by_msgid || %{}

    case Map.get(rows, msgid) do
      nil ->
        # Parent not in the loaded window — nothing to paint.
        socket

      row ->
        reactions = apply_reaction_map(row[:reactions] || %{}, emoji, nick, added)
        row = Map.put(row, :reactions, reactions)

        socket
        |> track_row(row)
        |> stream_insert(:messages, row, update_only: true)
    end
  end

  defp apply_reaction_map(reactions, emoji, nick, added) when is_map(reactions) do
    nick = to_string(nick)
    nicks = Map.get(reactions, emoji, []) |> Enum.map(&to_string/1)

    nicks =
      if added do
        if Enum.any?(nicks, &(String.downcase(&1) == String.downcase(nick))) do
          nicks
        else
          nicks ++ [nick]
        end
      else
        Enum.reject(nicks, &(String.downcase(&1) == String.downcase(nick)))
      end

    if nicks == [] do
      Map.delete(reactions, emoji)
    else
      Map.put(reactions, emoji, nicks)
    end
  end

  defp reaction_chip_label(emoji, nicks) when is_list(nicks) do
    if length(nicks) <= 1, do: emoji, else: "#{emoji} #{length(nicks)}"
  end

  defp reaction_mine?(nicks, aliases), do: nick_in_list?(nicks, aliases)

  # Treat av-state as "ours" when the actor nick matches our nick/handle.
  defp av_state_is_self?(av, socket) do
    actor = to_string(av[:actor] || "")
    nick = to_string(socket.assigns.snap[:current_nick] || "")
    handle = to_string(socket.assigns.snap[:auth_handle] || "")
    auth_nick = to_string(socket.assigns.snap[:auth_nick] || "")

    actor != "" and
      Enum.any?([nick, handle, auth_nick], fn n ->
        n != "" and String.downcase(n) == String.downcase(actor)
      end)
  end

  # Discover live call on this channel via freeq-server REST (works for guests).
  # Never overwrites an active AV session (which may be on another channel).
  defp apply_channel_call(socket, channel) do
    cond do
      socket.assigns[:av_active] ->
        socket

      channel in [nil, ""] ->
        socket

      true ->
        case Rest.fetch_channel_sessions(channel) |> Rest.active_call_from_sessions() do
          %{session_id: sid} = info when is_binary(sid) and sid != "" ->
            socket
            |> assign(:av_call_present, true)
            |> assign(:av_session_id, sid)
            |> assign(:av_participant_count, info.participant_count || 0)

          _ ->
            socket
            |> assign(:av_call_present, false)
            |> assign(:av_session_id, nil)
            |> assign(:av_participant_count, 0)
        end
    end
  rescue
    _ -> socket
  end

  # UTC clock as SSR/no-JS fallback; browser rewrites via data-ts → local 12h time.
  # NBSP between time and AM/PM so "4 PM" never wraps to "4\nPM".
  defp format_ts(%DateTime{} = t) do
    Calendar.strftime(t, "%-I:%M") <> "\u00A0" <> Calendar.strftime(t, "%p")
  end

  defp format_ts(_), do: ""

  defp ts_unix(%DateTime{} = t), do: DateTime.to_unix(t)
  defp ts_unix(_), do: nil

  # CSS class for a message row. Prefer web2 names (msg/join/part/notice).
  defp msg_row_class(:msg), do: "msg"
  defp msg_row_class(:join), do: "join"
  defp msg_row_class(:part), do: "part"
  defp msg_row_class(:notice), do: "notice"
  defp msg_row_class(_), do: "notice"

  attr :msg, :map, required: true
  attr :my_aliases, :list, default: []

  defp message_body(assigns) do
    ~H"""
    <span class="body">
      <%= if @msg.kind == :msg do %>
        <button
          :if={@msg[:parent] not in [nil, ""]}
          type="button"
          class="reply-badge"
          data-reply-to={@msg.parent}
          title="Jump to original"
          phx-click="scroll_to_message"
          phx-value-msgid={@msg.parent}
        >
          ↪ <span class="reply-nick">{@msg[:parent_nick] || "message"}</span>
          <span :if={@msg[:parent_text] not in [nil, ""]} class="reply-text">
            {preview_text(@msg.parent_text)}
          </span>
        </button>
        <span class={["nick", @msg[:color] || "n1"]}>{@msg.nick}</span>{" "}<.rich_text text={@msg.text} /><span
          :if={@msg[:msgid]}
          class="reactions"
        >
          <button
            :for={{emoji, nicks} <- reaction_entries(@msg[:reactions])}
            type="button"
            class={["reaction-chip", reaction_mine?(nicks, @my_aliases) && "mine"]}
            title={Enum.join(nicks, ", ")}
            data-emoji={emoji}
            data-msgid={@msg.msgid}
            phx-click="toggle_reaction"
            phx-value-msgid={@msg.msgid}
            phx-value-emoji={emoji}
          >
            {reaction_chip_label(emoji, nicks)}
          </button>
          <button
            type="button"
            class="react-btn"
            title="React"
            phx-click="open_react_picker"
            phx-value-msgid={@msg.msgid}
          >
            +
          </button>
        </span>
        <button
          :if={@msg[:msgid]}
          type="button"
          class="reply-btn"
          title="Reply"
          phx-click="reply"
          phx-value-msgid={@msg.msgid}
          phx-value-nick={@msg.nick}
          phx-value-text={@msg.text}
        >
          ↩
        </button>
      <% else %>
        <%= if @msg.kind in [:join, :part] do %>
          — {@msg.nick} {@msg.text}
        <% else %>
          <.rich_text text={@msg.text} />
        <% end %>
      <% end %>
    </span>
    """
  end

  # Linkify http(s) URLs; render direct image URLs as inline previews (web2 msg-img).
  attr :text, :string, required: true

  defp rich_text(assigns) do
    assigns = assign(assigns, :segments, Render.text_segments(assigns.text || ""))

    ~H"""
    <%= for seg <- @segments do %>
      <%= case seg do %>
        <% {:text, t} -> %>
          {t}
        <% {:link, url} -> %>
          <a href={url} target="_blank" rel="noopener noreferrer">{url}</a>
        <% {:image, url} -> %>
          <a href={url} target="_blank" rel="noopener noreferrer" class="msg-img-url">{url}</a>
          <a href={url} target="_blank" rel="noopener noreferrer" class="msg-img-link">
            <img
              src={url}
              alt=""
              class="msg-img"
              loading="lazy"
              referrerpolicy="no-referrer"
            />
          </a>
      <% end %>
    <% end %>
    """
  end

  # Stable chip order: sort emoji keys so the stream patch doesn't reshuffle.
  defp reaction_entries(nil), do: []
  defp reaction_entries(reactions) when is_map(reactions) do
    reactions
    |> Enum.filter(fn {_e, nicks} -> is_list(nicks) and nicks != [] end)
    |> Enum.sort_by(fn {emoji, _} -> emoji end)
  end

  defp reaction_entries(_), do: []

  attr :embed, :map, required: true

  defp link_embed(assigns) do
    ~H"""
    <a
      href={@embed.href}
      target="_blank"
      rel="noopener noreferrer"
      class={[
        "link-embed",
        @embed.kind == :youtube && "yt-embed",
        @embed.kind == :bsky && "bsky-embed"
      ]}
      style="grid-column: 2"
    >
      <%= if @embed.kind == :bsky && @embed[:bsky] do %>
        <div class="bsky-author">
          <%= if @embed.bsky[:avatar_url] do %>
            <img class="bsky-avatar" src={@embed.bsky.avatar_url} alt="" loading="lazy" />
          <% else %>
            <span class="bsky-avatar bsky-avatar-fallback">
              {String.first(@embed.bsky[:handle] || "?") |> String.upcase()}
            </span>
          <% end %>
          <span class="bsky-name">{@embed.bsky[:display]}</span>
          <span class="bsky-handle">@{@embed.bsky[:handle]}</span>
        </div>
        <div class="bsky-text">{@embed.bsky[:text]}</div>
        <img
          :if={@embed[:image_url]}
          class="link-embed-img"
          src={@embed.image_url}
          alt=""
          loading="lazy"
        />
        <div class="bsky-footer">
          <span>♥ {@embed.bsky[:likes] || 0}</span>
          <span>↻ {@embed.bsky[:reposts] || 0}</span>
          <span class="bsky-time">🦋 {@embed.bsky[:time]}</span>
        </div>
      <% else %>
        <img
          :if={@embed[:image_url]}
          class={["link-embed-img", @embed.kind == :youtube && "yt-thumb"]}
          src={@embed.image_url}
          alt=""
          loading="lazy"
        />
        <div class={["link-embed-body", @embed.kind == :youtube && "yt-footer"]}>
          <%= if @embed.kind == :youtube do %>
            <span class="yt-play">▶</span> YouTube
          <% else %>
            <div :if={@embed[:site_name]} class="link-embed-site">{@embed.site_name}</div>
            <div :if={@embed[:title]} class="link-embed-title">{@embed.title}</div>
            <div :if={@embed[:description]} class="link-embed-desc">{@embed.description}</div>
            <div :if={@embed[:domain]} class="link-embed-domain">{@embed.domain}</div>
          <% end %>
        </div>
      <% end %>
    </a>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="freeq-chat"
      phx-hook="ChatScroll"
      data-channel={@bare}
      phx-window-keydown="keydown"
    >
      <nav>
        <button
          type="button"
          class="mobile-btn"
          phx-click={
            JS.toggle_class("open", to: "#sidebar") |> JS.toggle_class("open", to: "#drawer-scrim")
          }
          aria-label="Channels"
        >
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16" /></svg>
        </button>
        <span class="brand">freeq</span>
        <div class="nav-channel-meta">
          <%= if @view == :index do %>
            <span class="nav-channel page-title">channels</span>
          <% else %>
            <span class="nav-channel">{@channel}</span>
            <%= if @editing_topic do %>
              <form id="topic-form" phx-submit="set_topic">
                <input
                  id="topic-input"
                  type="text"
                  name="topic"
                  value={@topic}
                  placeholder="Set topic… (Enter to save, Esc to cancel)"
                  autocomplete="off"
                  maxlength="390"
                  phx-keydown="cancel_topic_edit"
                  phx-key="Escape"
                  phx-mounted={JS.focus()}
                />
              </form>
            <% else %>
              <span
                id="channel-topic"
                class={if(can_edit_topic?(@members, @snap), do: "editable")}
                title={
                  if(can_edit_topic?(@members, @snap),
                    do: "Click to edit topic",
                    else: "Channel topic"
                  )
                }
                phx-click={if(can_edit_topic?(@members, @snap), do: "edit_topic")}
              >
                {if(@topic not in [nil, ""], do: @topic, else: "add topic")}
              </span>
            <% end %>
          <% end %>
          <button
            :if={@view == :channel or @av_active}
            type="button"
            id="av-call-btn"
            class={[
              "av-call-btn",
              if(@av_active, do: "in-call"),
              if(not @av_active and @av_call_present, do: "has-call")
            ]}
            phx-click={
              if(@av_active,
                do: "av_leave",
                else: if(@av_call_present, do: "av_join", else: "av_start")
              )
            }
            data-channel={@av_channel || @channel}
            data-nick={@snap.current_nick}
            data-instance={@av_instance}
            data-active={@av_active}
            title={
              cond do
                @av_active ->
                  call_ch = @av_channel || @channel
                  "In call on #{call_ch} — click to leave"
                @av_call_present ->
                  n = @av_participant_count || 0
                  "Join voice call (#{n} #{if n == 1, do: "person", else: "people"})"
                true -> "Start voice call"
              end
            }
          >
            {if(@av_active, do: "📞", else: if(@av_call_present, do: "🔊", else: "🎙️"))}
            <span
              :if={not @av_active and @av_call_present}
              class="av-call-badge"
            >{@av_participant_count || "!"}</span>
          </button>
        </div>
        <div class="nav-right">
          <span id="status" class={if @snap.ws_state == :ready, do: "connected"}>
            <span class="dot"></span>
            <span>{ws_label(@snap.ws_state)}</span>
          </span>
          <button
            :if={@view == :channel}
            type="button"
            class="mobile-btn"
            phx-click={
              JS.toggle_class("open", to: "#member-panel")
              |> JS.toggle_class("open", to: "#drawer-scrim")
            }
            aria-label="People"
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M16 19v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1" />
              <circle cx="9.5" cy="8" r="3.5" />
              <path d="M20 19v-1a3.5 3.5 0 0 0-2.5-3.35" />
              <path d="M16.5 4.6a3.5 3.5 0 0 1 0 6.8" />
            </svg>
          </button>
        </div>
      </nav>

      <div
        id="drawer-scrim"
        phx-click={
          JS.remove_class("open", to: "#sidebar")
          |> JS.remove_class("open", to: "#member-panel")
          |> JS.remove_class("open", to: "#drawer-scrim")
        }
        aria-hidden="true"
      >
      </div>

      <div class="chat-body">
        <aside id="sidebar">
          <p class="drawer-heading">Channels</p>
          <div class="sidebar-scroll">
            <form id="join-form" phx-submit="join">
              <input type="text" name="channel" placeholder="join #…" autocomplete="off" />
              <button type="submit">+</button>
            </form>
            <p class="sidebar-toggle"><span class="arrow">▾</span> MY CHANNELS</p>
            <ul id="my-channels">
              <li :for={ch <- @my_channels} class={if ch.name == @channel, do: "active"}>
                <%!-- patch keeps this LiveView + AvCall hook alive (redirect remounts and leaves AV). --%>
                <a
                  href={~p"/chat/#{ch.bare}"}
                  class="channel-link"
                  data-phx-link="patch"
                  data-phx-link-state="push"
                >
                  <span class="channel-link-name">{ch.name}</span>
                </a>
                <button
                  type="button"
                  class="sidebar-channel-part"
                  phx-click="part"
                  phx-value-channel={ch.name}
                  title="Part"
                >×</button>
              </li>
            </ul>
          </div>
          <div id="user-info">
            <div
              class={["user-handle", if(@snap[:authenticated?], do: "signed-in", else: "guest")]}
              id="user-handle"
            >
              👤 {if(@snap[:authenticated?],
                do: @snap[:auth_handle] || @snap.current_nick,
                else: @snap.current_nick || "guest"
              )}
            </div>
            <div class="user-actions">
              <a
                href={~p"/chat"}
                class="btn-link"
                data-phx-link="patch"
                data-phx-link-state="push"
              >
                All channels
              </a>
              <%= if @snap[:authenticated?] do %>
                <a href={~p"/logout"} class="btn-link">Sign out</a>
              <% else %>
                <a href={~p"/login"} class="btn-link">Sign in</a>
              <% end %>
            </div>
          </div>
        </aside>

        <section class="chat-main">
          <%!-- Channel directory (same LiveView as chat so AV call survives). --%>
          <div :if={@view == :index} class="channel-list-page">
            <form id="index-join-form" phx-submit="join">
              <input
                type="text"
                name="channel"
                placeholder="join #channel"
                autocomplete="off"
              />
              <button type="submit">Join</button>
            </form>

            <%= if @all_channels != [] do %>
              <ul class="channel-list">
                <li :for={ch <- @all_channels}>
                  <% bare = Render.bare_channel(ch["name"] || ch[:name] || "") %>
                  <a
                    href={~p"/chat/#{bare}"}
                    class="channel-item"
                    data-phx-link="patch"
                    data-phx-link-state="push"
                  >
                    <span class="channel-name">{ch["name"] || ch[:name]}</span>
                    <span :if={(ch["topic"] || ch[:topic] || "") != ""} class="channel-topic">
                      {ch["topic"] || ch[:topic]}
                    </span>
                    <span class="channel-members">{ch["members"] || ch[:members] || 0}</span>
                  </a>
                </li>
              </ul>
            <% else %>
              <p class="empty-state">No channels available (is freeq-server reachable?).</p>
            <% end %>
          </div>

          <%!-- Keep stream container mounted across index/channel (phx-update=stream). --%>
          <div
            id="messages"
            phx-update="stream"
            class={if(@view == :index, do: "is-hidden")}
            hidden={@view == :index}
          >
            <div
              :for={{dom_id, msg} <- @streams.messages}
              id={dom_id}
              class={msg_row_class(msg.kind)}
              data-msgid={msg[:msgid]}
              data-nick={msg[:nick]}
              data-text={msg[:text]}
            >
              <span class="ts" data-ts={ts_unix(msg.time)}>{format_ts(msg.time)}</span>
              <.message_body msg={msg} my_aliases={my_reaction_aliases(@snap)} />
              <.link_embed :if={msg[:embed]} embed={msg.embed} />
            </div>
          </div>

          <div
            :if={@av_active}
            id="av-call-panel"
            class={[
              "av-call-panel",
              "active",
              if(@av_camera, do: "is-camera-on"),
              if(@av_muted, do: "is-muted")
            ]}
            phx-hook="AvCall"
            data-channel={@av_channel || @channel}
            data-nick={@snap.current_nick}
            data-instance={@av_instance}
            data-session-id={@av_session_id || ""}
            data-muted={@av_muted}
            data-camera={@av_camera}
            data-authenticated={@snap[:authenticated?]}
            data-av-origin={FreeqWeb3.av_origin()}
          >
            <div class="av-call-bar">
              <span class="av-call-status">
                📞 {@av_channel || @channel} · {@av_participant_count || 1} in call
              </span>
              <div class="av-call-actions">
                <button
                  type="button"
                  class={["av-call-action", "av-mute-btn", if(@av_muted, do: "muted")]}
                  phx-click="av_toggle_mute"
                  title={if(@av_muted, do: "Unmute", else: "Mute")}
                >
                  {if(@av_muted, do: "🎤 off", else: "🎤 on")}
                </button>
                <button
                  type="button"
                  class={["av-call-action", "av-cam-btn", if(@av_camera, do: "on")]}
                  phx-click="av_toggle_camera"
                  title={if(@av_camera, do: "Turn off camera", else: "Turn on camera")}
                >
                  {if(@av_camera, do: "📷 on", else: "📷 off")}
                </button>
                <button
                  type="button"
                  class="av-call-action av-leave-btn"
                  phx-click="av_leave"
                  title="Leave call"
                >
                  Leave
                </button>
              </div>
            </div>

            <%!-- Media tiles: local + remote. phx-update=ignore so MoQ DOM survives LV patches. --%>
            <div id="av-video-grid" class="av-video-grid" phx-update="ignore">
              <div
                class="av-tile av-tile-local"
                id="av-local-tile"
                title="Click to enlarge"
                role="button"
                tabindex="0"
              >
                <video
                  id="av-local-video"
                  class="av-local-video"
                  autoplay
                  muted
                  playsinline
                  hidden
                >
                </video>
                <div class="av-tile-avatar local">You</div>
                <span class="av-tile-label">You</span>
              </div>
              <div id="av-remote-tiles" class="av-remote-tiles"></div>
            </div>
            <div id="av-publish-container" class="av-publish-container" phx-update="ignore"></div>
          </div>

          <div :if={@view == :channel and (@reply_to || @edit_to)} id="reply-banner" class="reply-banner">
            <span class="reply-banner-label">
              <%= if @edit_to do %>
                Editing message
              <% else %>
                Replying to {@reply_preview_nick || "message"}
              <% end %>
            </span>
            <span :if={@reply_preview_text not in [nil, ""]} class="reply-banner-text">
              {@reply_preview_text}
            </span>
            <button
              type="button"
              class="reply-banner-cancel"
              title="Cancel"
              phx-click="cancel_reply"
            >
              ×
            </button>
          </div>

          <div :if={@view == :channel} id="send-bar">
            <form id="send-form" phx-submit="send" phx-change="compose_change">
              <input
                id="message-input"
                type="text"
                name="msg"
                value={@compose}
                placeholder={"Message #{@channel}"}
                autocomplete="off"
                phx-hook="TabComplete"
                phx-mounted={JS.focus()}
              />
              <button type="submit">Send</button>
            </form>
          </div>
        </section>

        <aside :if={@view == :channel} id="member-panel">
          <p class="drawer-heading">People</p>
          <div id="member-list">
            <%= if map_size(@members) == 0 do %>
              <div class="member empty">—</div>
            <% else %>
              <div :for={m <- member_list(@members)} class="member" data-nick={m.nick}>
                <span class={[
                  "pfx",
                  if(m.op, do: "op"),
                  if(m.halfop, do: "halfop"),
                  if(m.voiced, do: "voice")
                ]}>
                  {cond do
                    m.op -> "@"
                    m.halfop -> "%"
                    m.voiced -> "+"
                    true -> ""
                  end}
                </span>
                <span class={"nick #{Render.nick_color_class(m.nick)}"}>{m.nick}</span>
              </div>
            <% end %>
          </div>
        </aside>
      </div>

      <%!-- Emoji reaction picker (centered overlay; freeq-web2 parity) --%>
      <div
        :if={@react_picker_msgid}
        id="react-picker-backdrop"
        class="react-picker-backdrop"
        phx-click="close_react_picker"
      >
      </div>
      <div
        :if={@react_picker_msgid}
        id="react-picker"
        class="open"
        role="menu"
        aria-label="React with emoji"
      >
        <button
          :for={emoji <- react_emojis()}
          type="button"
          phx-click="toggle_reaction"
          phx-value-msgid={@react_picker_msgid}
          phx-value-emoji={emoji}
        >
          {emoji}
        </button>
      </div>
    </div>
    """
  end
end
