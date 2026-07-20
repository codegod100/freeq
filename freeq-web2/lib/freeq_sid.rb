# frozen_string_literal: true

require "openssl"

# Shared freeq browser session id (HMAC cookie `freeq_sid`).
#
# HTTP (ApplicationController) and ActionCable/StimulusReflex MUST use the
# same id. If Cable invents its own SecureRandom sid, reflexes open a *guest*
# IRC connection while the browser cookie holds the SASL-authed session —
# which is exactly how #policytest 477s while the UI looks signed in.
module FreeqSid
  COOKIE = "freeq_sid"
  LEGACY_COOKIE = "freeq_session"

  module_function

  def hmac(sid, secret = nil)
    secret ||= (defined?(Rails) ? Rails.application.secret_key_base : "")
    OpenSSL::HMAC.hexdigest("SHA256", secret, "freeq_sid:#{sid}")[0, 32]
  end

  def cookie_value(sid, secret = nil)
    "#{sid}.#{hmac(sid, secret)}"
  end

  # Parse `sid.hmac` (optionally garbage-suffixed by broken Cookie headers).
  # Returns 32-hex sid or nil.
  def parse(raw, secret = nil)
    raw = raw.to_s
    return nil if raw.empty?

    if (m = raw.match(/\A([0-9a-f]{32}\.[0-9a-f]{32})/i))
      raw = m[1]
    end

    sid, sig = raw.split(".", 2)
    return nil unless sid.to_s.match?(/\A[0-9a-f]{32}\z/) && sig.to_s.match?(/\A[0-9a-f]{32}\z/)

    expect = hmac(sid, secret)
    return nil unless ActiveSupport::SecurityUtils.secure_compare(sig, expect)

    sid
  end

  # Extract freeq_sid from a Cookie header or Rack cookie hash.
  def from_cookies(cookies_hash, cookie_header: nil, secret: nil)
    raw = nil
    if cookie_header.to_s.present?
      cookie_header.to_s.split(/;\s*|,\s*(?=[A-Za-z_][A-Za-z0-9_]*=)/).each do |part|
        k, v = part.split("=", 2)
        next if k.nil? || v.nil?
        if k.strip == COOKIE
          raw = v
          break
        end
      end
    end
    raw = cookies_hash[COOKIE] || cookies_hash[COOKIE.to_sym] if raw.blank?
    parse(raw, secret)
  end
end
