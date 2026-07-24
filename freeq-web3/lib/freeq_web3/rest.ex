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

  @doc """
  GET /api/v1/channels/:name/topic → topic text or nil.

  The public `/api/v1/channels` list omits +i/+k/policy channels, so their
  topics never appear there. This per-channel endpoint still returns the
  topic (used when opening a private channel the user has already joined).
  """
  def fetch_channel_topic(channel) do
    ch = Render.canonical_channel(channel)
    encoded = URI.encode(ch, &(&1 != ?# and URI.char_unreserved?(&1)))
    url = FreeqWeb3.upstream_rest() <> "/api/v1/channels/#{encoded}/topic"

    case Req.get(url, receive_timeout: 5_000, connect_options: [timeout: 3_000]) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        case body["topic"] || body[:topic] do
          t when is_binary(t) and t != "" -> t
          _ -> nil
        end

      {:ok, %{status: 404}} ->
        nil

      {:ok, %{status: status}} ->
        Logger.debug("fetch_channel_topic #{ch}: HTTP #{status}")
        nil

      {:error, reason} ->
        Logger.warning("fetch_channel_topic failed: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  GET /api/v1/channels/:name/sessions

  freeq-server indexes sessions by the IRC channel name **with** `#`
  (lowercased). Always send the canonical form.
  """
  def fetch_channel_sessions(channel) do
    ch = Render.canonical_channel(channel)
    # Path segment: encode # as %23 so it isn't treated as a fragment.
    encoded = URI.encode(ch, &(&1 != ?# and URI.char_unreserved?(&1)))
    url = FreeqWeb3.upstream_rest() <> "/api/v1/channels/#{encoded}/sessions"

    case Req.get(url, receive_timeout: 5_000, connect_options: [timeout: 3_000]) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        body

      {:ok, %{status: status}} ->
        Logger.warning("fetch_channel_sessions HTTP #{status} for #{ch}")
        nil

      {:error, reason} ->
        Logger.warning("fetch_channel_sessions failed: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Extract active call info from a channel sessions payload.

  Returns `%{session_id, participant_count, title}` or `nil`.
  """
  def active_call_from_sessions(nil), do: nil

  def active_call_from_sessions(data) when is_map(data) do
    active = data["active"] || data[:active]
    if is_map(active) and active_call_state?(active) do
      %{
        session_id: active["id"] || active[:id],
        participant_count:
          active["participant_count"] || active[:participant_count] ||
            length(active["participants"] || active[:participants] || []),
        title: active["title"] || active[:title]
      }
    end
  end

  def active_call_from_sessions(_), do: nil

  defp active_call_state?(active) do
    state = to_string(active["state"] || active[:state] || "")
    String.downcase(state) in ["active", "started"]
  end


  @doc "GET /api/v1/sessions/:id"
  def fetch_session_detail(session_id) do
    url = FreeqWeb3.upstream_rest() <> "/api/v1/sessions/#{URI.encode_www_form(session_id)}"

    case Req.get(url, receive_timeout: 5_000, connect_options: [timeout: 3_000]) do
      {:ok, %{status: 200, body: body}} ->
        body

      {:ok, %{status: status}} ->
        Logger.warning("fetch_session_detail HTTP #{status}")
        nil

      {:error, reason} ->
        Logger.warning("fetch_session_detail failed: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  GET /api/v1/og?url= — OpenGraph preview (SSRF-safe on freeq-server).

  Returns a map (`title`, `description`, `image`, `site_name`) or `nil`.
  """
  def fetch_og(url) when is_binary(url) do
    encoded = URI.encode_www_form(url)
    endpoint = FreeqWeb3.upstream_rest() <> "/api/v1/og?url=#{encoded}"

    case Req.get(endpoint, receive_timeout: 10_000, connect_options: [timeout: 5_000]) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        body

      {:ok, %{status: status, body: body}} ->
        Logger.info("fetch_og HTTP #{status}: #{inspect(body) |> String.slice(0, 120)}")
        nil

      {:error, reason} ->
        Logger.warning("fetch_og failed: #{inspect(reason)}")
        nil
    end
  end

  def fetch_og(_), do: nil

  @doc "GET /api/v1/av/sessions/:id/token"
  def fetch_av_token(session_id, bearer) do
    url =
      FreeqWeb3.upstream_rest() <> "/api/v1/av/sessions/#{URI.encode_www_form(session_id)}/token"

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
      {:ok, %{status: 200, body: body}} ->
        body["token"]

      {:ok, %{status: status}} ->
        Logger.warning("fetch_av_token HTTP #{status}")
        nil

      {:error, reason} ->
        Logger.warning("fetch_av_token failed: #{inspect(reason)}")
        nil
    end
  end
end
