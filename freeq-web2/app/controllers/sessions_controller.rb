# frozen_string_literal: true
require_relative "../../lib/atproto/oauth"

class SessionsController < ApplicationController
  # GET /login — login form.
  def new
    @session = current_session
  end

  # POST /login — start OAuth flow.
  def create
    handle = params[:identifier].to_s.strip.sub(/^@/, "")
    if handle.empty?
      return redirect_to "/login", alert: "Handle is required"
    end

    session = current_session

    begin
      public_url = ENV["FREEQ_PUBLIC_URL"].presence
      prepared = Atproto::OAuth.prepare(handle, public_url)

      # Stash the PreparedLogin in the session cookie (encrypted via Rails).
      # We store the serialized form so we can complete it on callback.
      cookies.encrypted[:pending_oauth] = JSON.generate(
        handle: prepared.handle,
        did: prepared.did,
        pds_url: prepared.pds_url,
        token_endpoint: prepared.token_endpoint,
        redirect_uri: prepared.redirect_uri,
        client_id: prepared.client_id,
        code_verifier: prepared.code_verifier,
        dpop_key: prepared.dpop_key.serialize,
        state: prepared.state
      )

      redirect_to prepared.auth_url, allow_other_host: true
    rescue => e
      Rails.logger.warn("OAuth prepare failed: #{e.class}: #{e.message}")
      redirect_to "/login", alert: "Login failed: #{e.message}"
    end
  end

  # GET /auth/callback — OAuth redirect callback.
  def callback
    code = params[:code]
    state = params[:state]
    error = params[:error]

    if error
      redirect_to "/login", alert: "OAuth error: #{error}"
      return
    end

    pending = cookies.encrypted[:pending_oauth]
    unless pending
      redirect_to "/login", alert: "No pending login. Please try again."
      return
    end

    begin
      data = JSON.parse(pending)
      unless data["state"] == state
        redirect_to "/login", alert: "State mismatch. Please try again."
        return
      end

      dpop_key = Atproto::DpopKey.deserialize(data["dpop_key"])
      auth_meta = { "token_endpoint" => data["token_endpoint"] }
      prepared = Atproto::PreparedLogin.new(
        data["handle"], data["did"], data["pds_url"], auth_meta,
        data["redirect_uri"], data["client_id"],
        data["code_verifier"], dpop_key, data["state"], ""
      )
      oauth_session = prepared.complete(code)

      # Store in the server-side session state.
      session = current_session
      session.auth = oauth_session
      session.request_reconnect

      cookies.encrypted[:pending_oauth] = nil
      redirect_to "/chat", notice: "Signed in as #{oauth_session.handle}"
    rescue => e
      Rails.logger.warn("OAuth callback failed: #{e.class}: #{e.message}")
      redirect_to "/login", alert: "Login failed: #{e.message}"
    end
  end

  # POST /logout — clear session.
  def destroy
    session = current_session
    session.auth = :guest
    session.request_reconnect
    cookies.encrypted[:pending_oauth] = nil
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
end
