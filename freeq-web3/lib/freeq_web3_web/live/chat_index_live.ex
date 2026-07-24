defmodule FreeqWeb3Web.ChatIndexLive do
  @moduledoc "GET /chat — channel list + sidebar (My Channels)."
  use FreeqWeb3Web, :live_view

  alias FreeqWeb3.Irc.Render
  alias FreeqWeb3.Rest
  alias FreeqWeb3.Session

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Session.subscribe(socket.assigns.freeq_session)
    end

    snap = Session.snapshot(socket.assigns.freeq_session)
    all = Rest.fetch_channels()

    {:ok,
     socket
     |> assign(:page_title, "channels")
     |> assign(:snap, snap)
     |> assign(:all_channels, all)
     |> assign(:my_channels, my_channel_entries(snap.channels, all))
     |> assign(:join_input, "")}
  end

  @impl true
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
    snap = Session.snapshot(socket.assigns.freeq_session)
    all = socket.assigns.all_channels

    {:noreply,
     socket
     |> assign(:snap, snap)
     |> assign(:my_channels, my_channel_entries(snap.channels, all))}
  end

  @impl true
  def handle_info({:channels_changed, channels}, socket) do
    all = socket.assigns.all_channels

    {:noreply,
     socket
     |> assign(:my_channels, my_channel_entries(channels, all))
     |> update(:snap, &Map.put(&1, :channels, channels))}
  end

  def handle_info({:ws_state, ws_state, nick}, socket) do
    snap =
      socket.assigns.snap
      |> Map.put(:ws_state, ws_state)
      |> Map.put(:current_nick, nick)

    {:noreply, assign(socket, :snap, snap)}
  end

  def handle_info({:auth_changed, auth}, socket) do
    snap =
      socket.assigns.snap
      |> Map.merge(auth)

    {:noreply, assign(socket, :snap, snap)}
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
        topic: meta["topic"] || meta[:topic] || "",
        members: meta["members"] || meta[:members] || 0
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="freeq-chat">
      <nav>
        <button
          type="button"
          class="mobile-btn"
          id="btn-channels"
          phx-click={
            JS.toggle_class("open", to: "#sidebar") |> JS.toggle_class("open", to: "#drawer-scrim")
          }
          aria-label="Channels"
        >
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16" /></svg>
        </button>
        <span class="brand">freeq</span>
        <span class="page-title nav-channel">channels</span>
        <div class="nav-right">
          <%= if @snap[:authenticated?] do %>
            <span class="auth-badge signed-in" title={@snap[:auth_did]}>
              🔒 {@snap[:auth_handle] || @snap.current_nick}
            </span>
          <% else %>
            <span class="auth-badge guest">guest · {@snap.current_nick || "…"}</span>
            <a href={~p"/login"} class="btn-link" style="margin-left:0.5rem">Sign in</a>
          <% end %>
        </div>
      </nav>

      <div
        id="drawer-scrim"
        phx-click={
          JS.remove_class("open", to: "#sidebar") |> JS.remove_class("open", to: "#drawer-scrim")
        }
        aria-hidden="true"
      >
      </div>

      <div class="chat-body">
        <.sidebar my_channels={@my_channels} all_channels={@all_channels} active={nil} snap={@snap} />

        <div class="channel-list-page">
          <form id="index-join-form" phx-submit="join">
            <input
              type="text"
              name="channel"
              placeholder="join #channel"
              autocomplete="off"
              value={@join_input}
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
                  data-phx-link="redirect"
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
      </div>
    </div>
    """
  end

  attr :my_channels, :list, required: true
  attr :all_channels, :list, required: true
  attr :active, :any, default: nil
  attr :snap, :map, required: true

  def sidebar(assigns) do
    ~H"""
    <aside id="sidebar">
      <p class="drawer-heading">Channels</p>
      <div class="sidebar-scroll">
        <form id="join-form" phx-submit="join">
          <input type="text" name="channel" placeholder="join #…" autocomplete="off" />
          <button type="submit">+</button>
        </form>
        <p class="sidebar-toggle"><span class="arrow">▾</span> MY CHANNELS</p>
        <ul id="my-channels">
          <li :for={ch <- @my_channels} class={if @active == ch.name, do: "active"}>
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
        <p class="sidebar-toggle collapsed"><span class="arrow">▸</span> ALL CHANNELS</p>
        <ul id="all-channels-sidebar">
          <li :for={ch <- Enum.take(@all_channels, 40)}>
            <% bare = Render.bare_channel(ch["name"] || "") %>
            <a
              href={~p"/chat/#{bare}"}
              class="channel-link"
              data-phx-link="redirect"
              data-phx-link-state="push"
            >
              <span class="channel-link-name">{ch["name"]}</span>
            </a>
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
          <span class="status-hint">{ws_label(@snap.ws_state)}</span>
          <%= if @snap[:authenticated?] do %>
            <a href={~p"/logout"} class="btn-link" data-method="get">Sign out</a>
          <% else %>
            <a href={~p"/login"} class="btn-link">Sign in</a>
          <% end %>
        </div>
      </div>
    </aside>
    """
  end

  defp ws_label(:ready), do: "connected"
  defp ws_label(:connecting), do: "connecting…"
  defp ws_label(:registering), do: "registering…"
  defp ws_label(_), do: "offline"
end
