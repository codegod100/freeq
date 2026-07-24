defmodule FreeqWeb3 do
  @moduledoc """
  freeq-web3 — Phoenix LiveView BFF port of freeq-web2.

  Architecture (same as freeq-web2 / freeq-webui):

      browser  ◀── LiveView / PubSub ──▶  freeq-web3  ◀── WS /irc ──▶  freeq-server
                                         (Phoenix)      REST /api/v1

  One upstream IRC WebSocket per browser session. The LiveView never opens
  `/irc` directly; mutations enqueue outbound IRC lines on the session
  GenServer, and inbound lines are pubsub'd back to subscribed LiveViews.
  """

  @doc "Upstream IRC WebSocket URL."
  def upstream_ws do
    Application.get_env(:freeq_web3, :upstream_ws, "wss://irc.freeq.at/irc")
  end

  @doc "Upstream freeq-server REST base URL."
  def upstream_rest do
    Application.get_env(:freeq_web3, :upstream_rest, "https://irc.freeq.at")
  end
end
