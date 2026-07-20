# frozen_string_literal: true

# Temporary diagnostics for OAuth session stickiness.
class DebugAuthController < ApplicationController
  def show
    sid = session_id
    state = current_session
    disk = SessionRegistry.instance.session_store&.load(sid)
    render json: {
      freeq_sid_cookie: request.cookies[SID_COOKIE].to_s,
      freeq_sid_rails: session[:freeq_sid].to_s,
      session_id: sid.to_s,
      authenticated: state.authenticated?,
      has_credentials: state.has_credentials?,
      sasl_status: state.sasl_status,
      has_bearer: state.api_bearer.to_s != "",
      handle: state.auth_handle,
      disk_handle: (disk ? disk.handle : nil),
      cookie_names: request.cookies.keys.sort,
      cookie_header_bytes: request.headers["Cookie"].to_s.bytesize
    }
  end

  # GET /debug/clear_fat_cookies — wipe legacy multi-KB auth cookies.
  def clear_fat_cookies
    %i[oauth_session pending_oauth].each do |name|
      cookies.delete(name, path: "/")
      cookies[name] = {
        value: "",
        path: "/",
        expires: 1.year.ago,
        secure: !Rails.env.development?,
        same_site: :lax,
        httponly: true
      }
    end
    redirect_to "/debug/auth"
  end

  # GET /debug/impersonate_latest — attach latest disk OAuth to this browser.
  def impersonate_latest
    store = SessionRegistry.instance.session_store
    return render(plain: "no store", status: 500) unless store

    bins = Dir[store.dir.join("*.bin").to_s].sort_by { |p| -File.mtime(p).to_i }
    return render(plain: "no auth bins", status: 404) if bins.empty?

    sid_disk = File.basename(bins.first, ".bin")
    oauth = store.load(sid_disk)
    return render(plain: "load failed", status: 500) unless oauth

    sid = session_id
    state = SessionRegistry.instance.get(sid)
    state.auth = oauth
    SessionRegistry.instance.persist_auth(sid, oauth)
    cookies.delete(:oauth_session)
    cookies.delete(:pending_oauth)
    bind_freeq_session!(sid)
    oauth_file_log("impersonate_latest disk_sid=#{sid_disk} browser_sid=#{sid} handle=#{oauth.handle}")

    redirect_to "/debug/auth"
  end
end
