# frozen_string_literal: true

# Serves PWA bits with correct Content-Type and short/no cache.
# Static public/ files are year-cached by production config, which would
# pin an old service worker forever — so SW lives under app/views/pwa/.
class PwaController < ApplicationController
  skip_forgery_protection
  skip_before_action :ensure_session_cookie

  def service_worker
    path = Rails.root.join("app/views/pwa/service-worker.js")
    return head(:not_found) unless path.exist?

    response.set_header("Cache-Control", "no-cache, no-store, must-revalidate, max-age=0")
    response.set_header("Service-Worker-Allowed", "/")
    send_file path,
              type: "application/javascript; charset=utf-8",
              disposition: "inline"
  end

  def manifest
    response.set_header("Cache-Control", "public, max-age=300")
    render template: "pwa/manifest",
           formats: [:json],
           layout: false,
           content_type: "application/manifest+json"
  end
end
