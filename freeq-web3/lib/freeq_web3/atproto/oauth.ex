defmodule FreeqWeb3.Atproto.OAuth do
  @moduledoc """
  AT Protocol OAuth flow: handle resolution → auth server discovery → PAR →
  token exchange. Mirrors freeq-web2 `Atproto::OAuth` / freeq-webui oauth_flow.
  """

  require Logger

  alias FreeqWeb3.Atproto.DpopKey
  alias FreeqWeb3.Atproto.OAuthSession

  defmodule PreparedLogin do
    @moduledoc "In-flight OAuth login — everything needed for callback completion."
    defstruct [
      :auth_url,
      :state,
      :redirect_uri,
      :client_id,
      :code_verifier,
      :token_endpoint,
      :pds_url,
      :dpop_key,
      :did,
      :handle
    ]

    @type t :: %__MODULE__{}
  end

  @doc """
  Start OAuth for a handle. Returns `{:ok, PreparedLogin.t()}` or `{:error, reason}`.
  """
  def prepare(handle, public_url) when is_binary(handle) and is_binary(public_url) do
    handle = handle |> String.trim() |> String.trim_leading("@")

    with {:ok, did, pds_url} <- resolve_identity(handle),
         {:ok, auth_meta} <- discover_auth_server(pds_url) do
      redirect_uri = String.trim_trailing(public_url, "/") <> "/auth/callback"

      client_id =
        if String.match?(public_url, ~r/localhost|127\.0\.0\.1/) do
          scope = "atproto transition:generic"

          "http://localhost?redirect_uri=#{urlencode(redirect_uri)}&scope=#{urlencode(scope)}"
        else
          String.trim_trailing(public_url, "/") <> "/.well-known/oauth-client-metadata"
        end

      {code_verifier, code_challenge} = generate_pkce()
      dpop_key = DpopKey.generate()
      state = b64url(:crypto.strong_rand_bytes(16))

      par_endpoint = auth_meta["pushed_authorization_request_endpoint"]

      if is_nil(par_endpoint) or par_endpoint == "" do
        {:error, "Authorization server does not support PAR"}
      else
        case push_authorization_request(
               par_endpoint,
               auth_meta["authorization_endpoint"],
               client_id,
               redirect_uri,
               code_challenge,
               state,
               handle,
               dpop_key
             ) do
          {:ok, auth_url} ->
            {:ok,
             %PreparedLogin{
               handle: handle,
               did: did,
               pds_url: pds_url,
               token_endpoint: auth_meta["token_endpoint"],
               redirect_uri: redirect_uri,
               client_id: client_id,
               code_verifier: code_verifier,
               dpop_key: dpop_key,
               state: state,
               auth_url: auth_url
             }}

          {:error, _} = err ->
            err
        end
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Complete token exchange after the OAuth callback. Returns `{:ok, OAuthSession.t()}`."
  def complete(%PreparedLogin{} = prepared, auth_code) when is_binary(auth_code) do
    with {:ok, tokens} <-
           exchange_code(
             prepared.token_endpoint,
             auth_code,
             prepared.code_verifier,
             prepared.redirect_uri,
             prepared.client_id,
             prepared.dpop_key
           ) do
      token_did = tokens[:sub]

      if token_did && token_did != prepared.did do
        {:error, "DID mismatch: resolved #{prepared.did} but token is for #{token_did}"}
      else
        dpop_nonce =
          probe_dpop_nonce(prepared.pds_url, tokens[:access_token], prepared.dpop_key)

        session = %OAuthSession{
          did: prepared.did,
          handle: prepared.handle,
          access_token: tokens[:access_token],
          pds_url: prepared.pds_url,
          dpop_key: prepared.dpop_key,
          dpop_nonce: dpop_nonce,
          refresh_token: tokens[:refresh_token],
          token_endpoint: prepared.token_endpoint,
          client_id: prepared.client_id
        }

        {:ok, session}
      end
    end
  end

  @doc """
  Rebuild a `PreparedLogin` from pending-oauth store payload (string keys).
  """
  def prepared_from_pending(data) when is_map(data) do
    %PreparedLogin{
      handle: data["handle"],
      did: data["did"],
      pds_url: data["pds_url"],
      token_endpoint: data["token_endpoint"],
      redirect_uri: data["redirect_uri"],
      client_id: data["client_id"],
      code_verifier: data["code_verifier"],
      dpop_key: DpopKey.deserialize(data["dpop_key"]),
      state: data["state"],
      auth_url: ""
    }
  end

  @doc """
  Refresh a DPoP-bound access token. Mutates the session struct and returns
  `{:ok, session}` or `{:error, reason}`.
  """
  def refresh(%OAuthSession{} = session) do
    rt = session.refresh_token || ""
    te = session.token_endpoint || ""
    cid = session.client_id || ""

    if rt == "" or te == "" or cid == "" do
      {:error, :missing_refresh}
    else
      params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => rt,
        "client_id" => cid
      }

      dpop_proof =
        DpopKey.proof(session.dpop_key, "POST", te, nonce: session.dpop_nonce)

      case post_form(te, params, [{"DPoP", dpop_proof}]) do
        {:ok, %{status: status, body: body, headers: headers}}
        when status in [400, 401] ->
          case header_value(headers, "dpop-nonce") do
            nil ->
              {:error, "OAuth refresh failed (#{status}): #{trunc_body(body)}"}

            nonce ->
              dpop_proof2 = DpopKey.proof(session.dpop_key, "POST", te, nonce: nonce)

              case post_form(te, params, [{"DPoP", dpop_proof2}]) do
                {:ok, %{status: 200, body: body2, headers: headers2}} ->
                  apply_token_response(session, body2, headers2)

                {:ok, %{status: st, body: b}} ->
                  {:error, "OAuth refresh failed (#{st}): #{trunc_body(b)}"}

                {:error, reason} ->
                  {:error, reason}
              end
          end

        {:ok, %{status: 200, body: body, headers: headers}} ->
          apply_token_response(session, body, headers)

        {:ok, %{status: st, body: body}} ->
          {:error, "OAuth refresh failed (#{st}): #{trunc_body(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp apply_token_response(session, body, headers) do
    token_resp = if is_binary(body), do: Jason.decode!(body), else: body
    access = token_resp["access_token"] || session.access_token
    refresh_tok = token_resp["refresh_token"] || session.refresh_token

    dpop_nonce =
      case header_value(headers, "dpop-nonce") do
        nil -> probe_dpop_nonce(session.pds_url, access, session.dpop_key)
        n -> n
      end

    {:ok,
     %{
       session
       | access_token: access,
         refresh_token: refresh_tok,
         dpop_nonce: dpop_nonce
     }}
  end

  # ── Identity resolution ────────────────────────────────────────────────

  def resolve_identity(handle) do
    handle = handle |> String.trim() |> String.trim_leading("@")

    case resolve_handle(handle) do
      nil ->
        {:error, "Could not resolve handle: #{handle}"}

      did ->
        case fetch_json("https://plc.directory/#{did}") do
          {:ok, did_doc} ->
            case extract_pds_url(did_doc) do
              nil -> {:error, "No PDS service endpoint in DID document"}
              pds_url -> {:ok, did, pds_url}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def resolve_handle(handle) do
    resolve_handle_dns(handle) || resolve_handle_http(handle)
  end

  defp resolve_handle_dns(handle) do
    name = String.to_charlist("_atproto." <> handle)

    case :inet_res.lookup(name, :in, :txt) do
      records when is_list(records) and records != [] ->
        Enum.find_value(records, fn
          [txt | _] when is_list(txt) ->
            val = List.to_string(txt)
            extract_did(val)

          txt when is_list(txt) ->
            extract_did(List.to_string(txt))

          other ->
            extract_did(to_string(other))
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_did(val) do
    cond do
      String.starts_with?(val, "did=") -> String.trim_leading(val, "did=")
      String.starts_with?(val, "did:") -> val
      true -> nil
    end
  end

  defp resolve_handle_http(handle) do
    url = "https://#{handle}/.well-known/atproto-did"

    case Req.get(url, receive_timeout: 10_000, redirect: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        body = String.trim(body)
        if String.starts_with?(body, "did:"), do: body, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def discover_auth_server(pds_url) do
    pr_url = String.trim_trailing(pds_url, "/") <> "/.well-known/oauth-protected-resource"

    with {:ok, pr_meta} <- fetch_json(pr_url) do
      auth_servers =
        pr_meta["authorizationServers"] || pr_meta["authorization_servers"] || []

      case auth_servers do
        [auth_server | _] ->
          as_url =
            String.trim_trailing(to_string(auth_server), "/") <>
              "/.well-known/oauth-authorization-server"

          fetch_json(as_url)

        _ ->
          {:error, "No authorization servers listed"}
      end
    end
  end

  # ── PAR / token ────────────────────────────────────────────────────────

  def generate_pkce do
    verifier = b64url(:crypto.strong_rand_bytes(32))
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  def push_authorization_request(
        par_endpoint,
        authorization_endpoint,
        client_id,
        redirect_uri,
        code_challenge,
        state,
        login_hint,
        dpop_key
      ) do
    params = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "code_challenge" => code_challenge,
      "code_challenge_method" => "S256",
      "scope" => "atproto transition:generic",
      "state" => state,
      "login_hint" => login_hint
    }

    dpop_proof = DpopKey.proof(dpop_key, "POST", par_endpoint)

    case post_form(par_endpoint, params, [{"DPoP", dpop_proof}]) do
      {:ok, %{status: status, headers: headers, body: body}} when status in [400, 401] ->
        case header_value(headers, "dpop-nonce") do
          nil ->
            {:error, "PAR failed (#{status}): #{trunc_body(body)}"}

          nonce ->
            dpop2 = DpopKey.proof(dpop_key, "POST", par_endpoint, nonce: nonce)

            case post_form(par_endpoint, params, [{"DPoP", dpop2}]) do
              {:ok, %{status: st, body: body2}} when st in 200..299 ->
                parse_par_response(body2, authorization_endpoint, client_id)

              {:ok, %{status: st, body: body2}} ->
                {:error, "PAR failed (#{st}): #{trunc_body(body2)}"}

              {:error, reason} ->
                {:error, inspect(reason)}
            end
        end

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parse_par_response(body, authorization_endpoint, client_id)

      {:ok, %{status: st, body: body}} ->
        {:error, "PAR failed (#{st}): #{trunc_body(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp parse_par_response(body, authorization_endpoint, client_id) do
    par_resp = if is_binary(body), do: Jason.decode!(body), else: body
    request_uri = par_resp["request_uri"]

    if is_nil(request_uri) or request_uri == "" do
      {:error, "No request_uri in PAR response"}
    else
      auth_url =
        "#{authorization_endpoint}?client_id=#{urlencode(client_id)}&request_uri=#{urlencode(request_uri)}"

      {:ok, auth_url}
    end
  end

  def exchange_code(token_endpoint, code, code_verifier, redirect_uri, client_id, dpop_key) do
    params = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => client_id,
      "code_verifier" => code_verifier
    }

    dpop_proof = DpopKey.proof(dpop_key, "POST", token_endpoint)

    case post_form(token_endpoint, params, [{"DPoP", dpop_proof}]) do
      {:ok, %{status: status, headers: headers}} when status in [400, 401] ->
        case header_value(headers, "dpop-nonce") do
          nil ->
            {:error, "Token exchange failed (#{status})"}

          nonce ->
            dpop2 = DpopKey.proof(dpop_key, "POST", token_endpoint, nonce: nonce)

            case post_form(token_endpoint, params, [{"DPoP", dpop2}]) do
              {:ok, %{status: st, body: body}} when st in 200..299 ->
                parse_token_response(body)

              {:ok, %{status: st, body: body}} ->
                {:error, "Token exchange failed (#{st}): #{trunc_body(body)}"}

              {:error, reason} ->
                {:error, inspect(reason)}
            end
        end

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parse_token_response(body)

      {:ok, %{status: st, body: body}} ->
        {:error, "Token exchange failed (#{st}): #{trunc_body(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp parse_token_response(body) do
    token_resp = if is_binary(body), do: Jason.decode!(body), else: body

    {:ok,
     %{
       access_token: token_resp["access_token"],
       refresh_token: token_resp["refresh_token"],
       sub: token_resp["sub"]
     }}
  end

  def probe_dpop_nonce(pds_url, access_token, dpop_key) do
    url = String.trim_trailing(pds_url, "/") <> "/xrpc/com.atproto.server.getSession"
    proof = DpopKey.proof(dpop_key, "GET", url, access_token: access_token)

    case Req.get(url,
           headers: [
             {"authorization", "DPoP #{access_token}"},
             {"dpop", proof}
           ],
           receive_timeout: 10_000
         ) do
      {:ok, %{headers: headers}} -> header_value(headers, "dpop-nonce")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── HTTP helpers ───────────────────────────────────────────────────────

  defp fetch_json(url) do
    case Req.get(url, headers: [{"accept", "application/json"}], receive_timeout: 10_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        body = if is_binary(body), do: Jason.decode!(body), else: body
        {:ok, body}

      {:ok, %{status: st}} ->
        {:error, "GET #{url} failed (#{st})"}

      {:error, reason} ->
        {:error, "GET #{url} failed: #{inspect(reason)}"}
    end
  end

  defp post_form(url, params, headers) do
    body = URI.encode_query(params)

    case Req.post(url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"} | headers],
           receive_timeout: 15_000
         ) do
      {:ok, resp} -> {:ok, resp}
      {:error, reason} -> {:error, reason}
    end
  end

  # Req returns headers as a map (`%{"dpop-nonce" => ["…"]}`). Finch/Mint
  # style list-of-tuples is also accepted for tests and other clients.
  defp header_value(headers, name) when is_map(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name_down, do: first_header_val(v)
    end)
  end

  defp header_value(headers, name) when is_list(headers) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name_down, do: first_header_val(v)

      {k, v} when is_atom(k) ->
        if String.downcase(Atom.to_string(k)) == name_down, do: first_header_val(v)

      _ ->
        nil
    end)
  end

  defp header_value(_, _), do: nil

  defp first_header_val([v | _]) when is_binary(v), do: v
  defp first_header_val(v) when is_binary(v), do: v
  defp first_header_val(_), do: nil

  defp extract_pds_url(did_doc) do
    services = did_doc["service"] || []

    Enum.find_value(services, fn svc ->
      id = svc["id"] || ""
      type = svc["type"] || ""

      if id == "#atproto_pds" or type == "AtprotoPersonalDataServer" do
        svc["serviceEndpoint"]
      end
    end)
  end

  defp b64url(data), do: Base.url_encode64(data, padding: false)

  # RFC 3986 percent-encoding (not form-urlencoded — no `+` for spaces).
  defp urlencode(s) do
    URI.encode(to_string(s), &URI.char_unreserved?/1)
  end

  defp trunc_body(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp trunc_body(body), do: body |> inspect() |> String.slice(0, 200)
end
