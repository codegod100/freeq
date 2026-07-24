defmodule FreeqWeb3.Session do
  @moduledoc """
  Public API for browser-session IRC state.

  One `Session.Server` GenServer per `freeq_session` cookie. LiveViews call
  into this module; they never hold the upstream WebSocket.
  """

  alias FreeqWeb3.Session.Supervisor

  @doc "Get or start the session process for `session_id`."
  def get_or_start(session_id) when is_binary(session_id) do
    case Registry.lookup(FreeqWeb3.Session.Registry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case Supervisor.start_session(session_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  def via(session_id), do: {:via, Registry, {FreeqWeb3.Session.Registry, session_id}}

  def snapshot(session_id), do: GenServer.call(via(session_id), :snapshot)
  def enqueue(session_id, line), do: GenServer.cast(via(session_id), {:enqueue, line})

  def ensure_upstream(session_id, channel) do
    GenServer.cast(via(session_id), {:ensure_upstream, channel})
  end

  def add_channel(session_id, channel) do
    GenServer.call(via(session_id), {:add_channel, channel})
  end

  def remove_channel(session_id, channel) do
    GenServer.call(via(session_id), {:remove_channel, channel})
  end

  def join(session_id, channel) do
    GenServer.call(via(session_id), {:join, channel})
  end

  def part(session_id, channel) do
    GenServer.call(via(session_id), {:part, channel})
  end

  def send_message(session_id, target, text, opts \\ []) do
    GenServer.call(via(session_id), {:send_message, target, text, opts})
  end

  @doc """
  Toggle a reaction on a message via IRCv3 TAGMSG.

  `added: true` → `+react=<emoji>;+reply=<msgid>`
  `added: false` → `+freeq.at/unreact=<emoji>;+reply=<msgid>`

  Optimistically broadcasts `{:reaction, msgid, emoji, nick, added}` on the
  channel topic so the clicker sees the chip without waiting for the echo.
  """
  def react(session_id, channel, msgid, emoji, added?) when is_boolean(added?) do
    GenServer.call(via(session_id), {:react, channel, msgid, emoji, added?})
  end

  def set_topic(session_id, channel, topic) do
    GenServer.call(via(session_id), {:set_topic, channel, topic})
  end

  def members(session_id, channel) do
    GenServer.call(via(session_id), {:members, channel})
  end

  @doc "Install OAuth credentials (does not mark authenticated until SASL)."
  def set_auth(session_id, oauth) do
    GenServer.call(via(session_id), {:set_auth, oauth})
  end

  @doc "Clear credentials and drop to guest (reconnects upstream)."
  def clear_auth(session_id) do
    GenServer.call(via(session_id), :clear_auth, 15_000)
  end

  @doc """
  Force upstream reconnect so SASL re-runs with current credentials.
  Blocks until the session has processed the reconnect kickoff.
  """
  def request_reconnect(session_id) do
    GenServer.call(via(session_id), :request_reconnect, 15_000)
  end

  @doc """
  Drive SASL until app identity is real (API-BEARER). Returns true on success.
  """
  def ensure_authenticated(session_id, timeout_ms \\ 15_000) do
    GenServer.call(via(session_id), {:ensure_authenticated, timeout_ms}, timeout_ms + 5_000)
  end

  def av_start(session_id, channel, instance, opts \\ []) do
    GenServer.call(via(session_id), {:av_start, channel, instance, opts})
  end

  def av_join(session_id, channel, session_id_av, instance) do
    GenServer.call(via(session_id), {:av_join, channel, session_id_av, instance})
  end

  def av_leave(session_id, channel, session_id_av, instance) do
    GenServer.call(via(session_id), {:av_leave, channel, session_id_av, instance})
  end

  def av_end(session_id, channel, session_id_av) do
    GenServer.call(via(session_id), {:av_end, channel, session_id_av})
  end

  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(FreeqWeb3.PubSub, topic(session_id))
  end

  def subscribe_channel(session_id, channel) do
    Phoenix.PubSub.subscribe(FreeqWeb3.PubSub, channel_topic(session_id, channel))
  end

  def topic(session_id), do: "session:#{session_id}"

  def channel_topic(session_id, channel) do
    bare = FreeqWeb3.Irc.Render.bare_channel(channel) |> String.downcase()
    "session:#{session_id}:channel:#{bare}"
  end

  def broadcast(session_id, message) do
    Phoenix.PubSub.broadcast(FreeqWeb3.PubSub, topic(session_id), message)
  end

  def broadcast_channel(session_id, channel, message) do
    Phoenix.PubSub.broadcast(FreeqWeb3.PubSub, channel_topic(session_id, channel), message)
  end
end
