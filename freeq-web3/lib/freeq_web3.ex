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

  @doc """
  HTTP(S) origin of freeq-server for MoQ media (`/av/moq`).

  The Phoenix BFF does not terminate MoQ WebSockets; the browser dials the
  freeq-server origin directly (prod nginx may still same-origin proxy).
  """
  def av_origin do
    case System.get_env("FREEQ_AV_ORIGIN") do
      origin when is_binary(origin) and origin != "" ->
        String.trim_trailing(origin, "/")

      _ ->
        case URI.parse(upstream_rest()) do
          %URI{scheme: scheme, host: host} = uri when is_binary(host) and host != "" ->
            scheme = scheme || "https"
            port = uri.port

            port_suffix =
              cond do
                is_nil(port) -> ""
                scheme == "https" and port == 443 -> ""
                scheme == "http" and port == 80 -> ""
                true -> ":#{port}"
              end

            "#{scheme}://#{host}#{port_suffix}"

          _ ->
            ""
        end
    end
  end
end
