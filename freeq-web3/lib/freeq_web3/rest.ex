defmodule FreeqWeb3.Rest do
  @moduledoc """
  Thin client for freeq-server REST (`/api/v1/...`).

  Mirrors freeq-web2 `SessionRegistry#fetch_channels` / `#fetch_history`.
  """

  require Logger

  alias FreeqWeb3.Irc.Render

  @doc "GET /api/v1/channels → list of channel maps."
  def fetch_channels do
    url = FreeqWeb3.upstream_rest() <> "/api/v1/channels"

    case Req.get(url, receive_timeout: 5_000, connect_options: [timeout: 3_000]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        body

      {:ok, %{status: status}} ->
        Logger.warning("fetch_channels HTTP #{status}")
        []

      {:error, reason} ->
        Logger.warning("fetch_channels failed: #{inspect(reason)}")
        []
    end
  end

  @doc """
  GET /api/v1/channels/:name/history?limit=

  Pass `bearer:` (IRC session_id from API-BEARER) for restricted channels.
  Returns a list of history row maps, or `nil` on failure (caller may fall
  back to JOIN chathistory replay).
  """
  def fetch_history(channel, limit \\ 50, opts \\ []) do
    bearer = Keyword.get(opts, :bearer)
    retries = Keyword.get(opts, :retries, if(bearer in [nil, ""], do: 0, else: 4))
    do_fetch_history(channel, limit, bearer, retries, 0)
  end

  defp do_fetch_history(channel, limit, bearer, retries, attempt) do
    case fetch_history_once(channel, limit, bearer) do
      {:ok, rows} ->
        rows

      :error ->
        if attempt >= retries do
          nil
        else
          Process.sleep(trunc(350 * (attempt + 1)))
          do_fetch_history(channel, limit, bearer, retries, attempt + 1)
        end
    end
  end

  defp fetch_history_once(channel, limit, bearer) do
    bare = Render.bare_channel(channel)
    encoded = URI.encode_www_form(bare)
    url = FreeqWeb3.upstream_rest() <> "/api/v1/channels/#{encoded}/history?limit=#{limit}"

    headers =
      if bearer not in [nil, ""] do
        [{"authorization", "Bearer #{bearer}"}]
      else
        []
      end

    case Req.get(url,
           headers: headers,
           receive_timeout: 5_000,
           connect_options: [timeout: 3_000]
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, Enum.map(body, &Render.history_row/1)}

      {:ok, %{status: status}} ->
        Logger.info(
          "fetch_history #{channel}: HTTP #{status}" <>
            if(bearer in [nil, ""], do: " (anonymous)", else: " (authed)")
        )

        :error

      {:error, reason} ->
        Logger.warning("fetch_history failed: #{inspect(reason)}")
        :error
    end
  end
end
