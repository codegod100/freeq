# frozen_string_literal: true
require "net/http"
require "json"
require "uri"
require "base64"
require "securerandom"
require "openssl"

require_relative "dpop_key"
require_relative "o_auth_session"

module Atproto
  # Prepared in-flight OAuth login — carries everything needed for the
  # callback to complete the token exchange.
  class PreparedLogin
    attr_reader :auth_url, :state, :redirect_uri, :client_id,
                :code_verifier, :token_endpoint, :pds_url, :dpop_key,
                :did, :handle

    def initialize(handle, did, pds_url, token_endpoint, redirect_uri, client_id,
                   code_verifier, dpop_key, state, auth_url)
      @handle = handle
      @did = did
      @pds_url = pds_url
      @token_endpoint = token_endpoint
      @redirect_uri = redirect_uri
      @client_id = client_id
      @code_verifier = code_verifier
      @dpop_key = dpop_key
      @state = state
      @auth_url = auth_url
    end

    # Complete the OAuth flow after the callback. Returns an OAuthSession.
    def complete(auth_code)
      tokens = OAuth.exchange_code(
        @token_endpoint, auth_code, @code_verifier, @redirect_uri,
        @client_id, @dpop_key
      )
      token_did = tokens[:sub]
      if token_did && token_did != @did
        raise "DID mismatch: resolved #{@did} but token is for #{token_did}"
      end
      dpop_nonce = OAuth.probe_dpop_nonce(@pds_url, tokens[:access_token], @dpop_key)
      OAuthSession.new(
        did: @did,
        handle: @handle,
        access_token: tokens[:access_token],
        pds_url: @pds_url,
        dpop_key: @dpop_key,
        dpop_nonce: dpop_nonce,
        refresh_token: tokens[:refresh_token],
        token_endpoint: @token_endpoint,
        client_id: @client_id
      )
    end
  end

  # OAuth flow: handle resolution → auth server discovery → PAR → callback →
  # token exchange. Mirrors freeq-webui/src/oauth_flow.rs.
  module OAuth
    module_function

    def resolve_identity(handle)
      handle = handle.to_s.strip.sub(/^@/, "")
      did = resolve_handle(handle)
      raise "Could not resolve handle: #{handle}" unless did

      did_doc = fetch_json("https://plc.directory/#{did}")
      pds_url = extract_pds_url(did_doc)
      raise "No PDS service endpoint in DID document" unless pds_url

      [did, pds_url]
    end

    def resolve_handle(handle)
      begin
        require "resolv"
        dns = Resolv::DNS.new
        records = dns.getresources("_atproto.#{handle}", Resolv::DNS::Resource::IN::TXT)
        records.each do |r|
          val = r.strings.join
          return val.sub(/^did=/, "") if val.start_with?("did=") || val.start_with?("did:")
        end
      rescue StandardError
        nil
      end

      begin
        uri = URI("https://#{handle}/.well-known/atproto-did")
        res = Net::HTTP.get_response(uri)
        if res.is_a?(Net::HTTPSuccess) && res.body&.start_with?("did:")
          return res.body.strip
        end
      rescue StandardError
        nil
      end

      nil
    end

    def discover_auth_server(pds_url)
      pr_url = "#{pds_url.to_s.chomp('/')}/.well-known/oauth-protected-resource"
      pr_meta = fetch_json(pr_url)
      auth_servers = pr_meta["authorizationServers"] || pr_meta["authorization_servers"] || []
      raise "No authorization servers listed" if auth_servers.empty?

      auth_server = auth_servers.first
      as_url = "#{auth_server.to_s.chomp('/')}/.well-known/oauth-authorization-server"
      fetch_json(as_url)
    end

    def generate_pkce
      verifier = b64url(SecureRandom.random_bytes(32))
      challenge = b64url(OpenSSL::Digest::SHA256.digest(verifier))
      [verifier, challenge]
    end

    def push_authorization_request(par_endpoint, authorization_endpoint, client_id,
                                   redirect_uri, code_challenge, state,
                                   login_hint, dpop_key)
      params = {
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256",
        "scope" => "atproto transition:generic",
        "state" => state,
        "login_hint" => login_hint
      }

      dpop_proof = dpop_key.proof("POST", par_endpoint)
      resp = http_post_form(par_endpoint, params, "DPoP" => dpop_proof)

      if resp.code.to_i == 400 && (nonce = resp["dpop-nonce"])
        dpop_proof = dpop_key.proof("POST", par_endpoint, nonce: nonce)
        resp = http_post_form(par_endpoint, params, "DPoP" => dpop_proof)
      end

      raise "PAR failed (#{resp.code}): #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      par_resp = JSON.parse(resp.body)
      request_uri = par_resp["request_uri"]
      raise "No request_uri in PAR response" unless request_uri

      "#{authorization_endpoint}?client_id=#{urlencode(client_id)}&request_uri=#{urlencode(request_uri)}"
    end

    def exchange_code(token_endpoint, code, code_verifier, redirect_uri,
                      client_id, dpop_key)
      params = {
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client_id,
        "code_verifier" => code_verifier
      }

      dpop_proof = dpop_key.proof("POST", token_endpoint)
      resp = http_post_form(token_endpoint, params, "DPoP" => dpop_proof)

      if [400, 401].include?(resp.code.to_i) && (nonce = resp["dpop-nonce"])
        dpop_proof = dpop_key.proof("POST", token_endpoint, nonce: nonce)
        resp = http_post_form(token_endpoint, params, "DPoP" => dpop_proof)
      end

      raise "Token exchange failed (#{resp.code}): #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      token_resp = JSON.parse(resp.body)
      {
        access_token: token_resp["access_token"],
        refresh_token: token_resp["refresh_token"],
        sub: token_resp["sub"]
      }
    end

    # Refresh a DPoP-bound access token. Mutates `session` in place.
    # Returns true on success, false if refresh is impossible / failed.
    def refresh!(session)
      rt = session.refresh_token.to_s
      te = session.token_endpoint.to_s
      cid = session.client_id.to_s
      return false if rt.empty? || te.empty? || cid.empty?

      params = {
        "grant_type" => "refresh_token",
        "refresh_token" => rt,
        "client_id" => cid
      }
      dpop_proof = session.dpop_key.proof("POST", te, nonce: session.dpop_nonce)
      resp = http_post_form(te, params, "DPoP" => dpop_proof)

      if [400, 401].include?(resp.code.to_i) && (nonce = resp["dpop-nonce"])
        session.dpop_nonce = nonce
        dpop_proof = session.dpop_key.proof("POST", te, nonce: nonce)
        resp = http_post_form(te, params, "DPoP" => dpop_proof)
      end

      unless resp.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("OAuth refresh failed (#{resp.code}): #{resp.body.to_s[0, 200]}") if defined?(Rails)
        return false
      end

      token_resp = JSON.parse(resp.body)
      session.access_token = token_resp["access_token"] if token_resp["access_token"]
      session.refresh_token = token_resp["refresh_token"] if token_resp["refresh_token"]
      # Fresh DPoP nonce for subsequent getSession / SASL.
      if (n = resp["dpop-nonce"])
        session.dpop_nonce = n
      else
        session.dpop_nonce = probe_dpop_nonce(session.pds_url, session.access_token, session.dpop_key)
      end
      true
    rescue StandardError => e
      Rails.logger.warn("OAuth refresh error: #{e.class}: #{e.message}") if defined?(Rails)
      false
    end

    def probe_dpop_nonce(pds_url, access_token, dpop_key)
      url = "#{pds_url.to_s.chomp('/')}/xrpc/com.atproto.server.getSession"
      proof = dpop_key.proof("GET", url, access_token: access_token)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "DPoP #{access_token}"
      req["DPoP"] = proof
      resp = http.request(req)
      resp["dpop-nonce"]
    rescue StandardError
      nil
    end

    # Start the OAuth flow for a handle. Returns a PreparedLogin.
    # When public_url is publicly reachable, uses the web redirect flow
    # with a client metadata URL. When it's localhost, uses the loopback
    # client_id format (inline params, no metadata fetch required).
    def prepare(handle, public_url = nil)
      did, pds_url = resolve_identity(handle)
      auth_meta = discover_auth_server(pds_url)

      redirect_uri = "#{public_url.chomp('/')}/auth/callback"

      if public_url.to_s.match?(/localhost|127\.0\.0\.1/)
        # Loopback client_id: encodes redirect_uri + scope inline.
        scope = "atproto transition:generic"
        client_id = "http://localhost?redirect_uri=#{urlencode(redirect_uri)}&scope=#{urlencode(scope)}"
      else
        client_id = "#{public_url.chomp('/')}/.well-known/oauth-client-metadata"
      end

      code_verifier, code_challenge = generate_pkce
      dpop_key = DpopKey.new
      state = b64url(SecureRandom.random_bytes(16))

      par_endpoint = auth_meta["pushed_authorization_request_endpoint"]
      raise "Authorization server does not support PAR" unless par_endpoint

      auth_url = push_authorization_request(
        par_endpoint, auth_meta["authorization_endpoint"], client_id,
        redirect_uri, code_challenge, state, handle, dpop_key
      )

      PreparedLogin.new(
        handle, did, pds_url, auth_meta["token_endpoint"],
        redirect_uri, client_id,
        code_verifier, dpop_key, state, auth_url
      )
    end

    # ── Helpers ──────────────────────────────────────────────────────────

    def fetch_json(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = 10
      req = Net::HTTP::Get.new(uri)
      req["Accept"] = "application/json"
      resp = http.request(req)
      raise "GET #{url} failed (#{resp.code})" unless resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body)
    end

    def http_post_form(url, params, headers = {})
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = 10
      req = Net::HTTP::Post.new(uri)
      req.set_form_data(params)
      headers.each { |k, v| req[k] = v }
      http.request(req)
    end

    def extract_pds_url(did_doc)
      services = did_doc["service"] || []
      services.each do |svc|
        return svc["serviceEndpoint"] if svc["id"] == "#atproto_pds" || svc["type"] == "AtprotoPersonalDataServer"
      end
      nil
    end

    def b64url(data)
      Base64.urlsafe_encode64(data, padding: false)
    end

    def urlencode(s)
      s.to_s.bytes.each_with_object(+"") do |byte, out|
        if (0x41..0x5a).include?(byte) || (0x61..0x7a).include?(byte) ||
           (0x30..0x39).include?(byte) || [0x2d, 0x5f, 0x2e, 0x7e].include?(byte)
          out << byte.chr
        else
          out << format("%%%02X", byte)
        end
      end
    end
  end
end
