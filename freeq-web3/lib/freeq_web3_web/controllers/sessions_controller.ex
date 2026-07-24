defmodule FreeqWeb3Web.SessionsController do
  @moduledoc """
  AT Protocol OAuth login: form, start, callback, logout, client metadata.

  Port of freeq-web2 `SessionsController`.
  """

  use FreeqWeb3Web, :controller

  require Logger

  alias FreeqWeb3.Atproto.OAuth
  alias FreeqWeb3.PendingOauthStore
  alias FreeqWeb3.Session

  # GET /login
  def new(conn, _params) do
    sid = freeq_session_id(conn)
    {:ok, _} = Session.get_or_start(sid)
    snap = Session.snapshot(sid)

    cond do
      snap.authenticated? ->
        conn
        |> put_flash(:info, "Signed in as #{snap.auth_handle}")
        |> redirect(to: ~p"/chat")

      snap.has_credentials? ->
        # Credentials without SASL: keep trying.
        ok = Session.ensure_authenticated(sid, 10_000)
        snap = Session.snapshot(sid)

        if ok or snap.authenticated? do
          conn
          |> put_flash(:info, "Signed in as #{snap.auth_handle}")
          |> redirect(to: ~p"/chat")
        else
          render(conn, :new, page_title: "Sign in")
        end

      true ->
        render(conn, :new, page_title: "Sign in")
    end
  end

  # GET /login/start | POST /login
  def create(conn, params) do
    handle =
      (params["identifier"] || "")
      |> to_string()
      |> String.trim()
      |> String.trim_leading("@")

    if handle == "" do
      conn
      |> put_flash(:error, "Handle is required")
      |> redirect(to: ~p"/login")
    else
      public_url = public_url(conn)
      sid = freeq_session_id(conn)
      {:ok, _} = Session.get_or_start(sid)

      case OAuth.prepare(handle, public_url) do
        {:ok, prepared} ->
          payload = %{
            "handle" => prepared.handle,
            "did" => prepared.did,
            "pds_url" => prepared.pds_url,
            "token_endpoint" => prepared.token_endpoint,
            "redirect_uri" => prepared.redirect_uri,
            "client_id" => prepared.client_id,
            "code_verifier" => prepared.code_verifier,
            "dpop_key" => FreeqWeb3.Atproto.DpopKey.serialize(prepared.dpop_key),
            "state" => prepared.state,
            "freeq_session_id" => sid
          }

          PendingOauthStore.save(prepared.state, payload)
          PendingOauthStore.gc!()

          Logger.info(
            "OAuth start handle=#{prepared.handle} sid=#{String.slice(sid, 0, 8)} " <>
              "state=#{String.slice(prepared.state, 0, 12)}"
          )

          redirect(conn, external: prepared.auth_url)

        {:error, reason} ->
          Logger.warning("OAuth prepare failed: #{inspect(reason)}")

          conn
          |> put_flash(:error, "Login failed: #{reason}")
          |> redirect(to: ~p"/login")
      end
    end
  end

  # GET|POST /auth/callback
  def callback(conn, params) do
    code = params["code"]
    state = to_string(params["state"] || "")
    error = params["error"]

    cond do
      error not in [nil, ""] ->
        if state != "", do: PendingOauthStore.remove(state)

        conn
        |> put_flash(:error, "OAuth error: #{error}")
        |> redirect(to: ~p"/login")

      code in [nil, ""] or state == "" ->
        conn
        |> put_flash(:error, "OAuth callback missing code or state.")
        |> redirect(to: ~p"/login")

      true ->
        complete_callback(conn, code, state)
    end
  end

  # GET|POST /logout
  def destroy(conn, _params) do
    sid = freeq_session_id(conn)

    case Session.get_or_start(sid) do
      {:ok, _} ->
        Session.clear_auth(sid)

      _ ->
        :ok
    end

    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out")
    |> redirect(to: ~p"/chat")
  end

  # GET /.well-known/oauth-client-metadata
  def client_metadata(conn, _params) do
    public = public_url(conn)

    json(conn, %{
      client_id: String.trim_trailing(public, "/") <> "/.well-known/oauth-client-metadata",
      client_name: "freeq-web3",
      redirect_uris: [String.trim_trailing(public, "/") <> "/auth/callback"],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      scope: "atproto transition:generic",
      token_endpoint_auth_method: "none",
      application_type: "web",
      dpop_bound_access_tokens: true
    })
  end

  defp complete_callback(conn, code, state) do
    data = PendingOauthStore.take(state)

    if not is_map(data) or data["code_verifier"] in [nil, ""] do
      Logger.warning("OAuth callback: no pending for state=#{String.slice(state, 0, 12)}")

      conn
      |> put_flash(:error, "No pending login. Please try again.")
      |> redirect(to: ~p"/login")
    else
      try do
        prepared = OAuth.prepared_from_pending(data)

        case OAuth.complete(prepared, code) do
          {:ok, oauth_session} ->
            sid =
              case data["freeq_session_id"] do
                id when is_binary(id) and id != "" -> id
                _ -> freeq_session_id(conn)
              end

            conn = put_session(conn, :freeq_session, sid)
            {:ok, _} = Session.get_or_start(sid)
            Session.set_auth(sid, oauth_session)

            ok =
              try do
                Session.request_reconnect(sid)
                Session.ensure_authenticated(sid, 15_000)
              rescue
                e ->
                  Logger.warning("SASL after login failed: #{Exception.message(e)}")
                  false
              end

            snap = Session.snapshot(sid)

            Logger.info(
              "OAuth+SASL handle=#{oauth_session.handle} sid=#{String.slice(sid, 0, 8)} " <>
                "sasl=#{ok} status=#{snap.sasl_status} bearer=#{snap.api_bearer not in [nil, ""]}"
            )

            if ok or snap.authenticated? do
              conn
              |> put_flash(:info, "Signed in as #{oauth_session.handle}")
              |> redirect(to: ~p"/chat")
            else
              conn
              |> put_flash(
                :error,
                "OAuth ok for #{oauth_session.handle}, but IRC SASL did not finish. " <>
                  "Wait a moment or sign out and try again."
              )
              |> redirect(to: ~p"/chat")
            end

          {:error, reason} ->
            Logger.warning("OAuth complete failed: #{inspect(reason)}")

            conn
            |> put_flash(:error, "Login failed: #{reason}")
            |> redirect(to: ~p"/login")
        end
      rescue
        e ->
          Logger.warning("OAuth callback FAILED: #{Exception.message(e)}")

          conn
          |> put_flash(:error, "Login failed: #{Exception.message(e)}")
          |> redirect(to: ~p"/login")
      end
    end
  end

  defp freeq_session_id(conn) do
    case get_session(conn, :freeq_session) do
      id when is_binary(id) and id != "" -> id
      _ -> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    end
  end

  defp public_url(conn) do
    case System.get_env("FREEQ_PUBLIC_URL") do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        # Phoenix endpoint URL — prefer configured host when set.
        "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}"
    end
  end

  defp port_suffix(conn) do
    case {conn.scheme, conn.port} do
      {:http, 80} -> ""
      {:https, 443} -> ""
      {_, port} -> ":#{port}"
    end
  end
end
