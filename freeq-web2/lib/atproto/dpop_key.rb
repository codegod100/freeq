# frozen_string_literal: true
require "ed25519"
require "base64"
require "securerandom"
require "json"
require "openssl"

module Atproto
  # Ed25519 keypair for DPoP (Demonstrating Proof-of-Possession) proofs.
  # Mirrors freeq-sdk's DpopKey.
  class DpopKey
    attr_reader :signing_key, :verify_key

    def initialize(signing_key = nil)
      if signing_key
        @signing_key = Ed25519::SigningKey.new(signing_key)
      else
        @signing_key = Ed25519::SigningKey.generate
      end
      @verify_key = @signing_key.verify_key
    end

    # Public key as raw 32 bytes.
    def public_bytes
      @verify_key.to_bytes
    end

    # Public key as base64url (unpadded) for JWK.
    def public_b64
      b64url(public_bytes)
    end

    # JWK representation for the DPoP JWT header.
    def jwk
      { kty: "OKP", crv: "Ed25519", x: public_b64 }
    end

    # Build a DPoP proof JWT for the given HTTP method, URL, optional nonce,
    # and optional access token (ath claim).
    def proof(method, url, nonce: nil, access_token: nil)
      header = { typ: "dpop+jwt", alg: "EdDSA", jwk: jwk }
      payload = {
        htm: method.upcase,
        htu: url,
        iat: Time.now.to_i,
        jti: SecureRandom.hex(16)
      }
      payload[:nonce] = nonce if nonce
      payload[:ath] = b64url(OpenSSL::Digest::SHA256.digest(access_token)) if access_token

      header_b64 = b64url(JSON.generate(header))
      payload_b64 = b64url(JSON.generate(payload))
      signing_input = "#{header_b64}.#{payload_b64}"
      signature = @signing_key.sign(signing_input)
      "#{signing_input}.#{b64url(signature)}"
    end

    # Serialize for session storage (raw private key bytes, base64-encoded).
    def serialize
      b64url(@signing_key.to_bytes)
    end

    # Deserialize from base64-encoded private key bytes.
    def self.deserialize(str)
      bytes = unb64url(str)
      new(bytes)
    end

    private

    def b64url(data)
      Base64.urlsafe_encode64(data, padding: false)
    end

    def self.unb64url(str)
      Base64.urlsafe_decode64(str)
    end
  end
end
