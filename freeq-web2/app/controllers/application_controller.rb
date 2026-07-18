class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :ensure_session_cookie

  private

  def ensure_session_cookie
    cookies.signed[:freeq_session] ||= SecureRandom.hex(16)
  end

  def current_session
    state = SessionRegistry.instance.get(session_id)
    # Restore auth from encrypted cookie if the in-memory state lost it
    # (e.g. server restart).
    if state.auth == :guest && cookies.encrypted[:oauth_session].present?
      begin
        data = JSON.parse(cookies.encrypted[:oauth_session])
        state.auth = Atproto::OAuthSession.from_h(
          did: data["did"],
          handle: data["handle"],
          access_token: data["access_token"],
          pds_url: data["pds_url"],
          dpop_key: Atproto::DpopKey.deserialize(data["dpop_key"]),
          dpop_nonce: data["dpop_nonce"]
        )
      rescue => e
        Rails.logger.warn("Failed to restore OAuth session: #{e.class}: #{e.message}")
        cookies.encrypted[:oauth_session] = nil
      end
    end
    state
  end

  def session_id
    cookies.signed[:freeq_session] ||= SecureRandom.hex(16)
  end
end