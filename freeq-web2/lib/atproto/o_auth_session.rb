# frozen_string_literal: true
require_relative "dpop_key"

module Atproto
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
end
