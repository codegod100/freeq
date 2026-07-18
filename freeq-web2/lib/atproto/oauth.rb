# frozen_string_literal: true
require "net/http"
require "json"
require "uri"
require "securerandom"
require "base64"
require "openssl"

require_relative "dpop_key"

module Atproto
  # OAuth flow: handle resolution → auth server discovery → PAR → callback →
  # token exchange. Mirrors freeq-webui/src/oauth_flow.rs.
  module OAuth
    module_function

    # Resolve a handle (e.g. "nandi.bsky.social") to (did, pds_url).
    # 1. Try DNS TXT _atproto.handle → DID
    # 2. Try https://{handle}/.well-known/atproto-did
    # 3. Resolve DID document → PDS endpoint
    def resolve_identity(handle)
      handle = handle.to_s.strip.sub(/^@/, "")
      did = resolve_handle(handle)
      raise "Could not resolve handle: #{handle}" unless did

      did_doc = fetch_json("https://plc.directory/#{did}")
      pds_url = extract_pds_url(did_doc)
      raise "No PDS service endpoint in DID document" unless pds_url

      [did, pds_url]
    end

    # Resolve handle → DID via DNS TXT or .well-known.
    def resolve_handle(handle)
      # Try DNS TXT first (more reliable when the host doesn't have a web server).
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

      # Fallback: HTTPS .well-known/atproto-did.
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

    # Discover the authorization server from the PDS's protected resource metadata.
    def discover_auth_server(pds_url)
      pr_url = "#{pds_url.to_s.chomp('/')}/.well-known/oauth-protected-resource"
      pr_meta = fetch_json(pr_url)
      auth_servers = pr_meta["authorizationServers"] || pr_meta["authorization_servers"] || []
      raise "No authorization servers listed" if auth_servers.empty?

      auth_server = auth_servers.first
      as_url = "#{auth_server.to_s.chomp('/')}/.well-known/oauth-authorization-server"
      fetch_json(as_url)
    end

    # Generate PKCE pair. Returns [code_verifier, code_challenge].
    def generate_pkce
      verifier = b64url(SecureRandom.random_bytes(32))
      challenge = b64url(OpenSSL::Digest::SHA256.digest(verifier))
      [verifier, challenge]
    end

    # Pushed Authorization Request. Returns the authorization URL to redirect
    # the browser to. Uses DPoP for sender-constrained PAR.
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

      # Handle DPoP nonce retry.
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

    # Exchange the authorization code for an access token. Returns
    # [access_token, optional sub DID from token response].
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

      # Handle DPoP nonce retry.
      if [400, 401].include?(resp.code.to_i) && (nonce = resp["dpop-nonce"])
        dpop_proof = dpop_key.proof("POST", token_endpoint, nonce: nonce)
        resp = http_post_form(token_endpoint, params, "DPoP" => dpop_proof)
      end

      raise "Token exchange failed (#{resp.code}): #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      token_resp = JSON.parse(resp.body)
      [token_resp["access_token"], token_resp["sub"]]
    end

    # Probe the PDS for a DPoP nonce. Returns the nonce string or nil.
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

  # Prepared in-flight OAuth login — carries everything needed for the
  # callback to complete the token exchange.
  class PreparedLogin
    attr_reader :auth_url, :state, :redirect_uri, :client_id,
                :code_verifier, :token_endpoint, :pds_url, :dpop_key,
                :did, :handle

    def initialize(handle, did, pds_url, auth_meta, redirect_uri, client_id,
                   code_verifier, dpop_key, state, auth_url)
      @handle = handle
      @did = did
      @pds_url = pds_url
      @token_endpoint = auth_meta["token_endpoint"]
      @redirect_uri = redirect_uri
      @client_id = client_id
      @code_verifier = code_verifier
      @dpop_key = dpop_key
      @state = state
      @auth_url = auth_url
    end

    # Complete the OAuth flow after the callback. Returns an OAuthSession.
    def complete(auth_code)
      access_token, token_did = OAuth.exchange_code(
        @token_endpoint, auth_code, @code_verifier, @redirect_uri,
        @client_id, @dpop_key
      )
      if token_did && token_did != @did
        raise "DID mismatch: resolved #{@did} but token is for #{token_did}"
      end
      dpop_nonce = OAuth.probe_dpop_nonce(@pds_url, access_token, @dpop_key)
      OAuthSession.new(
        did: @did,
        handle: @handle,
        access_token: access_token,
        pds_url: @pds_url,
        dpop_key: @dpop_key,
        dpop_nonce: dpop_nonce
      )
    end
  end

  # Authenticated AT Protocol session. Carried by SessionState for SASL.
  class OAuthSession
    attr_accessor :did, :handle, :access_token, :pds_url, :dpop_key, :dpop_nonce

    def initialize(did:, handle:, access_token:, pds_url:, dpop_key:, dpop_nonce: nil)
      @did = did
      @handle = handle
      @access_token = access_token
      @pds_url = pds_url
      @dpop_key = dpop_key
      @dpop_nonce = dpop_nonce
    end

    def nick
      IrcRender.sanitize_nick(handle)
    end

    # Serialize for cookie/session storage.
    def to_h
      {
        did: @did,
        handle: @handle,
        access_token: @access_token,
        pds_url: @pds_url,
        dpop_key_serialized: @dpop_key.serialize,
        dpop_nonce: @dpop_nonce
      }
    end

    def self.from_h(h)
      new(
        did: h[:did],
        handle: h[:handle],
        access_token: h[:access_token],
        pds_url: h[:pds_url],
        dpop_key: DpopKey.deserialize(h[:dpop_key_serialized]),
        dpop_nonce: h[:dpop_nonce]
      )
    end
  end

  # Build a PreparedLogin for a web redirect flow.
  module OAuth
    class << self
      # Start the OAuth flow for a handle. Returns a PreparedLogin.
      def prepare(handle, public_url = nil)
        did, pds_url = resolve_identity(handle)
        auth_meta = discover_auth_server(pds_url)

        redirect_uri = public_url ? "#{public_url.chomp('/')}/auth/callback" : "http://127.0.0.1:0/callback"
        client_id = if public_url
          "#{public_url.chomp('/')}/.well-known/oauth-client-metadata"
        else
          scope = "atproto transition:generic"
          "http://localhost?redirect_uri=#{urlencode(redirect_uri)}&scope=#{urlencode(scope)}"
        end

        code_verifier, code_challenge = generate_pkce
        dpop_key = DpopKey.new
        state = b64url(SecureRandom.random_bytes(16))

        par_endpoint = auth_meta["pushed_authorization_request_endpoint"] ||
                       auth_meta["pushed_authorization_request_endpoint"]
        raise "Authorization server does not support PAR" unless par_endpoint

        auth_url = push_authorization_request(
          par_endpoint, auth_meta["authorization_endpoint"], client_id,
          redirect_uri, code_challenge, state, handle, dpop_key
        )

        PreparedLogin.new(
          handle, did, pds_url, auth_meta, redirect_uri, client_id,
          code_verifier, dpop_key, state, auth_url
        )
      end
    end
  end
end
