defmodule FreeqWeb3Web.ApiController do
  @moduledoc """
  Same-origin BFF proxy for AV call control and static AV assets.

  AV signaling is enqueued as IRC TAGMSG on the session GenServer;
  token/session REST endpoints proxy to freeq-server.
  """

  use FreeqWeb3Web, :controller

  alias FreeqWeb3.Rest
  alias FreeqWeb3.Session

  def av_start(conn, %{"channel" => channel, "instance" => instance} = params) do
    sid = session_id(conn)
    title = Map.get(params, "title", "")
    :ok = Session.av_start(sid, channel, instance, title: title)
    json(conn, %{ok: true})
  end

  def av_join(conn, %{"channel" => channel, "session_id" => session_id_av, "instance" => instance}) do
    sid = session_id(conn)
    :ok = Session.av_join(sid, channel, session_id_av, instance)
    json(conn, %{ok: true})
  end

  def av_leave(conn, %{"channel" => channel, "session_id" => session_id_av} = params) do
    sid = session_id(conn)
    instance = Map.get(params, "instance", "")
    :ok = Session.av_leave(sid, channel, session_id_av, instance)
    json(conn, %{ok: true})
  end

  def av_end(conn, %{"channel" => channel, "session_id" => session_id_av}) do
    sid = session_id(conn)
    :ok = Session.av_end(sid, channel, session_id_av)
    json(conn, %{ok: true})
  end

  def channel_sessions(conn, %{"channel" => channel}) do
    json(conn, Rest.fetch_channel_sessions(channel) || %{})
  end

  def session_detail(conn, %{"id" => id}) do
    json(conn, Rest.fetch_session_detail(id) || %{})
  end

  def av_token(conn, %{"id" => id}) do
    sid = session_id(conn)

    # REST token requires SASL API-BEARER + DID participant. Guests always
    # get tokens via IRC +freeq.at/av-token TAGMSG (no REST). Don't block
    # long waiting for a bearer that will never come for guests.
    bearer =
      case Session.get_or_start(sid) do
        {:ok, _} ->
          snap = Session.snapshot(sid)
          snap.api_bearer

        _ ->
          nil
      end

    if bearer in [nil, ""] do
      conn
      |> put_status(:unauthorized)
      |> json(%{
        error: "guest — use +freeq.at/av-token TAGMSG (REST needs SASL)",
        guest: true
      })
    else
      case Rest.fetch_av_token(id, bearer) do
        nil ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "upstream refused token"})

        token when is_binary(token) ->
          json(conn, %{token: token})
      end
    end
  end

  # GET /api/v1/og?url= — same-origin proxy to freeq-server (SSRF-safe there).
  # Used by client-side link embeds in the channel message pane.
  def og_preview(conn, params) do
    url =
      (params["url"] || "")
      |> to_string()
      # Strip zero-width / bidi paste noise (U+200B..U+200D, FEFF, 2060, soft hyphen).
      |> String.replace(~r/[\x{200B}-\x{200D}\x{FEFF}\x{2060}\x{00AD}]/u, "")
      |> String.trim()
      |> String.trim_leading("<")
      |> String.trim_trailing(">")

    cond do
      url == "" ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "url required"})

      not Regex.match?(~r/\Ahttps?:\/\//i, url) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid URL"})

      true ->
        case Rest.fetch_og(url) do
          nil ->
            conn
            |> put_status(:bad_gateway)
            |> json(%{error: "Fetch failed"})

          body when is_map(body) ->
            json(conn, body)
        end
    end
  end

  def av_asset(conn, %{"path" => path}) do
    upstream = FreeqWeb3.upstream_rest()
    url = "#{upstream}/av/assets/#{Enum.join(path, "/")}"

    case Req.get(url, receive_timeout: 10_000, connect_options: [timeout: 5_000]) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type =
          headers
          |> Map.get("content-type", [])
          |> List.first() ||
            if String.ends_with?(List.last(path) || "", ".js"),
              do: "application/javascript",
              else: "application/octet-stream"

        conn
        |> put_resp_content_type(content_type)
        |> send_resp(200, body)

      {:ok, %{status: status}} ->
        send_resp(conn, status, "")

      {:error, _reason} ->
        send_resp(conn, 502, "")
    end
  end

  defp session_id(conn) do
    get_session(conn, :freeq_session) || ""
  end
end
