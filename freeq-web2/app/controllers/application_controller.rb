class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :ensure_session_cookie

  private

  def ensure_session_cookie
    cookies.signed[:freeq_session] ||= SecureRandom.hex(16)
  end

  def current_session
    SessionRegistry.instance.get(session_id)
  end

  def session_id
    cookies.signed[:freeq_session] ||= SecureRandom.hex(16)
  end
end