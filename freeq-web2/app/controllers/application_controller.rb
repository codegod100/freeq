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
    # Registry restores from the encrypted disk store on first touch.
    # Cookie is a secondary path — also used to backfill refresh fields
    # that older disk payloads omitted (refresh_token / token_endpoint /
    # client_id), without which SASL 904s after the access token expires.
    if cookies.encrypted[:oauth_session].present?
      begin
        data = JSON.parse(cookies.encrypted[:oauth_session])
        cookie_oauth = Atproto::OAuthSession.from_h(data)
        if state.auth == :guest
          state.auth = cookie_oauth
          SessionRegistry.instance.persist_auth(session_id, cookie_oauth)
          # Disk was empty — reconnect so SASL runs with the restored OAuth.
          if state.ws_state == :ready && state.api_bearer.to_s.empty?
            state.request_reconnect(SessionRegistry.instance.upstream_url)
          end
        elsif state.authenticated? && needs_refresh_backfill?(state.auth, cookie_oauth)
          # Only backfill when disk has NO refresh_token. Never overwrite a
          # disk RT with a cookie RT (cookie can hold an already-rotated RT).
          backfill_refresh_fields!(state.auth, cookie_oauth)
          SessionRegistry.instance.persist_auth(session_id, state.auth)
          Rails.logger.info(
            "Backfilled OAuth refresh fields for #{state.auth_handle} from cookie"
          )
          if state.api_bearer.to_s.empty?
            state.request_reconnect(SessionRegistry.instance.upstream_url)
          end
        end
      rescue StandardError => e
        Rails.logger.warn("Failed to restore OAuth session: #{e.class}: #{e.message}")
        cookies.delete(:oauth_session) if state.auth == :guest
      end
    end

    # After a background token refresh, rewrite the cookie so the next
    # process restart does not re-use a burned (single-use) refresh token.
    if state.authenticated? && SessionRegistry.instance.take_cookie_sync!(session_id)
      write_oauth_cookie!(state.auth)
    end

    state
  end

  def needs_refresh_backfill?(disk, cookie)
    disk.refresh_token.to_s.empty? && cookie.refresh_token.to_s != ""
  end

  def backfill_refresh_fields!(disk, cookie)
    disk.refresh_token = cookie.refresh_token if disk.refresh_token.to_s.empty?
    disk.token_endpoint = cookie.token_endpoint if disk.token_endpoint.to_s.empty?
    disk.client_id = cookie.client_id if disk.client_id.to_s.empty?
  end

  def write_oauth_cookie!(oauth)
    cookies.encrypted[:oauth_session] = {
      value: JSON.generate(oauth.to_h),
      httponly: true,
      same_site: :lax,
      expires: 30.days.from_now
    }
  end

  def session_id
    ensure_session_cookie
    cookies.signed[:freeq_session]
  end
end