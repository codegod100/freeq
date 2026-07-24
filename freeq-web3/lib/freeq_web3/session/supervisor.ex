defmodule FreeqWeb3.Session.Supervisor do
  @moduledoc "DynamicSupervisor for per-browser Session GenServers."
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(session_id) when is_binary(session_id) do
    spec = {FreeqWeb3.Session.Server, session_id: session_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
