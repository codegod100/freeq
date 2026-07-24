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

  def set_topic(session_id, channel, topic) do
    GenServer.call(via(session_id), {:set_topic, channel, topic})
  end

  def members(session_id, channel) do
    GenServer.call(via(session_id), {:members, channel})
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
