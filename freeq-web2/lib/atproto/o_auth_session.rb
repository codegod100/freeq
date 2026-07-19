# frozen_string_literal: true
require_relative "dpop_key"

module Atproto
  # Authenticated AT Protocol session. Carried by SessionState for SASL.
  class OAuthSession
    attr_accessor :did, :handle, :access_token, :pds_url, :dpop_key, :dpop_nonce,
                  :refresh_token, :token_endpoint, :client_id

    def initialize(did:, handle:, access_token:, pds_url:, dpop_key:, dpop_nonce: nil,
                   refresh_token: nil, token_endpoint: nil, client_id: nil)
      @did = did
      @handle = handle
      @access_token = access_token
      @pds_url = pds_url
      @dpop_key = dpop_key
      @dpop_nonce = dpop_nonce
      @refresh_token = refresh_token
      @token_endpoint = token_endpoint
      @client_id = client_id
    end

    def nick
      IrcRender.sanitize_nick(handle)
    end

    def to_h
      {
        "did" => @did,
        "handle" => @handle,
        "access_token" => @access_token,
        "pds_url" => @pds_url,
        "dpop_key" => @dpop_key.serialize,
        "dpop_nonce" => @dpop_nonce,
        "refresh_token" => @refresh_token,
        "token_endpoint" => @token_endpoint,
        "client_id" => @client_id
      }
    end

    # Accepts string/symbol keys and either a serialized dpop_key string
    # (`dpop_key` / `dpop_key_serialized`) or a live DpopKey instance.
    def self.from_h(h)
      h = h.transform_keys(&:to_s)
      key =
        if h["dpop_key"].is_a?(DpopKey)
          h["dpop_key"]
        else
          raw = h["dpop_key"] || h["dpop_key_serialized"]
          raise ArgumentError, "missing dpop_key" if raw.to_s.empty?

          DpopKey.deserialize(raw)
        end
      new(
        did: h["did"],
        handle: h["handle"],
        access_token: h["access_token"],
        pds_url: h["pds_url"],
        dpop_key: key,
        dpop_nonce: h["dpop_nonce"],
        refresh_token: h["refresh_token"],
        token_endpoint: h["token_endpoint"],
        client_id: h["client_id"]
      )
    end
  end
end
