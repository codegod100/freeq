# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"
require "securerandom"

# Short-lived disk store for in-flight AT Protocol OAuth logins.
#
# Keyed by the OAuth `state` parameter so the /auth/callback can recover
# the PKCE verifier + DPoP key even when the browser does not send the
# encrypted pending_oauth cookie back after the cross-site redirect from
# the PDS (SameSite / cookie-jar edge cases behind reverse proxies).
#
# Files expire after TTL and are deleted on take (one-shot).
class PendingOauthStore
  TTL = 30 * 60 # seconds
  INFO = "freeq-pending-oauth"

  class << self
    def instance
      @instance ||= open
    end

    def open
      raw = ENV.fetch("FREEQ_WEB2_PENDING_OAUTH_DIR", ".dev-data/web2-pending-oauth")
      return NullStore.new if raw.to_s.empty?

      dir = Pathname.new(raw)
      dir = Rails.root.join(dir) if defined?(Rails) && !dir.absolute?
      new(dir)
    rescue StandardError => e
      warn_log("pending oauth store init failed: #{e.class}: #{e.message}")
      NullStore.new
    end

    def warn_log(msg)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(msg)
      else
        warn("[PendingOauthStore] #{msg}")
      end
    end
  end

  def initialize(dir)
    @dir = Pathname(dir)
    FileUtils.mkdir_p(@dir)
  end

  # Save a prepared-login payload Hash (string keys). Returns state.
  def save(state, payload)
    state = state.to_s
    raise ArgumentError, "empty state" if state.empty?

    data = payload.merge(
      "state" => state,
      "created_at" => Time.now.to_i
    )
    atomic_write(path_for(state), JSON.generate(data))
    state
  end

  # Load without deleting. Returns Hash or nil.
  def load(state)
    state = state.to_s
    return nil if state.empty?

    path = path_for(state)
    return nil unless path.exist?

    data = JSON.parse(path.read)
    if expired?(data)
      path.delete rescue nil
      return nil
    end
    data
  rescue StandardError => e
    self.class.warn_log("load pending oauth failed: #{e.class}: #{e.message}")
    nil
  end

  # Load and delete (one-shot). Returns Hash or nil.
  def take(state)
    data = load(state)
    remove(state)
    data
  end

  def remove(state)
    state = state.to_s
    return if state.empty?

    path = path_for(state)
    path.delete if path.exist?
  rescue StandardError
    nil
  end

  # Drop expired files (best-effort; called occasionally).
  def gc!
    @dir.each_child do |path|
      next unless path.file? && path.extname == ".json"

      begin
        data = JSON.parse(path.read)
        path.delete if expired?(data)
      rescue StandardError
        # leave file; next take will fail cleanly
      end
    end
  end

  class NullStore
    def save(_state, _payload) = nil
    def load(_state) = nil
    def take(_state) = nil
    def remove(_state) = nil
    def gc! = nil
  end

  private

  def path_for(state)
    # state is url-safe base64; still sanitize path separators
    safe = state.to_s.gsub(%r{[^A-Za-z0-9_\-]}, "_")
    @dir.join("#{safe}.json")
  end

  def expired?(data)
    created = data["created_at"].to_i
    created <= 0 || (Time.now.to_i - created) > TTL
  end

  def atomic_write(path, text)
    tmp = path.sub_ext("#{path.extname}.#{Process.pid}.tmp")
    File.write(tmp, text)
    File.chmod(0o600, tmp)
    File.rename(tmp, path)
    File.chmod(0o600, path)
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end
end
