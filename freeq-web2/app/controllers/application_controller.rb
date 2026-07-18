# frozen_string_literal: true

class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :ensure_session_cookie

  private

  def ensure_session_cookie
    cookies.signed[:freeq_session] ||= {
      value: SecureRandom.hex(16),
      httponly: true,
      same_site: :lax,
      expires: 30.days.from_now
    }
  end

  def current_session
    state = SessionRegistry.instance.get(session_id)
    # Registry already restores from the encrypted disk store on first
    # touch. Fall back to the encrypted cookie if disk had nothing
    # (e.g. sessions dir wiped but browser still has the cookie).
    if state.auth == :guest && cookies.encrypted[:oauth_session].present?
      begin
        data = JSON.parse(cookies.encrypted[:oauth_session])
        oauth = Atproto::OAuthSession.from_h(data)
        state.auth = oauth
        SessionRegistry.instance.persist_auth(session_id, oauth)
      rescue StandardError => e
        Rails.logger.warn("Failed to restore OAuth session: #{e.class}: #{e.message}")
        cookies.delete(:oauth_session)
      end
    end
    state
  end

  def session_id
    ensure_session_cookie
    cookies.signed[:freeq_session]
  end
end