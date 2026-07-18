# frozen_string_literal: true

require "set"
require "monitor"
require "socket"
require "openssl"
require "uri"
require "base64"
require "json"
require "websocket/driver"

require_relative "atproto/sasl"

# In-memory per-session state. One upstream WebSocket per browser session.
# When authenticated (OAuth), the WS task performs SASL ATPROTO-CHALLENGE;
# otherwise it registers as a guest.
class SessionState
  include MonitorMixin

  attr_reader :session_id, :joined, :channel_members, :irc_out, :irc_in,
              :parent_lookup, :suppress_history_batches, :reaction_cache,
              :policy_response_queue
  attr_accessor :auth   # :guest or Atproto::OAuthSession
  attr_accessor :ws_state # :disconnected, :connecting, :registering, :ready

  def initialize(session_id)
    super()
    @session_id = session_id
    @joined = Set.new
    @channel_members = {}
    @irc_out = Queue.new
    @irc_in  = Queue.new
    @auth = :guest
    @ws_state = :disconnected
    @seen_msgids = Set.new
    @suppress_history_batches = Set.new
    @parent_lookup = {}
    @reaction_cache = {}
    @policy_response_queue = nil  # Set to a Queue when capturing policy NOTICEs
    @task = nil
    @broadcaster = nil
    @reg_phase = :wait_cap_ack  # :wait_cap_ack, :sasl_challenge, :sasl_result
    @task_mutex = Mutex.new
  end

  # ── Auth helpers ──────────────────────────────────────────────────────

  def authenticated?
    @auth.is_a?(Atproto::OAuthSession)
  end

  def auth_nick
    authenticated? ? @auth.nick : nil
  end

  def auth_handle
    authenticated? ? @auth.handle : nil
  end

  # Force the WS task to reconnect so it picks up the new auth state.
  # If any channels were previously joined, immediately respawn with the
  # first one so the caller doesn't need to navigate to a channel page.
  def request_reconnect(upstream_url = nil)
    @task_mutex.synchronize do
      if @task && @task.alive?
        @task.kill
        @task.join(2) # give it a moment to die
        @task = nil
      end
      @ws_state = :disconnected
      @reg_phase = :wait_cap_ack
    end

    # Respawn outside the mutex — spawn_upstream_if_needed acquires @task_mutex.
    if upstream_url && !@joined.empty?
      first_channel = @joined.first
      spawn_upstream_if_needed(upstream_url, first_channel)
    end
  end

  # ── Reaction cache ────────────────────────────────────────────────────

  def apply_reaction(msgid, emoji, nick, added)
    return if msgid.to_s.empty? || emoji.to_s.empty?
    synchronize do
      @reaction_cache[msgid] ||= {}
      if added
        @reaction_cache[msgid][emoji] ||= Set.new
        @reaction_cache[msgid][emoji] << nick
      else
        @reaction_cache[msgid][emoji]&.delete(nick)
        @reaction_cache[msgid].delete(emoji) if @reaction_cache[msgid][emoji]&.empty?
        @reaction_cache.delete(msgid) if @reaction_cache[msgid].empty?
      end
    end
  end

  def merged_reactions(msgid, rest_reactions)
    cached = @reaction_cache[msgid]
    merged = {}
    rest_reactions&.each { |emoji, nicks| merged[emoji] = nicks.dup }
    cached&.each do |emoji, nicks|
      set = (merged[emoji] || []).to_set
      set.merge(nicks)
      merged[emoji] = set.to_a
    end
    merged
  end

  # ── Message + msgid tracking ──────────────────────────────────────────

  def remember_message(msgid, nick, text)
    return if msgid.to_s.empty?
    synchronize do
      @parent_lookup[msgid] = { nick: nick.to_s, text: text.to_s }
      if @parent_lookup.size > 2000
        @parent_lookup = @parent_lookup.to_a.last(1000).to_h
      end
    end
  end

  def note_seen_msgids(ids)
    synchronize do
      ids.each { |id| @seen_msgids << id unless id.to_s.empty? }
      trim_seen
    end
  end

  def check_and_mark_msgid(msgid)
    return false if msgid.to_s.empty?
    synchronize do
      return true if @seen_msgids.include?(msgid)
      @seen_msgids << msgid
      trim_seen
      false
    end
  end

  def enqueue_outbound(line)
    @irc_out << line
  end

  # Start capturing policy NOTICEs into a dedicated queue.
  # The broadcaster will forward policy-related NOTICEs to this queue.
  # Stops any previous capture first.
  def start_policy_capture
    @policy_response_queue = Queue.new
  end

  # Stop capturing and return the queue (may still have pending items).
  def stop_policy_capture
    q = @policy_response_queue
    @policy_response_queue = nil
    q
  end

  # ── Upstream WS ───────────────────────────────────────────────────────

  def spawn_upstream_if_needed(upstream_url, channel)
    target = IrcRender.canonical_channel(channel)
    synchronize { @joined << target }
    ensure_broadcaster!

    @task_mutex.synchronize do
      # Clean up dead thread handles so we can respawn.
      if @task && !@task.alive?
        @task = nil
        @ws_state = :disconnected
      end

      if @task && @task.alive?
        # Already connected — just JOIN the new channel.
        enqueue_outbound("JOIN #{target}\r\n")
        return
      end

      # Spawn a fresh WS task. finish_registration will JOIN the target
      # channel directly. We don't re-join all of @joined because it
      # accumulates channels from browsing — only join what the user
      # is currently viewing.
      @task = Thread.new { run_upstream(upstream_url.to_s, target) }
    end
  end

  def ensure_broadcaster!
    @task_mutex.synchronize do
      return if @broadcaster && @broadcaster.alive?
      @broadcaster = Thread.new do
        loop do
          line = @irc_in.pop
          IrcBroadcaster.handle(self, line)
        rescue => e
          Rails.logger.warn("session broadcaster error: #{e.class}: #{e.message}")
        end
      end
    end
  end

  # websocket-driver client I/O callbacks.
  attr_reader :url

  def write(data)
    @socket&.write(data)
  end

  # The upstream WS connection task. Mirrors run_upstream_ws in upstream.rs.
  # Supports ws:// and wss://. When authenticated, performs SASL
  # ATPROTO-CHALLENGE before completing IRC registration.
  def run_upstream(upstream_url, channel)
    uri = URI(upstream_url)
    tls = uri.scheme == "wss"
    port = uri.port || (tls ? 443 : 80)
    @url = upstream_url.to_s
    @reg_phase = :wait_cap_ack

    tcp = TCPSocket.new(uri.host, port)
    @socket =
      if tls
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.hostname = uri.host
        ssl.sync_close = true
        ssl.connect
        ssl
      else
        tcp
      end

    driver = WebSocket::Driver.client(self)
    driver.on(:open)    { self.ws_state = :registering; send_registration(driver, channel) }
    driver.on(:message) do |event|
      event.data.to_s.each_line do |raw|
        raw.chomp!
        next if raw.empty?
        handle_upstream_line(raw, driver, channel)
      end
    end
    driver.on(:close) do
      self.ws_state = :disconnected
      @socket&.close
    end
    driver.on(:error) do |event|
      Rails.logger.warn("upstream WS driver error: #{event.message}")
    end

    driver.start
    self.ws_state = :connecting

    loop do
      chunk =
        begin
          @socket.read_nonblock(4096)
        rescue IO::WaitReadable
          nil
        rescue EOFError, Errno::ECONNRESET, OpenSSL::SSL::SSLError
          break
        end
      if chunk
        driver.parse(chunk)
      else
        # Always try to drain the outbound queue, regardless of ws_state.
        # Messages enqueued before :ready (e.g. JOINs) will be sent once
        # the registration handshake completes via flush_outbound.
        begin
          line = irc_out.pop(true)
          driver.text(line) if ws_state == :ready
        rescue ThreadError
          sleep 0.01
        end
        sleep 0.005 if ws_state != :ready
      end
    end
  rescue => e
    Rails.logger.warn("upstream WS error: #{e.class}: #{e.message}")
  ensure
    self.ws_state = :disconnected
    @socket&.close
  end

  private

  def send_registration(driver, channel)
    driver.text("CAP LS 302\r\n")
    nick = authenticated? ? auth_nick : guest_nick
    driver.text("NICK #{nick}\r\n")
    driver.text("USER web2 0 * :freeq-web2\r\n")
    driver.text("CAP REQ :sasl account-notify message-tags batch server-time echo-message\r\n")
    @reg_phase = :wait_cap_ack
  end

  def handle_upstream_line(line, driver, channel)
    # PING/PONG keepalive — don't forward.
    if (token = ping_token(line))
      driver.text("PONG :#{token}\r\n")
      return
    end

    # 433 nick in use → retry, but still forward so user sees the error.
    if line.include?(" 433 ")
      irc_in << line
      driver.text("NICK #{guest_nick}\r\n")
      return
    end

    # Registration state machine — each phase may consume the line or
    # fall through to forward it to the broadcaster.
    consumed = false

    case @reg_phase
    when :wait_cap_ack
      if (caps = parse_cap_ack(line))
        if caps.any? { |c| c.casecmp?("sasl") } && authenticated?
          # Start SASL ATPROTO-CHALLENGE.
          driver.text("AUTHENTICATE ATPROTO-CHALLENGE\r\n")
          @reg_phase = :sasl_challenge
          Rails.logger.info("Starting SASL ATPROTO-CHALLENGE for #{auth_handle}")
        else
          # No SASL or not authenticated — guest mode.
          finish_registration(driver, channel)
        end
        consumed = true
      elsif line =~ / 00[1-4] /
        # Server sent numeric registration without CAP → proceed as guest.
        finish_registration(driver, channel)
        # Don't consume — let user see the welcome numeric.
      end

    when :sasl_challenge
      # Check for DPOP_NONCE notice and update the OAuth session.
      if (nonce = parse_dpop_nonce_notice(line))
        Rails.logger.debug("DPoP nonce rotated during SASL: #{nonce}")
        update_dpop_nonce!(nonce)
        consumed = true
      elsif (challenge_b64 = parse_authenticate_challenge(line))
        begin
          challenge = Atproto::Sasl.parse_challenge(challenge_b64)
          response = Atproto::Sasl.build_response(challenge[:nonce], @auth)
          driver.text("AUTHENTICATE #{response}\r\n")
          @reg_phase = :sasl_result
          Rails.logger.info("SASL challenge response sent for #{auth_handle}")
        rescue => e
          Rails.logger.warn("SASL challenge response failed: #{e.class}: #{e.message}")
          finish_registration(driver, channel)
        end
        consumed = true
      end

    when :sasl_result
      if line.include?(" 903 ")
        Rails.logger.info("SASL authentication successful for #{auth_handle}")
        finish_registration(driver, channel)
        consumed = true
      elsif line.include?(" 904 ")
        Rails.logger.warn("SASL authentication failed; proceeding as guest")
        @reg_phase = :wait_cap_ack
        finish_registration(driver, channel)
        consumed = true
      elsif (nonce = parse_dpop_nonce_notice(line))
        update_dpop_nonce!(nonce)
        consumed = true
      elsif (challenge_b64 = parse_authenticate_challenge(line))
        # Server re-issues a challenge (DPoP retry).
        begin
          challenge = Atproto::Sasl.parse_challenge(challenge_b64)
          response = Atproto::Sasl.build_response(challenge[:nonce], @auth)
          driver.text("AUTHENTICATE #{response}\r\n")
        rescue => e
          Rails.logger.warn("SASL retry failed: #{e.class}: #{e.message}")
          finish_registration(driver, channel)
        end
        consumed = true
      end
    end

    # Forward all non-consumed lines to the broadcaster so the user sees
    # server notices, welcome messages, etc.
    irc_in << line unless consumed
  end

  def finish_registration(driver, channel)
    driver.text("CAP END\r\n")
    driver.text("JOIN #{channel}\r\n")
    self.ws_state = :ready
    @reg_phase = :ready
    flush_outbound(driver)
  end

  def flush_outbound(driver)
    begin
      loop { driver.text(irc_out.pop(true)) }
    rescue ThreadError
      nil
    end
  end

  def ping_token(line)
    line = line.chomp
    return nil unless line.start_with?(":")
    rest = line[1..]
    sp = rest.index(" ") or return nil
    after = rest[(sp + 1)..]
    return after[5..].delete_prefix(":") if after.start_with?("PING ")
    nil
  end

  # Parse `:server CAP * ACK :sasl account-notify` into the list of caps.
  def parse_cap_ack(line)
    parts = line.split
    return nil unless parts.length >= 4
    return nil unless parts[1]&.casecmp?("CAP") && parts[3]&.casecmp?("ACK")
    caps = parts[4..]
    return nil if caps.nil? || caps.empty?
    caps.map { |c| c.delete_prefix(":") }
  end

  def parse_authenticate_challenge(line)
    return nil unless line.start_with?("AUTHENTICATE ")
    challenge = line.sub("AUTHENTICATE ", "").strip
    challenge unless challenge.empty? || challenge == "+"
  end

  def parse_dpop_nonce_notice(line)
    return nil unless line.include?("NOTICE") && line.include?("DPOP_NONCE")
    # :server NOTICE target :DPOP_NONCE <nonce>
    if (m = line.match(/DPOP_NONCE\s+(\S+)/))
      m[1]
    end
  end

  # Keep the rotated DPoP nonce on disk so a restart doesn't re-auth
  # with a stale nonce (matches freeq-webui apply_dpop_nonce intent).
  def update_dpop_nonce!(nonce)
    return unless authenticated?

    @auth.dpop_nonce = nonce
    begin
      SessionRegistry.instance.persist_auth(@session_id, @auth)
    rescue StandardError => e
      Rails.logger.warn("persist dpop_nonce failed: #{e.class}: #{e.message}") if defined?(Rails)
    end
  end

  def guest_nick
    "web" + rand(0xffffffff).to_s(16)
  end

  def trim_seen
    return if @seen_msgids.size <= 1000
    @seen_msgids = Set.new(@seen_msgids.to_a.drop(@seen_msgids.size / 2))
  end
end