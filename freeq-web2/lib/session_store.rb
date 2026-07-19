# frozen_string_literal: true

require "openssl"
require "json"
require "fileutils"
require "securerandom"
require "pathname"

require_relative "atproto/o_auth_session"
require_relative "atproto/dpop_key"

# Disk-backed encrypted OAuth session store.
#
# Mirrors freeq-webui's SessionStore (src/state.rs):
#   - one file per browser session_id under a local directory
#   - AES-256-GCM with a per-session key derived via HKDF-SHA256 from a
#     machine-local secret + the session_id
#   - file format: nonce (12) || ciphertext || tag (16)
#
# Env: FREEQ_WEB2_SESSIONS_DIR — default `.dev-data/web2-sessions`.
#      Set empty to disable disk persistence.
class SessionStore
  INFO = "freeq-session-encryption"
  NONCE_LEN = 12
  TAG_LEN = 16
  KEY_LEN = 32

  attr_reader :dir

  # Open or create the store. Returns nil when persistence is disabled.
  def self.open
    raw = ENV.fetch("FREEQ_WEB2_SESSIONS_DIR", ".dev-data/web2-sessions")
    return nil if raw.to_s.empty?

    dir = Pathname.new(raw)
    dir = Rails.root.join(dir) if defined?(Rails) && !dir.absolute?
    new(dir)
  rescue StandardError => e
    warn_log("session store init failed: #{e.class}: #{e.message}")
    nil
  end

  def initialize(dir)
    @dir = Pathname(dir)
    FileUtils.mkdir_p(@dir)
    @machine_key = load_or_create_machine_key
  end

  def save(sid, oauth)
    return if sid.to_s.empty? || oauth.nil?

    path = session_path(sid)
    key = derive_key(sid)
    plaintext = JSON.generate(payload(oauth))
    blob = encrypt(plaintext, key)
    atomic_write(path, blob)
  end

  def load(sid)
    return nil if sid.to_s.empty?

    path = session_path(sid)
    return nil unless path.exist?

    key = derive_key(sid)
    plaintext = decrypt(path.binread, key)
    data = JSON.parse(plaintext)
    Atproto::OAuthSession.from_h(data)
  rescue StandardError => e
    warn_log("load session #{sid[0, 8]}… failed: #{e.class}: #{e.message}")
    nil
  end

  def remove(sid)
    return if sid.to_s.empty?

    path = session_path(sid)
    path.delete if path.exist?
    channels_path(sid).delete if channels_path(sid).exist?
  rescue StandardError => e
    warn_log("remove session #{sid[0, 8]}… failed: #{e.class}: #{e.message}")
  end

  # ── Channel list (client-authoritative) ────────────────────────────
  #
  # freeq-web2 owns the user's joined-channel list — the upstream server
  # is treated as a dumb relay. Persisted (encrypted like the OAuth blob)
  # so the list survives process restarts and can be re-asserted on every
  # fresh WS connect.

  def save_channels(sid, channels)
    return if sid.to_s.empty?

    key = derive_key(sid)
    plaintext = JSON.generate(channels.map(&:to_s))
    atomic_write(channels_path(sid), encrypt(plaintext, key))
  rescue StandardError => e
    warn_log("save channels #{sid[0, 8]}… failed: #{e.class}: #{e.message}")
  end

  def load_channels(sid)
    return [] if sid.to_s.empty?

    path = channels_path(sid)
    return [] unless path.exist?

    key = derive_key(sid)
    data = JSON.parse(decrypt(path.binread, key))
    data.is_a?(Array) ? data.map(&:to_s) : []
  rescue StandardError => e
    warn_log("load channels #{sid[0, 8]}… failed: #{e.class}: #{e.message}")
    []
  end

  private

  def session_path(sid)
    safe = sid.to_s.gsub(%r{[/\\.]}, "_")
    @dir.join("#{safe}.bin")
  end

  def channels_path(sid)
    safe = sid.to_s.gsub(%r{[/\\.]}, "_")
    @dir.join("#{safe}.channels")
  end

  def load_or_create_machine_key
    key_path = @dir.join(".key")
    if key_path.exist?
      bytes = key_path.binread
      raise "session key file has wrong length: #{bytes.bytesize}" unless bytes.bytesize == KEY_LEN

      return bytes
    end

    key = SecureRandom.random_bytes(KEY_LEN)
    atomic_write(key_path, key)
    key
  end

  # HKDF-SHA256(ikm=machine_key, salt=sid, info="freeq-session-encryption") → 32B
  # Matches freeq_sdk::oauth::derive_session_key.
  def derive_key(sid)
    OpenSSL::KDF.hkdf(
      @machine_key,
      salt: sid.to_s,
      info: INFO,
      length: KEY_LEN,
      hash: "SHA256"
    )
  end

  # Must include refresh fields — without them restored sessions skip
  # refresh_oauth_before_sasl! and SASL 904s once the access token expires.
  def payload(oauth)
    {
      "did" => oauth.did,
      "handle" => oauth.handle,
      "access_token" => oauth.access_token,
      "pds_url" => oauth.pds_url,
      "dpop_key" => oauth.dpop_key.serialize,
      "dpop_nonce" => oauth.dpop_nonce,
      "refresh_token" => oauth.refresh_token,
      "token_endpoint" => oauth.token_endpoint,
      "client_id" => oauth.client_id
    }
  end

  def encrypt(plaintext, key)
    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    cipher.encrypt
    cipher.key = key
    nonce = cipher.random_iv
    raise "unexpected GCM iv length #{nonce.bytesize}" unless nonce.bytesize == NONCE_LEN

    ciphertext = cipher.update(plaintext) + cipher.final
    tag = cipher.auth_tag(TAG_LEN)
    nonce + ciphertext + tag
  end

  def decrypt(data, key)
    raise "encrypted session file too short" if data.bytesize < NONCE_LEN + TAG_LEN

    nonce = data.byteslice(0, NONCE_LEN)
    tag = data.byteslice(-TAG_LEN, TAG_LEN)
    ciphertext = data.byteslice(NONCE_LEN...-TAG_LEN)

    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    cipher.decrypt
    cipher.key = key
    cipher.iv = nonce
    cipher.auth_tag = tag
    cipher.update(ciphertext) + cipher.final
  end

  def atomic_write(path, bytes)
    tmp = path.sub_ext("#{path.extname}.#{Process.pid}.tmp")
    File.binwrite(tmp, bytes)
    File.chmod(0o600, tmp)
    File.rename(tmp, path)
    File.chmod(0o600, path)
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  def self.warn_log(msg)
    if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      Rails.logger.warn(msg)
    else
      warn("[SessionStore] #{msg}")
    end
  end

  def warn_log(msg)
    self.class.warn_log(msg)
  end
end
