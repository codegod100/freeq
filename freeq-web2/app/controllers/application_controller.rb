class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  # Set/propagate the signed freeq session id cookie. This id keys the
  # in-memory SessionState that holds the upstream IRC WebSocket.
  before_action :ensure_session_cookie

  private

  def ensure_session_cookie
    cookies.signed[:freeq_session] ||= SecureRandom.hex(16)
  end
end