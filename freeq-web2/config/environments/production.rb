require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true
  config.active_job.queue_adapter = :async

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # boxd (and most reverse proxies) terminate TLS in front of Puma.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # Service worker + health must stay reachable on the plain local port too.
  config.ssl_options = {
    redirect: {
      exclude: ->(request) {
        path = request.path.to_s
        path == "/up" || path == "/service-worker" || path == "/manifest"
      }
    }
  }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # DNS rebinding protection — allow boxd + any FREEQ_PUBLIC_URL host.
  config.hosts.clear
  config.hosts << "freeq.boxd.sh"
  config.hosts << /.*\.boxd\.sh/
  if (pub = ENV["FREEQ_PUBLIC_URL"].to_s).present?
    begin
      config.hosts << URI(pub).host
    rescue StandardError
      nil
    end
  end
  # Skip DNS rebinding protection for the default health check endpoint.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # ActionCable from the public origin.
  config.action_cable.url = ENV.fetch("ACTION_CABLE_URL", "wss://freeq.boxd.sh/cable")
  config.action_cable.allowed_request_origins = [
    "https://freeq.boxd.sh",
    %r{\Ahttps://.*\.boxd\.sh\z}
  ]
  if (pub = ENV["FREEQ_PUBLIC_URL"].to_s).present?
    config.action_cable.allowed_request_origins << pub
  end
end
