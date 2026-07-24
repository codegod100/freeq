defmodule FreeqWeb3Web.ChatLive do
  @moduledoc "GET /chat/:channel — chat shell for a single channel."
  use FreeqWeb3Web, :live_view

  alias FreeqWeb3.Irc.Render
  alias FreeqWeb3.LinkPreview
  alias FreeqWeb3.Rest
  alias FreeqWeb3.Session

  @impl true
  def mount(%{"channel" => channel}, _session, socket) do
    ch = Render.canonical_channel(channel)
    bare = Render.bare_channel(ch)
    sid = socket.assigns.freeq_session

    if connected?(socket) do
      Session.subscribe(sid)
      Session.subscribe_channel(sid, ch)
    end

    # Explicit join intent (mirrors freeq-web2 chat#show).
    Session.add_channel(sid, ch)
    Session.ensure_upstream(sid, ch)

    snap = Session.snapshot(sid)
    all = Rest.fetch_channels()
    my = my_channel_entries(snap.channels, all)
    topic = topic_for(all, ch)

    history =
      case Rest.fetch_history(ch, 50, bearer: snap.api_bearer) do
        nil ->
          []

        rows ->
          # Server-side previews: download remote OG/YT images into local
          # cache so the page only loads same-origin /preview-cache/* URLs.
          LinkPreview.attach_many(rows, max_concurrency: 4, timeout: 6_000)
      end

    members = Session.members(sid, ch)

    socket =
      socket
      |> assign(:page_title, ch)
      |> assign(:channel, ch)
      |> assign(:bare, bare)
      |> assign(:snap, snap)
      |> assign(:topic, topic)
      |> assign(:all_channels, all)
      |> assign(:my_channels, my)
      |> assign(:members, members)
      |> assign(:compose, "")
      |> assign(:reply_to, nil)
      |> assign(:edit_to, nil)
      |> assign(:av_active, false)
      |> assign(:av_call_present, false)
      |> assign(:av_session_id, nil)
      |> assign(:av_participant_count, 0)
      |> assign(:av_muted, false)
      |> assign(:av_instance, generate_av_instance())
      |> stream(:messages, history, reset: true)
      |> assign(:message_count, length(history))

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"channel" => channel}, _uri, socket) do
    ch = Render.canonical_channel(channel)

    if ch == socket.assigns.channel do
      {:noreply, socket}
    else
      # Navigating between channels reuses the LiveView process when routed
      # under the same live_session — remount-like re-setup.
      bare = Render.bare_channel(ch)
      sid = socket.assigns.freeq_session
      Session.subscribe_channel(sid, ch)
      Session.add_channel(sid, ch)
      Session.ensure_upstream(sid, ch)

      snap = Session.snapshot(sid)
      all = socket.assigns.all_channels
      topic = topic_for(all, ch)
      history =
        (Rest.fetch_history(ch, 50, bearer: snap.api_bearer) || [])
        |> LinkPreview.attach_many(max_concurrency: 4, timeout: 6_000)

      members = Session.members(sid, ch)

      {:noreply,
       socket
       |> assign(:page_title, ch)
       |> assign(:channel, ch)
       |> assign(:bare, bare)
       |> assign(:snap, snap)
       |> assign(:topic, topic)
       |> assign(:my_channels, my_channel_entries(snap.channels, all))
       |> assign(:members, members)
       |> assign(:compose, "")
       |> assign(:reply_to, nil)
       |> assign(:edit_to, nil)
       |> assign(:av_active, false)
       |> assign(:av_call_present, false)
       |> assign(:av_session_id, nil)
       |> assign(:av_participant_count, 0)
       |> assign(:av_muted, false)
       |> assign(:av_instance, generate_av_instance())
       |> stream(:messages, history, reset: true)
       |> assign(:message_count, length(history))}
    end
  end

  @impl true
  def handle_event("send", %{"msg" => msg}, socket) do
    sid = socket.assigns.freeq_session
    ch = socket.assigns.channel

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
     |> assign(:edit_to, nil)}
  end

  def handle_event("join", %{"channel" => raw}, socket) do
    ch = raw |> to_string() |> String.trim()

    if ch == "" do
      {:noreply, socket}
    else
      Session.join(socket.assigns.freeq_session, ch)
      bare = Render.bare_channel(ch)
      {:noreply, push_navigate(socket, to: ~p"/chat/#{bare}")}
    end
  end

  def handle_event("part", %{"channel" => ch}, socket) do
    Session.part(socket.assigns.freeq_session, ch)

    if Render.canonical_channel(ch) == socket.assigns.channel do
      {:noreply, push_navigate(socket, to: ~p"/chat")}
    else
      snap = Session.snapshot(socket.assigns.freeq_session)

      {:noreply,
       socket
       |> assign(:snap, snap)
       |> assign(:my_channels, my_channel_entries(snap.channels, socket.assigns.all_channels))}
    end
  end

  def handle_event("set_topic", %{"topic" => topic}, socket) do
    Session.set_topic(socket.assigns.freeq_session, socket.assigns.channel, topic)
    {:noreply, assign(socket, :topic, topic)}
  end

  def handle_event("av_start", _params, socket) do
    sid = socket.assigns.freeq_session
    ch = socket.assigns.channel
    instance = socket.assigns.av_instance
    Session.av_start(sid, ch, instance)
    {:noreply, assign(socket, av_active: true)}
  end

  def handle_event("av_join", _params, socket) do
    sid = socket.assigns.freeq_session
    ch = socket.assigns.channel
    session_id_av = socket.assigns.av_session_id
    instance = socket.assigns.av_instance

    if session_id_av do
      Session.av_join(sid, ch, session_id_av, instance)
      {:noreply, assign(socket, av_active: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("av_leave", _params, socket) do
    sid = socket.assigns.freeq_session
    ch = socket.assigns.channel
    session_id_av = socket.assigns.av_session_id
    instance = socket.assigns.av_instance

    if session_id_av do
      Session.av_leave(sid, ch, session_id_av, instance)
    end

    {:noreply,
     socket
     |> assign(:av_active, false)
     |> assign(:av_call_present, false)
     |> assign(:av_session_id, nil)
     |> assign(:av_participant_count, 0)
     |> push_event("av_left", %{})}
  end

  def handle_event("av_toggle_mute", _params, socket) do
    muted = not socket.assigns.av_muted
    {:noreply, socket |> assign(:av_muted, muted) |> push_event("av_muted", %{muted: muted})}
  end

  def handle_event("reply", %{"msgid" => msgid}, socket) do
    {:noreply, assign(socket, reply_to: msgid, edit_to: nil)}
  end

  def handle_event("edit", %{"msgid" => msgid}, socket) do
    {:noreply, assign(socket, edit_to: msgid, reply_to: nil)}
  end

  def handle_event("cancel_reply", _, socket) do
    {:noreply, assign(socket, reply_to: nil, edit_to: nil)}
  end

  def handle_event("compose_change", %{"msg" => msg}, socket) do
    {:noreply, assign(socket, :compose, msg)}
  end

  @impl true
  def handle_info({:message, row}, socket) do
    # Prefer cache-only for the first paint; resolve+download off the LV process.
    row_fast = LinkPreview.attach_cache_only(row)

    socket =
      socket
      |> stream_insert(:messages, row_fast, at: -1)
      |> assign(:message_count, socket.assigns.message_count + 1)
      |> push_event("scroll_bottom", %{})

    if row_fast.kind == :msg and is_nil(row_fast[:embed]) and is_binary(row_fast[:text]) do
      lv = self()

      Task.start(fn ->
        full = LinkPreview.attach(row)

        if full[:embed] do
          send(lv, {:message_embed, full})
        end
      end)
    end

    {:noreply, socket}
  end

  def handle_info({:message_embed, row}, socket) do
    # Update the existing stream row with a fully resolved local preview.
    {:noreply, stream_insert(socket, :messages, row, at: -1)}
  end

  def handle_info({:av_state, %{channel: ch} = av}, socket) do
    if String.downcase(Render.canonical_channel(ch)) ==
         String.downcase(Render.canonical_channel(socket.assigns.channel)) do
      state = String.downcase(to_string(av.state))

      socket =
        cond do
          state in ["started", "joined"] ->
            socket
            |> assign(:av_call_present, true)
            |> assign(:av_session_id, av.session_id)
            |> assign(:av_participant_count, av.participants || 0)
            |> push_event("av_state", %{
              channel: ch,
              state: av.state,
              session_id: av.session_id,
              participants: av.participants || 0,
              actor: av.actor,
              instance: av.instance
            })

          state == "ended" ->
            socket
            |> assign(:av_active, false)
            |> assign(:av_call_present, false)
            |> assign(:av_session_id, nil)
            |> assign(:av_participant_count, 0)
            |> push_event("av_ended", %{session_id: av.session_id})

          true ->
            socket
        end

      {:noreply, socket}
    else
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

    {:noreply, assign(socket, :snap, snap)}
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

  defp format_ts(%DateTime{} = t), do: Calendar.strftime(t, "%H:%M")
  defp format_ts(_), do: ""

  # CSS class for a message row. Prefer web2 names (msg/join/part/notice).
  defp msg_row_class(:msg), do: "msg"
  defp msg_row_class(:join), do: "join"
  defp msg_row_class(:part), do: "part"
  defp msg_row_class(:notice), do: "notice"
  defp msg_row_class(_), do: "notice"

  attr :msg, :map, required: true

  defp message_body(assigns) do
    ~H"""
    <span class="body"><%= if @msg.kind == :msg do %>
      <span class={["nick", @msg[:color] || "n1"]}>{@msg.nick}</span>{" "}{@msg.text}<button
        :if={@msg[:msgid]}
        type="button"
        class="reply-btn"
        title="Reply"
        phx-click="reply"
        phx-value-msgid={@msg.msgid}
      >↩</button>
    <% else %>
      <%= if @msg.kind in [:join, :part] do %>
        — {@msg.nick} {@msg.text}
      <% else %>
        {@msg.text}
      <% end %>
    <% end %></span>
    """
  end

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
    <div id="freeq-chat" phx-hook="ChatScroll" data-channel={@bare}>
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
        <span class="nav-channel">{@channel}</span>
        <span id="channel-topic" title="Channel topic">{@topic || "add topic"}</span>
        <div class="nav-right">
          <span id="status" class={if @snap.ws_state == :ready, do: "connected"}>
            <span class="dot"></span>
            <span>{ws_label(@snap.ws_state)}</span>
          </span>
          <button
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
            disabled={not @snap[:authenticated?] and not @av_active and not @av_call_present}
            data-channel={@channel}
            data-nick={@snap.current_nick}
            data-instance={@av_instance}
            data-active={@av_active}
            title={
              cond do
                @av_active -> "In call — click to leave"
                @av_call_present -> "Join call (#{@av_participant_count || 0})"
                @snap[:authenticated?] -> "Start voice call"
                true -> "Sign in to start a call"
              end
            }
          >
            {if(@av_active, do: "📞", else: if(@av_call_present, do: "🔊", else: "🎙️"))}
          </button>
          <button
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
                <a
                  href={~p"/chat/#{ch.bare}"}
                  class="channel-link"
                  data-phx-link="redirect"
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
              <a href={~p"/chat"} class="btn-link" data-phx-link="redirect" data-phx-link-state="push">
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
          <div id="messages" phx-update="stream">
            <div
              :for={{dom_id, msg} <- @streams.messages}
              id={dom_id}
              class={msg_row_class(msg.kind)}
              data-msgid={msg[:msgid]}
              data-nick={msg[:nick]}
              data-text={msg[:text]}
            >
              <span class="ts">{format_ts(msg.time)}</span>
              <.message_body msg={msg} />
              <.link_embed :if={msg[:embed]} embed={msg.embed} />
            </div>
          </div>

          <div
            :if={@av_active}
            id="av-call-panel"
            class="av-call-panel active"
            phx-hook="AvCall"
            data-channel={@channel}
            data-nick={@snap.current_nick}
            data-instance={@av_instance}
            data-session-id={@av_session_id}
            data-muted={@av_muted}
            data-authenticated={@snap[:authenticated?]}
          >
            <div class="av-call-bar">
              <span class="av-call-status">
                📞 {@channel} · {@av_participant_count || 1} in call
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
                  class="av-call-action av-leave-btn"
                  phx-click="av_leave"
                  title="Leave call"
                >
                  Leave
                </button>
              </div>
            </div>
            <div id="av-publish-container" phx-update="ignore"></div>
            <div id="av-remote-tiles" phx-update="ignore"></div>
          </div>

          <div :if={@reply_to || @edit_to} id="reply-banner" class="reply-banner">
            <span class="reply-banner-label">{if(@edit_to, do: "Editing", else: "Replying")}</span>
            <span class="reply-banner-text">{@reply_to || @edit_to}</span>
            <button type="button" class="reply-banner-cancel" phx-click="cancel_reply">×</button>
          </div>

          <div id="send-bar">
            <form id="send-form" phx-submit="send" phx-change="compose_change">
              <input
                id="message-input"
                type="text"
                name="msg"
                value={@compose}
                placeholder={"Message #{@channel}"}
                autocomplete="off"
                phx-mounted={JS.focus()}
              />
              <button type="submit">Send</button>
            </form>
          </div>
        </section>

        <aside id="member-panel">
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
    </div>
    """
  end
end
