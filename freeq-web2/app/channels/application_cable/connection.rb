# frozen_string_literal: true

require_relative "../../../lib/freeq_sid"

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :session_id

    def connect
      sid = resolve_freeq_sid
      if sid.blank?
        # Last resort: accept a random sid rather than leaving Cable dead
        # (reactions / live rows / StimulusReflex all need this socket).
        # Prefer freeq_sid so IRC state matches HTTP; log when we cannot.
        sid = SecureRandom.hex(16)
        log_cable("warn missing freeq_sid — ephemeral sid=#{sid[0, 8]}… keys=#{cookie_keys}")
      else
        log_cable("connected freeq_sid=#{sid[0, 8]}…")
      end
      self.session_id = sid
    end

    private

    def resolve_freeq_sid
      header = request.headers["Cookie"].to_s
      FreeqSid.from_cookies(cookies, cookie_header: header).presence ||
        session_freeq_sid.presence ||
        legacy_signed_freeq_session
    end

    # Rails cookie session may carry freeq_sid when the plain cookie is
    # missing from the upgrade request.
    def session_freeq_sid
      request.session[:freeq_sid].to_s.presence
    rescue StandardError
      nil
    end

    def legacy_signed_freeq_session
      cookies.signed[FreeqSid::LEGACY_COOKIE].to_s.presence
    rescue StandardError
      nil
    end

    def cookie_keys
      request.cookies.keys.sort.join(",")
    rescue StandardError
      "?"
    end

    def log_cable(msg)
      logger.info("[cable] #{msg}")
      path = (defined?(Rails) ? Rails.root : Pathname.new(".")).join("log/oauth.log")
      File.open(path, "a") { |f| f.puts("#{Time.now.utc.iso8601} [cable] #{msg}") }
    rescue StandardError
      nil
    end
  end
end
