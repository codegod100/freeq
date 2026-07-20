# frozen_string_literal: true
require_relative "../../lib/atproto/o_auth"

class SessionsController < ApplicationController
  # Login start + logout skip CSRF: boxd Cookie-header quirks + Turbo often
  # 422 authenticity checks even with a valid token. Logout is low-risk
  # (worst case: CSRF log-out). OAuth start is bound by the `state` param.
  skip_before_action :verify_authenticity_token, only: %i[create destroy]

  # GET /login — login form.
  def new
    @session = current_session
    if @session.authenticated?
      redirect_to "/chat", notice: "Signed in as #{@session.auth_handle}"
      return
    end
    # Credentials without SASL: keep trying; don't pretend we're done.
    if @session.has_credentials?
      @session.ensure_authenticated!(SessionRegistry.instance.upstream_url, timeout: 10.0)
      if @session.authenticated?
        redirect_to "/chat", notice: "Signed in as #{@session.auth_handle}"
        return
      end
    end
  end

  # GET /login/start | POST /login — start OAuth flow.
  def create
    handle = params[:identifier].to_s.strip.sub(/^@/, "")
    if handle.empty?
      return redirect_to "/login", alert: "Handle is required"
    end

    begin
      public_url = ENV["FREEQ_PUBLIC_URL"].presence || request.base_url
      prepared = Atproto::OAuth.prepare(handle, public_url)

      # freeq_session must already exist (before_action). Persist it with the
      # pending OAuth so callback can re-bind even if the cookie is missing.
      sid = session_id
      payload = {
        "handle" => prepared.handle,
        "did" => prepared.did,
        "pds_url" => prepared.pds_url,
        "token_endpoint" => prepared.token_endpoint,
        "redirect_uri" => prepared.redirect_uri,
        "client_id" => prepared.client_id,
        "code_verifier" => prepared.code_verifier,
        "dpop_key" => prepared.dpop_key.serialize,
        "state" => prepared.state,
        "freeq_session_id" => sid
      }

      # Server-side only — do NOT put PKCE/DPoP material in a cookie (size +
      # truncation). OAuth state in the redirect URL is the lookup key.
      PendingOauthStore.instance.save(prepared.state, payload)
      PendingOauthStore.instance.gc!

      # Keep freeq_session tiny; drop any leftover fat cookies.
      cookies.delete(:pending_oauth)
      cookies.delete(:oauth_session)
      bind_freeq_session!(sid)

      oauth_file_log("OAuth start handle=#{prepared.handle} sid=#{sid} state=#{prepared.state[0, 12]}")
      redirect_to prepared.auth_url, allow_other_host: true
    rescue => e
      oauth_file_log("OAuth prepare failed: #{e.class}: #{e.message}")
      Rails.logger.warn("OAuth prepare failed: #{e.class}: #{e.message}")
      redirect_to "/login", alert: "Login failed: #{e.message}"
    end
  end

  # GET|POST /auth/callback — OAuth redirect callback.
  def callback
    code = params[:code]
    state = params[:state].to_s
    error = params[:error]

    if error
      PendingOauthStore.instance.remove(state) if state.present?
      redirect_to "/login", alert: "OAuth error: #{error}"
      return
    end

    if code.to_s.empty? || state.empty?
      redirect_to "/login", alert: "OAuth callback missing code or state."
      return
    end

    data = load_pending_oauth(state)
    unless data
      oauth_file_log("OAuth callback: no pending for state=#{state[0, 12]} cookies=#{request.cookies.keys}")
      redirect_to "/login", alert: "No pending login. Please try again."
      return
    end

    begin
      dpop_key = Atproto::DpopKey.deserialize(data["dpop_key"])
      prepared = Atproto::PreparedLogin.new(
        data["handle"], data["did"], data["pds_url"], data["token_endpoint"],
        data["redirect_uri"], data["client_id"],
        data["code_verifier"], dpop_key, data["state"], ""
      )
      oauth_session = prepared.complete(code)

      sid = data["freeq_session_id"].to_s
      sid = session_id if sid.empty?
      bind_freeq_session!(sid)

      # Never put tokens in cookies — disk + tiny freeq_session only.
      cookies.delete(:pending_oauth)
      cookies.delete(:oauth_session)
      session.delete(:oauth)

      state_obj = SessionRegistry.instance.get(sid)
      # OAuth is credentials only — app identity becomes real after SASL.
      state_obj.auth = oauth_session
      SessionRegistry.instance.persist_auth(sid, oauth_session)

      # Drop other freeq-web2 upstreams for this DID (same process only).
      begin
        SessionRegistry.instance.ghost_siblings!(
          except_sid: sid,
          did: oauth_session.did,
          nick: oauth_session.nick
        )
      rescue StandardError => ge
        oauth_file_log("ghost_siblings after login: #{ge.class}: #{ge.message}")
      end

      begin
        state_obj.request_reconnect(SessionRegistry.instance.upstream_url)
        # Block until SASL lands so /chat never shows a false 🔒.
        ok = state_obj.ensure_authenticated!(
          SessionRegistry.instance.upstream_url,
          timeout: 15.0
        )
        oauth_file_log(
          "OAuth+SASL handle=#{oauth_session.handle} sid=#{sid} " \
          "sasl=#{ok} status=#{state_obj.sasl_status} " \
          "bearer=#{state_obj.api_bearer.to_s != ''}"
        )
      rescue StandardError => re
        oauth_file_log("SASL after login failed: #{re.class}: #{re.message}")
      end

      if state_obj.authenticated?
        redirect_to "/chat", notice: "Signed in as #{oauth_session.handle}"
      else
        redirect_to "/chat",
          alert: "OAuth ok for #{oauth_session.handle}, but IRC SASL did not finish. " \
                 "Wait a moment or sign out and try again."
      end
    rescue => e
      oauth_file_log("OAuth callback FAILED: #{e.class}: #{e.message}")
      Rails.logger.warn("OAuth callback failed: #{e.class}: #{e.message}")
      redirect_to "/login", alert: "Login failed: #{e.message}"
    end
  end

  # POST|GET /logout — clear session.
  def destroy
    sid = session_id
    state_obj = SessionRegistry.instance.get(sid)
    state_obj.auth = :guest # clears credentials + SASL state
    SessionRegistry.instance.clear_auth(sid)
    begin
      state_obj.request_reconnect(SessionRegistry.instance.upstream_url)
    rescue StandardError => e
      oauth_file_log("logout reconnect: #{e.class}: #{e.message}")
    end
    clear_oauth_browser_state!
    reset_session
    redirect_to "/chat", notice: "Signed out"
  end

  # GET /.well-known/oauth-client-metadata — public OAuth client metadata.
  def client_metadata
    public_url = ENV["FREEQ_PUBLIC_URL"].presence || "http://#{request.host}:#{request.port}"
    render json: {
      client_id: "#{public_url.chomp('/')}/.well-known/oauth-client-metadata",
      client_name: "freeq-web2",
      redirect_uris: ["#{public_url.chomp('/')}/auth/callback"],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      scope: "atproto transition:generic",
      token_endpoint_auth_method: "none",
      application_type: "web",
      dpop_bound_access_tokens: true
    }
  end

  private

  def load_pending_oauth(state)
    data = PendingOauthStore.instance.take(state)
    return data if data.is_a?(Hash) && data["code_verifier"].present?

    # Legacy cookie fallback (old builds). Prefer server store.
    raw = cookies.encrypted[:pending_oauth] rescue nil
    return nil if raw.blank?

    begin
      cookie_data = raw.is_a?(String) ? JSON.parse(raw) : raw
    rescue JSON::ParserError
      return nil
    end

    return nil unless cookie_data.is_a?(Hash)
    return nil unless cookie_data["state"].to_s == state.to_s
    return nil if cookie_data["code_verifier"].to_s.empty?

    cookie_data
  end
end
