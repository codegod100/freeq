# frozen_string_literal: true

require_relative "../../lib/freeq_sid"

class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :ensure_session_cookie

  # Plain HMAC cookie. Keep this tiny — fat OAuth cookies + Cookie-header
  # corruption on the boxd edge were dropping the session id.
  # MUST match ActionCable::Connection (see FreeqSid / freeq_sid.rb).
  SID_COOKIE = FreeqSid::COOKIE

  private

  def ensure_session_cookie
    session_id
  end

  def oauth_file_log(msg)
    path = Rails.root.join("log/oauth.log")
    File.open(path, "a") { |f| f.puts("#{Time.now.utc.iso8601} #{msg}") }
  rescue StandardError
    nil
  end

  def session_id
    return @freeq_session_id if defined?(@freeq_session_id) && @freeq_session_id.present?

    sid = read_sid_cookie
    sid = session[:freeq_sid].to_s if sid.blank?
    sid = SecureRandom.hex(16) if sid.blank?

    bind_freeq_session!(sid)
    sid
  end

  def bind_freeq_session!(sid)
    sid = sid.to_s
    raise ArgumentError, "empty freeq session id" if sid.empty?

    @freeq_session_id = sid
    session[:freeq_sid] = sid
    write_sid_cookie!(sid)
    sid
  end

  def read_sid_cookie
    header = request.headers["Cookie"].to_s
    sid = FreeqSid.from_cookies(request.cookies, cookie_header: header)
    return sid if sid.present?

    legacy = cookies.signed[FreeqSid::LEGACY_COOKIE].to_s rescue ""
    return legacy if legacy.present?

    raw = extract_cookie_value(SID_COOKIE).to_s
    if raw.present? && FreeqSid.parse(raw).nil?
      oauth_file_log("sid cookie bad/malformed len=#{raw.bytesize} prefix=#{raw[0, 48].inspect}")
    end
    nil
  end

  # Prefer the raw Cookie header so a corrupted jar entry cannot swallow the sid.
  def extract_cookie_value(name)
    header = request.headers["Cookie"].to_s
    if header.present?
      header.split(/;\s*|,\s*(?=[A-Za-z_][A-Za-z0-9_]*=)/).each do |part|
        k, v = part.split("=", 2)
        next if k.nil? || v.nil?
        return v if k.strip == name
      end
    end
    request.cookies[name]
  end

  def sid_hmac(sid)
    FreeqSid.hmac(sid)
  end

  def write_sid_cookie!(sid)
    %w[freeq_session oauth_session pending_oauth].each { |n| expire_cookie!(n) }

    cookies[SID_COOKIE] = {
      value: FreeqSid.cookie_value(sid),
      httponly: true,
      same_site: :lax,
      secure: !Rails.env.development?,
      expires: 30.days.from_now,
      path: "/"
    }
  end

  def current_session
    sid = session_id
    state = SessionRegistry.instance.get(sid)

    # Stick the sid cookie while we hold OAuth credentials (SASL may still
    # be in flight). App "signed in" is state.authenticated? (SASL).
    write_sid_cookie!(sid) if state.has_credentials?

    oauth_file_log(
      "current_session sid=#{sid[0, 8]} " \
      "sasl=#{state.authenticated?} credentials=#{state.has_credentials?} " \
      "status=#{state.sasl_status} handle=#{state.auth_handle || '-'} " \
      "req_cookies=#{request.cookies.keys.sort.join(',')} " \
      "hdr_bytes=#{request.headers['Cookie'].to_s.bytesize}"
    )

    state
  end

  def expire_cookie!(name)
    name = name.to_s
    return unless request.cookies[name].present? || cookies[name].present?

    cookies.delete(name, path: "/")
    cookies[name] = {
      value: "deleted",
      path: "/",
      expires: 1.year.ago,
      secure: !Rails.env.development?,
      same_site: :lax,
      httponly: true
    }
  rescue StandardError
    nil
  end

  def write_oauth_cookie!(_oauth)
    expire_cookie!("oauth_session")
  end

  def clear_oauth_browser_state!
    session.delete(:oauth)
    session.delete(:freeq_sid)
    %w[oauth_session pending_oauth freeq_session].each { |n| expire_cookie!(n) }
    expire_cookie!(SID_COOKIE)
  end
end
