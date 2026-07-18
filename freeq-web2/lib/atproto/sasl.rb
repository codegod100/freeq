# frozen_string_literal: true
require "base64"
require "json"

module Atproto
  # SASL ATPROTO-CHALLENGE response builder.
  # Given a server challenge (base64-encoded JSON) and an OAuthSession,
  # builds the base64-encoded response payload.
  module Sasl
    module_function

    # Parse the server's AUTHENTICATE challenge (base64 JSON).
    # Returns { session_id:, nonce:, timestamp: }.
    def parse_challenge(challenge_b64)
      json = Base64.urlsafe_decode64(challenge_b64)
      data = JSON.parse(json)
      {
        session_id: data["session_id"],
        nonce: data["nonce"],
        timestamp: data["timestamp"]
      }
    end

    # Build the SASL response payload for the given challenge nonce + OAuthSession.
    # The dpop_proof is for GET /xrpc/com.atproto.server.getSession on the PDS.
    def build_response(challenge_nonce, oauth_session)
      get_session_url = "#{oauth_session.pds_url.to_s.chomp('/')}/xrpc/com.atproto.server.getSession"
      dpop_proof = oauth_session.dpop_key.proof(
        "GET",
        get_session_url,
        nonce: oauth_session.dpop_nonce,
        access_token: oauth_session.access_token
      )
      payload = {
        did: oauth_session.did,
        signature: oauth_session.access_token,
        method: "pds-oauth",
        pds_url: oauth_session.pds_url,
        dpop_proof: dpop_proof,
        challenge_nonce: challenge_nonce
      }
      Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
    end
  end
end
