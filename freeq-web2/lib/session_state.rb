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
# Explicit load (o_auth.rb → Atproto::OAuth under Zeitwerk).
require_relative "atproto/o_auth"

# In-memory per-session state. One upstream WebSocket per browser session.
#
# Identity model (single source of truth for "signed in"):
#
#   credentials  — Atproto::OAuthSession or :guest
#                  OAuth tokens used *only* to complete SASL. Not app login.
#   SASL / IRC   — API-BEARER present means freeq-server bound a DID on this
#                  connection. That is app authentication.
#
#   authenticated?     → SASL succeeded (DID on the wire)
#   has_credentials?   → we hold OAuth material to run (or re-run) SASL
#   signing_in?        → credentials present, SASL not done yet
#
# UI and policy joins must key off authenticated?, never credentials alone.
class SessionState
  include MonitorMixin

  attr_reader :session_id, :joined, :channels, :channel_members, :irc_out, :irc_in,
              :parent_lookup, :suppress_history_batches, :reaction_cache,
              :policy_response_queue, :current_nick, :known_nicks, :nick_to_did,
              :whois_response_queue, :api_bearer, :last_upstream_error,
              :last_msg_day, :sasl_status
  # OAuth credential bag (or :guest). Prefer has_credentials? / credentials.
  # Writer is custom — see auth= below.
  attr_reader :auth
  attr_accessor :ws_state # :disconnected, :connecting, :registering, :ready
  attr_accessor :whois_response_queue  # set to a Queue when capturing WHOIS replies

  def initialize(session_id)
    super()
    @session_id = session_id
    @joined = Set.new        # routing table: channels we're emitting lines for
    @channels = Set.new      # client-authoritative joined list (persisted)
    @join_sent = Set.new     # channels with an in-flight JOIN (dedupe)
    @join_failed = Set.new   # channels rejected (477 etc.) — allow re-JOIN
    @policy_accept_sent = Set.new # POLICY ACCEPT already issued for channel
    @channel_members = {}
    @nick_to_did = {}   # nick (lowercase) => DID, populated from extended-join/account-notify/account tags
    @irc_out = Queue.new
    @irc_in  = Queue.new
    @auth = :guest
    @ws_state = :disconnected
    @suppress_history_batches = Set.new
    @replay_channels = Set.new  # REST scrollback failed — let JOIN replay render
    @replay_batches = Set.new   # batch ids we're rendering (not suppressing)
    @parent_lookup = {}
    @reaction_cache = {}
    @policy_response_queue = nil  # Set to a Queue when capturing policy NOTICEs
    @recent_rows = {}             # channel => [html rows] for subscribe replay
    @api_bearer = nil             # freeq-server IRC session_id (from API-BEARER NOTICE)
    # :none | :pending | :ok | :failed — app identity tracks this, not OAuth alone
    @sasl_status = :none
    @last_upstream_error = nil    # last connect/run failure (for diagnostics)
    @last_msg_day = {}            # channel/DM key => "YYYY-MM-DD" for date separators
    @task = nil
    @broadcaster = nil
    @reg_phase = :wait_cap_ack  # :wait_cap_ack, :sasl_challenge, :sasl_result
    @task_mutex = Mutex.new
  end

  # ── Auth helpers ──────────────────────────────────────────────────────

  # OAuth token bag for SASL (not "logged in" by itself).
  def credentials
    has_credentials? ? @auth : nil
  end

  def has_credentials?
    @auth.is_a?(Atproto::OAuthSession)
  end

  # App signed-in = DID bound on the IRC connection (SASL 903 + API-BEARER).
  def authenticated?
    has_credentials? && @api_bearer.to_s != "" && @sasl_status == :ok
  end

  def signing_in?
    has_credentials? && !authenticated?
  end

  def auth_nick
    has_credentials? ? @auth.nick : nil
  end

  def auth_handle
    has_credentials? ? @auth.handle : nil
  end

  def auth_did
    has_credentials? ? @auth.did : nil
  end

  # Install OAuth credentials. Does NOT mark the user authenticated until SASL.
  def auth=(value)
    if value.is_a?(Atproto::OAuthSession)
      @auth = value
      @sasl_status = @api_bearer.to_s.empty? ? :pending : :ok
    else
      @auth = :guest
      @api_bearer = nil
      @sasl_status = :none
    end
  end
  alias credentials= auth=

  # ── Client-authoritative channel list ──────────────────────────────
  #
  # freeq-web2 owns the user's joined-channel list. The upstream server
  # is a dumb relay: we persist the list to disk and re-assert it on
  # every fresh WS connect instead of trusting upstream room state.

  # Seed the list from disk (SessionRegistry#get). Adds to @joined too so
  # the broadcaster routes lines for restored channels.
  def restore_channels!(channels)
    synchronize do
      channels.each do |ch|
        c = IrcRender.canonical_channel(ch)
        @channels << c
        @joined << c
      end
    end
  end

  # Join (or re-join) a channel: record it, persist, and route its lines.
  def add_channel!(channel)
    c = IrcRender.canonical_channel(channel)
    synchronize do
      @channels << c
      @joined << c
    end
    persist_channels!
  end

  # Leave a channel: drop from the list, persist, stop routing its lines.
  def remove_channel!(channel)
    c = IrcRender.canonical_channel(channel)
    synchronize do
      @channels.delete(c)
      @joined.delete(c)
      @join_sent.delete(c)
    end
    persist_channels!
  end

  def persist_channels!
    SessionRegistry.instance.persist_channels(@session_id, @channels.to_a)
  rescue StandardError => e
    Rails.logger.warn("persist_channels! failed: #{e.class}: #{e.message}") if defined?(Rails)
  end

  # ── History replay fallback ──────────────────────────────────────────
  #
  # Normally JOIN chathistory replay is suppressed because REST scrollback
  # already rendered it. When REST fails (e.g. 403 on +i/+k channels) or
  # for DMs (no REST history at all), allow the replay to render instead.
  #
  # Keys are lowercased; channel targets keep their leading #/& (never
  # invent one for nick/DM targets).

  def allow_replay!(target)
    synchronize { @replay_channels << history_target_key(target) }
  end

  def replay_allowed?(target)
    synchronize { @replay_channels.include?(history_target_key(target)) }
  end

  def clear_replay!(target)
    synchronize { @replay_channels.delete(history_target_key(target)) }
  end

  # Normalize CHATHISTORY / BATCH / row-cache keys to bare lowercase so
  # channel "#freeq" and Cable room "freeq" hit the same bucket, and DM
  # nicks never get a spurious leading #.
  def history_target_key(target)
    target.to_s.strip.sub(/\A[#&]/, "").downcase
  end

  def track_replay_batch(id)
    synchronize { @replay_batches << id }
  end

  def untrack_replay_batch(id)
    synchronize { @replay_batches.delete(id) }
  end

  def replay_batch?(id)
    synchronize { @replay_batches.include?(id) }
  end

  # Fetch backlog explicitly for a channel we're already joined to (no
  # fresh JOIN → no automatic history replay). Used when REST scrollback
  # is unavailable (e.g. 403 on +i/+k channels).
  def request_backlog!(channel, limit = 50)
    return unless @ws_state == :ready

    enqueue_outbound("CHATHISTORY LATEST #{IrcRender.canonical_channel(channel)} * #{limit}\r\n")
  end

  # Request DM history via CHATHISTORY over WS. Safe to call before the
  # upstream is ready — the request is held until registration finishes.
  def request_dm_backlog!(nick, limit = 50)
    nick = nick.to_s
    return if nick.empty?

    # Always allow the chathistory BATCH for this nick through the
    # broadcaster (DMs have no REST scrollback to suppress against).
    allow_replay!(nick)
    @pending_dm_backlog = [nick, limit]
    flush_pending_dm_backlog!
  end

  def flush_pending_dm_backlog!
    return unless @ws_state == :ready
    return unless @pending_dm_backlog

    nick, limit = @pending_dm_backlog
    @pending_dm_backlog = nil
    enqueue_outbound("CHATHISTORY LATEST #{nick} * #{limit}\r\n")
  end

  # Record a nick → DID mapping (from extended-join, account-notify, or
  # the +account message tag). Case-insensitive nick key.
  def record_nick_did(nick, did)
    return if nick.nil? || nick.empty? || did.nil? || did.empty?
    return unless did.start_with?("did:")
    synchronize { @nick_to_did[nick.downcase] = did }
  end

  # Look up the DID for a nick, or nil if unknown.
  def did_for_nick(nick)
    return nil if nick.nil?
    synchronize { @nick_to_did[nick.downcase] }
  end

  # ── Recent message rows ──────────────────────────────────────────────
  #
  # The broadcaster caches the last N rendered message rows per target
  # (channel or DM nick). ChatChannel#subscribed replays them so
  # broadcasts that raced the subscription aren't lost.
  #
  # Keys use history_target_key — channels keep #, DM nicks stay bare
  # (must match CableReady stream bare + client room param).

  RECENT_ROWS_PER_CHANNEL = 50

  def cache_row(target, html)
    c = history_target_key(target)
    synchronize do
      rows = (@recent_rows[c] ||= [])
      rows << html
      rows.shift while rows.size > RECENT_ROWS_PER_CHANNEL
    end
  end

  # Day key of the last message rendered for a channel/DM (for live date seps).
  def last_msg_day_for(target)
    synchronize { @last_msg_day[history_target_key(target)] }
  end

  def set_last_msg_day(target, day_key)
    return if day_key.to_s.empty?

    synchronize { @last_msg_day[history_target_key(target)] = day_key.to_s }
  end

  # Prepend a date separator if this message is on a new day for the target.
  # Returns html (possibly with separator prefix) and updates last_msg_day.
  def with_date_separator(target, html, time)
    day = IrcRender.day_key(time)
    return html if day.nil?

    prev = last_msg_day_for(target)
    set_last_msg_day(target, day)
    return html if prev == day

    IrcRender.date_separator_html(time) + html
  end

  def recent_rows(target)
    synchronize { (@recent_rows[history_target_key(target)] || []).dup }
  end

  # Drain the cache for a target (one-shot subscribe replay).
  def take_recent_rows(target)
    synchronize { @recent_rows.delete(history_target_key(target)) || [] }
  end

  # Force the WS task to reconnect so it picks up the new auth state.
  # Re-asserts the full client-owned channel list upstream.
  def request_reconnect(upstream_url = nil)
    channels_to_rejoin = synchronize { @channels.to_a }

    # Drop other freeq-web2 sessions for this DID/nick (same process only).
    if has_credentials?
      begin
        SessionRegistry.instance.ghost_siblings!(
          except_sid: @session_id,
          did: @auth.did,
          nick: auth_nick
        )
      rescue StandardError => e
        Rails.logger.warn("ghost_siblings: #{e.class}: #{e.message}") if defined?(Rails)
      end
    end

    disconnect_upstream!(reason: "reconnect")

    return unless upstream_url

    # spawn_upstream_if_needed JOINs only the primary (via
    # finish_registration); queue the rest to flush after registration.
    # Fall back to #freeq when the user has no channel list yet (DM-only
    # or first login) so SASL still re-runs after OAuth restore.
    primary = channels_to_rejoin.first || "#freeq"
    spawn_upstream_if_needed(upstream_url, primary)
    rest = channels_to_rejoin[1..] || []
    @join_sent.merge(rest)
    rest.each { |ch| enqueue_outbound("JOIN #{ch}\r\n") }
  end

  # Drop the upstream IRC connection. Prefer QUIT so the nick is released
  # promptly instead of a half-open TCP hold.
  def disconnect_upstream!(reason: "disconnect")
    @task_mutex.synchronize do
      if @task && @task.alive?
        begin
          enqueue_outbound("QUIT :#{reason}\r\n") if @ws_state == :ready
          sleep 0.15
        rescue StandardError
          nil
        end
        @task.kill
        @task.join(2)
        @task = nil
      end
      @ws_state = :disconnected
      @reg_phase = :wait_cap_ack
      @api_bearer = nil
      # Credentials survive reconnect; SASL must run again on the new socket.
      @sasl_status = has_credentials? ? :pending : :none
      @join_sent.clear
      begin
        @socket&.close
      rescue StandardError
        nil
      end
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

  # Update the live IRC nick (after 433 retry or server force-rename).
  # Public: IrcBroadcaster calls this when painting Guest* renames.
  def apply_nick!(nick)
    return if nick.nil? || nick.empty?
    @current_nick = nick
    @known_nicks ||= Set.new
    @known_nicks << nick
  end

  # Wait for freeq-server's API-BEARER NOTICE after SASL.
  # Re-spawns a dead upstream at most once per SPAWN_COOLDOWN so a down
  # freeq-server cannot thrash. Used by REST history + pre-key upload.
  SPAWN_COOLDOWN = 2.0

  def wait_for_api_bearer(timeout: 10.0, primary: "#freeq")
    b = @api_bearer
    return b if b && !b.empty?

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    upstream = SessionRegistry.instance.upstream_url
    last_spawn = 0.0
    loop do
      b = @api_bearer
      return b if b && !b.empty?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @ws_state == :disconnected && (now - last_spawn) >= SPAWN_COOLDOWN
        spawn_upstream_if_needed(upstream, primary)
        last_spawn = now
      end
      sleep 0.2
    end
    nil
  end

  # freeq-server authorize_channel_read requires the caller's DID to be a
  # *current* channel member. Wait until we see a 353 NAMES roster (proof
  # JOIN landed), or timeout. Issues at most one JOIN (+ policy ACCEPT path
  # may trigger one more from the IRC thread).
  def wait_until_joined(channel, timeout: 8.0)
    ch = IrcRender.canonical_channel(channel)
    return true if channel_members[ch]&.any?

    force_join!(ch) if @ws_state == :ready

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if channel_members[ch]&.any?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.15
    end
    channel_members[ch]&.any? || false
  end

  # Send JOIN even if we already "sent" one (clears sticky join_sent).
  def force_join!(channel)
    ch = IrcRender.canonical_channel(channel)
    add_channel!(ch)
    @join_sent << ch
    @join_failed&.delete(ch)
    enqueue_outbound("JOIN #{ch}\r\n")
    Rails.logger.info("force_join #{ch} (bearer=#{@api_bearer.to_s != ''})") if defined?(Rails)
  end

  # Drive SASL until app identity is real (API-BEARER). OAuth alone is not enough.
  # Call before JOINing policy-gated channels or treating the user as signed in.
  def ensure_authenticated!(upstream_url = nil, timeout: 12.0)
    return false unless has_credentials?
    return true if authenticated?

    upstream = upstream_url || SessionRegistry.instance.upstream_url
    @sasl_status = :pending
    if @task&.alive? && @ws_state == :ready && @api_bearer.to_s.empty?
      log_irc(
        "ensure_authenticated!: credentials for #{auth_handle} but no SASL — reconnecting"
      )
      request_reconnect(upstream)
    elsif !@task&.alive? || @ws_state == :disconnected
      # Fresh connect — open the pipe; registration primary is #freeq so we
      # don't JOIN a policy channel as guest mid-handshake.
      ensure_broadcaster!
      @task_mutex.synchronize do
        if !@task || !@task.alive?
          @task = nil
          @join_sent.clear
          @task = Thread.new { run_upstream(upstream.to_s, "#freeq") }
        end
      end
    elsif @task&.alive? && @ws_state != :ready
      log_irc("ensure_authenticated!: waiting for in-flight SASL (#{@reg_phase}/#{@ws_state})")
    end

    bearer = wait_for_api_bearer(timeout: timeout, primary: "#freeq")
    ok = bearer.to_s != "" && has_credentials?
    @sasl_status = ok ? :ok : (has_credentials? ? :failed : :none)
    log_irc(
      "ensure_authenticated!: sasl=#{@sasl_status} bearer=#{ok ? 'yes' : 'NO'} " \
      "ws=#{@ws_state} phase=#{@reg_phase} handle=#{auth_handle}"
    )
    ok
  end
  alias ensure_irc_authenticated! ensure_authenticated!

  def log_irc(msg)
    Rails.logger.info(msg) if defined?(Rails)
    path = (defined?(Rails) ? Rails.root : Pathname.new(".")).join("log/oauth.log")
    File.open(path, "a") { |f| f.puts("#{Time.now.utc.iso8601} #{msg}") }
  rescue StandardError
    nil
  end

  # After SASL 903 the connection has a DID — re-assert every channel so a
  # prior guest-time JOIN 477 cannot leave us stuck out of +policy channels.
  def rejoin_all_after_sasl!(driver)
    # Drop JOINs queued while we were still a guest (would 477 again).
    keep = []
    begin
      loop do
        line = @irc_out.pop(true)
        keep << line unless line.to_s.start_with?("JOIN ")
      end
    rescue ThreadError
      nil
    end
    keep.each { |l| @irc_out << l }

    chans = synchronize { (@channels.to_a | @joined.to_a).map { |c| IrcRender.canonical_channel(c) } }
    chans = ["#freeq"] if chans.empty?
    @join_sent.clear
    @join_failed = Set.new
    # Keep @policy_accept_sent — ACCEPT is durable per DID; no need to re-spam.
    chans.each do |ch|
      @join_sent << ch
      driver.text("JOIN #{ch}\r\n")
      Rails.logger.info("post-SASL JOIN #{ch}") if defined?(Rails)
    end
  end

  # ── Upstream WS ───────────────────────────────────────────────────────

  # Ensure the upstream IRC WS is running.
  # - Channel targets (#foo / bare channel name): JOIN + client channel list.
  # - DM nicks: never JOIN; only ensure WS + broadcaster (and flush DM backlog).
  #
  # `as_dm:` must be true when the target is a nick (chat#dm). Bare channel
  # names from chat#show omit # and are still channels.
  def spawn_upstream_if_needed(upstream_url, channel, as_dm: false)
    # Credentials without SASL → re-handshake before JOIN/DM (policy channels).
    if has_credentials? && @api_bearer.to_s.empty? && @task&.alive? && @ws_state == :ready
      log_irc(
        "spawn: credentials #{auth_handle} on guest IRC — reconnecting SASL before #{channel}"
      )
      request_reconnect(upstream_url)
      wait_for_api_bearer(timeout: 8.0, primary: as_dm ? "#freeq" : channel)
    end

    if as_dm
      ensure_broadcaster!
      @task_mutex.synchronize do
        if @task && !@task.alive?
          @task = nil
          @ws_state = :disconnected
          @join_sent.clear
        end
        if @task && @task.alive?
          flush_pending_dm_backlog!
          return
        end
        # Prefer an already-joined channel as registration primary so we
        # never JOIN a nick. Fall back to #freeq.
        primary = synchronize { @channels.to_a.first } || "#freeq"
        primary = IrcRender.canonical_channel(primary)
        extras = synchronize { @channels.to_a.map { |c| IrcRender.canonical_channel(c) } } - [primary]
        @join_sent << primary
        @join_sent.merge(extras)
        @task = Thread.new { run_upstream(upstream_url.to_s, primary) }
        extras.each { |ch| enqueue_outbound("JOIN #{ch}\r\n") }
      end
      return
    end

    target = IrcRender.canonical_channel(channel)
    add_channel!(target) # record + persist (client-authoritative)
    ensure_broadcaster!

    @task_mutex.synchronize do
      # Clean up dead thread handles so we can respawn.
      if @task && !@task.alive?
        @task = nil
        @ws_state = :disconnected
        @join_sent.clear # dead WS — its JOINs are void
      end

      if @task && @task.alive?
        # Already connected — JOIN unless one's already in flight.
        # If still mid-SASL (authed, no bearer yet), only mark the channel;
        # rejoin_all_after_sasl! will JOIN after 903.
        unless @join_sent.include?(target)
          @join_sent << target
          if has_credentials? && @api_bearer.to_s.empty? && @ws_state != :ready
            # Mid-SASL — rejoin_all_after_sasl! JOINs after 903 (avoid guest 477).
          else
            enqueue_outbound("JOIN #{target}\r\n")
          end
        end
        flush_pending_dm_backlog!
        return
      end

      # Fresh WS: re-assert our whole channel list — the upstream keeps
      # no reliable room state, so we tell it what we're in on every
      # connect. finish_registration JOINs the primary; the rest flush
      # after registration.
      extras = synchronize { @channels.to_a } - [target]
      @join_sent << target
      @join_sent.merge(extras)
      @task = Thread.new { run_upstream(upstream_url.to_s, target) }
      extras.each { |ch| enqueue_outbound("JOIN #{ch}\r\n") }
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
    @last_upstream_error = nil

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
        # Drain outbound only when ready. Never pop-and-drop during
        # registration — that used to silently discard TAGMSG (reacts) and
        # PRIVMSG enqueued while SASL was still in flight.
        if ws_state == :ready
          begin
            line = irc_out.pop(true)
            driver.text(line)
          rescue ThreadError
            sleep 0.01
          end
        else
          sleep 0.005
        end
      end
    end
  rescue => e
    @last_upstream_error = "#{e.class}: #{e.message}"
    Rails.logger.warn("upstream WS error: #{e.class}: #{e.message}")
  ensure
    was_up = @ws_state != :disconnected
    self.ws_state = :disconnected
    @socket&.close
    if was_up
      begin
        IrcBroadcaster.broadcast_connection_status(self)
      rescue StandardError
        nil
      end
    end
  end

  private

  def send_registration(driver, channel)
    driver.text("CAP LS 302\r\n")
    # Prefer account nick whenever we have OAuth credentials (SASL will follow).
    nick = has_credentials? ? auth_nick : guest_nick
    @desired_nick = auth_nick if has_credentials?
    @nick_collision_tries = 0
    @nick_reclaim_attempts = 0
    @current_nick = nick
    @known_nicks ||= Set.new
    @known_nicks << nick
    @sasl_status = :pending if has_credentials?
    log_irc(
      "send_registration sid=#{@session_id.to_s[0, 8]}… nick=#{nick} " \
      "credentials=#{has_credentials?} handle=#{auth_handle || '-'} primary=#{channel}"
    )
    driver.text("NICK #{nick}\r\n")
    driver.text("USER web2 0 * :freeq-web2\r\n")
    driver.text("CAP REQ :sasl account-notify extended-join account-tag message-tags batch server-time echo-message draft/chathistory\r\n")
    @reg_phase = :wait_cap_ack
  end

  def handle_upstream_line(line, driver, channel)
    # PING/PONG keepalive — don't forward.
    if (token = ping_token(line))
      driver.text("PONG :#{token}\r\n")
      return
    end

    # Capture freeq-server session_id for REST auth (E2EE key upload, etc.).
    # NOTICE * :API-BEARER <session_id> arrives after successful SASL.
    if (bearer = parse_api_bearer_notice(line))
      @api_bearer = bearer
      @sasl_status = :ok if has_credentials?
      log_irc(
        "Captured API-BEARER for session=#{@session_id[0, 8]}… " \
        "sasl=#{@sasl_status} handle=#{auth_handle || '-'}"
      )
      # App identity flips to signed-in only once bearer lands.
      begin
        IrcBroadcaster.broadcast_user_identity(self)
      rescue StandardError
        nil
      end
      return
    end

    # 433 nick in use. Authenticated: temporary preferred_ then retry preferred
    # after SASL. Never web* for authed users. Guests: random web*.
    if line.include?(" 433 ")
      if has_credentials? && auth_nick.to_s != ""
        @desired_nick = auth_nick
        # Post-SASL: keep hammering preferred (our old connection may free it).
        if @ws_state == :ready || @reg_phase == :ready || @reg_phase == :sasl_result
          Rails.logger.info("433 post-auth for #{auth_nick} — reschedule reclaim") if defined?(Rails)
          schedule_nick_reclaim!(driver, force: true)
          irc_in << line
          return
        end
        new_nick = nick_fallback_for_collision(auth_nick)
      else
        new_nick = guest_nick
      end
      apply_nick!(new_nick)
      irc_in << line
      driver.text("NICK #{new_nick}\r\n")
      Rails.logger.info("433 nick in use — retrying as #{new_nick}") if defined?(Rails)
      return
    end

    # Our NICK change confirmed by server (:old!u@h NICK :new).
    if (new_from_nick = parse_self_nick_change(line))
      apply_nick!(new_from_nick)
      begin
        IrcBroadcaster.broadcast_user_identity(self)
      rescue StandardError
        nil
      end
    end

    # Server force-rename (registered nick / Guest*) arrives as NOTICE after
    # registration. Update current_nick before the broadcaster paints UI.
    if (renamed = IrcRender.parse_forced_nick_rename(line))
      apply_nick!(renamed)
      # After SASL, reclaim preferred nick if server parked us on Guest*/tmp.
      if has_credentials? && auth_nick.to_s != "" && !renamed.to_s.casecmp?(auth_nick)
        @desired_nick = auth_nick
        schedule_nick_reclaim!(driver) if @ws_state == :ready || @reg_phase == :sasl_result
      end
      # Fall through so the notice still appears in the message pane.
    end

    # 477/473/… — JOIN rejected. Clear sticky join_sent so we can re-JOIN
    # after SASL. Policy-gated channels need POLICY ACCEPT before JOIN.
    if (failed_ch = parse_join_failure_channel(line))
      @join_sent.delete(failed_ch)
      @join_failed ||= Set.new
      @join_failed << failed_ch
      Rails.logger.warn("JOIN rejected for #{failed_ch}: #{line.to_s[0, 200]}") if defined?(Rails)

      trailing = line.to_s.split(" :", 2)[1].to_s
      if authenticated? && trailing.include?("policy acceptance")
        @policy_accept_sent ||= Set.new
        unless @policy_accept_sent.include?(failed_ch)
          @policy_accept_sent << failed_ch
          Rails.logger.info("POLICY #{failed_ch} ACCEPT (then re-JOIN)") if defined?(Rails)
          driver.text("POLICY #{failed_ch} ACCEPT\r\n")
          # Server needs a beat to store the attestation before JOIN succeeds.
          Thread.new do
            sleep 0.6
            force_join!(failed_ch) if @ws_state == :ready
          rescue StandardError => e
            Rails.logger.warn("policy re-JOIN failed: #{e.class}: #{e.message}") if defined?(Rails)
          end
        end
      elsif has_credentials? && trailing.include?("requires authentication")
        # JOIN as guest while we still hold OAuth — finish SASL, then re-JOIN.
        log_irc("JOIN #{failed_ch} needs SASL — ensuring auth for #{auth_handle}")
        Thread.new do
          begin
            if ensure_authenticated!(SessionRegistry.instance.upstream_url)
              sleep 0.3
              force_join!(failed_ch)
            end
          rescue StandardError => e
            log_irc("auth re-JOIN failed: #{e.class}: #{e.message}")
          end
        end
      end
      # Fall through so the user sees the notice in chat.
    end

    # Registration state machine — each phase may consume the line or
    # fall through to forward it to the broadcaster.
    consumed = false

    case @reg_phase
    when :wait_cap_ack
      if (caps = parse_cap_ack(line))
        log_irc(
          "CAP ACK: #{caps.inspect} credentials=#{has_credentials?} " \
          "handle=#{auth_handle || '-'}"
        )
        if caps.any? { |c| c.casecmp?("sasl") } && has_credentials?
          # Access tokens expire; refresh when we have a refresh_token so
          # SASL pds-oauth getSession doesn't fail with a dead token.
          @sasl_status = :pending
          refresh_oauth_before_sasl!
          driver.text("AUTHENTICATE ATPROTO-CHALLENGE\r\n")
          @reg_phase = :sasl_challenge
          log_irc("Starting SASL ATPROTO-CHALLENGE for #{auth_handle}")
        else
          # No SASL cap or no OAuth credentials — guest IRC.
          log_irc(
            "CAP ACK → guest finish (sasl_cap=#{caps.any? { |c| c.casecmp?('sasl') }} " \
            "credentials=#{has_credentials?})"
          )
          @sasl_status = has_credentials? ? :failed : :none
          finish_registration(driver, channel, after_sasl: false)
        end
        consumed = true
      elsif line =~ / 00[1-4] /
        # Server sent numeric registration without CAP → proceed as guest.
        log_irc("numeric welcome without CAP ACK — guest finish: #{line.to_s[0, 120]}")
        @sasl_status = has_credentials? ? :failed : :none
        finish_registration(driver, channel, after_sasl: false)
        # Don't consume — let user see the welcome numeric.
      end

    when :sasl_challenge
      # Check for DPOP_NONCE notice and update the OAuth session.
      if (nonce = parse_dpop_nonce_notice(line))
        log_irc("DPoP nonce rotated during SASL")
        update_dpop_nonce!(nonce)
        consumed = true
      elsif (challenge_b64 = parse_authenticate_challenge(line))
        begin
          challenge = Atproto::Sasl.parse_challenge(challenge_b64)
          response = Atproto::Sasl.build_response(challenge[:nonce], @auth)
          driver.text("AUTHENTICATE #{response}\r\n")
          @reg_phase = :sasl_result
          log_irc("SASL challenge response sent for #{auth_handle}")
        rescue => e
          log_irc("SASL challenge response failed: #{e.class}: #{e.message}")
          @sasl_status = :failed
          finish_registration(driver, channel, after_sasl: false)
        end
        consumed = true
      elsif line.include?(" 904 ")
        log_irc("SASL 904 during challenge phase: #{line.to_s[0, 200]}")
        @api_bearer = nil
        @sasl_status = :failed
        finish_registration(driver, channel, after_sasl: false)
        consumed = true
      end

    when :sasl_result
      if line.include?(" 903 ")
        log_irc("SASL 903 success for #{auth_handle}")
        @sasl_status = :ok
        # Always NICK preferred after SASL — do NOT apply_nick! first or
        # reclaim_preferred_nick! will no-op and the IRC nick stays on preferred_/Guest*.
        @desired_nick = auth_nick if auth_nick.to_s != ""
        @nick_reclaim_attempts = 0
        reclaim_preferred_nick!(driver, force: true)
        schedule_nick_reclaim!(driver, force: true)
        finish_registration(driver, channel, after_sasl: true)
        begin
          IrcBroadcaster.broadcast_user_identity(self)
        rescue StandardError
          nil
        end
        consumed = true
      elsif line.include?(" 904 ")
        log_irc(
          "SASL 904 failed for #{auth_handle}; credentials kept, IRC is guest. " \
          "line=#{line.to_s[0, 200]}"
        )
        @api_bearer = nil
        @sasl_status = :failed
        @reg_phase = :wait_cap_ack
        finish_registration(driver, channel, after_sasl: false)
        begin
          IrcBroadcaster.broadcast_user_identity(self)
        rescue StandardError
          nil
        end
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
          log_irc("SASL retry failed: #{e.class}: #{e.message}")
          @sasl_status = :failed
          finish_registration(driver, channel, after_sasl: false)
        end
        consumed = true
      end
    end

    # Forward all non-consumed lines to the broadcaster so the user sees
    # server notices, welcome messages, etc.
    irc_in << line unless consumed
  end

  def finish_registration(driver, channel, after_sasl: false)
    driver.text("CAP END\r\n")
    self.ws_state = :ready
    @reg_phase = :ready
    if after_sasl
      # Connection now has a DID — re-JOIN everything (guest 477 is sticky
      # via join_sent otherwise and leaves roster empty forever).
      rejoin_all_after_sasl!(driver)
    else
      driver.text("JOIN #{channel}\r\n")
      @join_sent << IrcRender.canonical_channel(channel)
    end
    flush_pending_dm_backlog!
    flush_outbound(driver)
    # Page subscribed while we were still :connecting — push the final
    # status so the UI does not stay on "connecting…" forever.
    begin
      IrcBroadcaster.broadcast_connection_status(self)
      IrcBroadcaster.broadcast_user_identity(self)
    rescue StandardError => e
      Rails.logger.warn("post-registration broadcast: #{e.class}: #{e.message}") if defined?(Rails)
    end
  end

  # :server 477 nick #chan :need regged nick  → "#chan"
  def parse_join_failure_channel(line)
    line = line.to_s.chomp.delete_suffix("\r")
    # Strip tags
    line = line.sub(/\A@\S+\s+/, "")
    rest = line.start_with?(":") ? line[1..] : line
    parts = rest.split
    return nil unless parts.length >= 4
    return nil unless %w[471 473 474 475 477].include?(parts[1])
    ch = parts[3]
    return nil unless ch.start_with?("#", "&")
    IrcRender.canonical_channel(ch)
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

  # Strip IRCv3 tags + optional :prefix so CAP/AUTHENTICATE parse is reliable.
  # e.g. "@time=… :irc.freeq.at CAP * ACK :sasl …" → "CAP * ACK :sasl …"
  def irc_command_payload(line)
    line = line.to_s.chomp.delete_suffix("\r")
    line = line.sub(/\A@\S+\s+/, "")
    line = line.sub(/\A:[^\s]+\s+/, "")
    line
  end

  # Parse `CAP * ACK :sasl account-notify` (with or without server prefix/tags).
  def parse_cap_ack(line)
    payload = irc_command_payload(line)
    parts = payload.split
    return nil if parts.length < 3
    return nil unless parts[0]&.casecmp?("CAP")
    # CAP <target> ACK :caps…
    ack_i = parts.index { |p| p.casecmp?("ACK") }
    return nil unless ack_i
    caps = parts[(ack_i + 1)..]
    return nil if caps.nil? || caps.empty?

    caps.map { |c| c.delete_prefix(":") }
  end

  def parse_authenticate_challenge(line)
    payload = irc_command_payload(line)
    return nil unless payload.start_with?("AUTHENTICATE ")
    challenge = payload.sub(/\AAUTHENTICATE\s+/, "").strip
    challenge unless challenge.empty? || challenge == "+"
  end

  def parse_dpop_nonce_notice(line)
    return nil unless line.include?("NOTICE") && line.include?("DPOP_NONCE")
    # :server NOTICE target :DPOP_NONCE <nonce>
    if (m = line.match(/DPOP_NONCE\s+(\S+)/))
      m[1]
    end
  end

  # :server NOTICE * :API-BEARER <session_id>
  def parse_api_bearer_notice(line)
    return nil unless line.include?("NOTICE") && line.include?("API-BEARER")
    if (m = line.match(/API-BEARER\s+(\S+)/))
      m[1]
    end
  end

  # Keep the rotated DPoP nonce on disk so a restart doesn't re-auth
  # with a stale nonce (matches freeq-webui apply_dpop_nonce intent).
  def update_dpop_nonce!(nonce)
    return unless has_credentials?

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

  # Server convention: trailing `_` marks a temporary nick to reclaim after SASL.
  # Use preferred_, preferred__, … so we never fall back to a random web* guest.
  def nick_fallback_for_collision(preferred)
    base = preferred.to_s
    base = "user" if base.empty?
    @nick_collision_tries = (@nick_collision_tries || 0) + 1
    "#{base}#{'_' * [@nick_collision_tries, 3].min}"
  end

  # After SASL 903 (or on 433 post-auth), send NICK preferred.
  # force: true always emits NICK even if local @current_nick already matches
  # (local state is often optimistic and wrong vs the server).
  def reclaim_preferred_nick!(driver, force: false)
    desired = (@desired_nick.presence || auth_nick).to_s
    return if desired.empty?
    return if !force && @current_nick.to_s.casecmp?(desired) && !temporary_nick?(@current_nick)

    Rails.logger.info(
      "Reclaiming nick #{desired} (local=#{@current_nick} force=#{force})"
    ) if defined?(Rails)
    begin
      driver.text("NICK #{desired}\r\n")
    rescue StandardError => e
      Rails.logger.warn("reclaim NICK send failed: #{e.class}: #{e.message}") if defined?(Rails)
      return
    end
    # Only optimistic-apply when we were clearly on a temp nick; confirmed via
    # server NICK line / 433 otherwise.
    apply_nick!(desired) if temporary_nick?(@current_nick) || @current_nick.to_s.empty?
  end

  def temporary_nick?(nick)
    n = nick.to_s
    n.empty? || n.end_with?("_") || n.match?(/\AGuest\d+\z/i) || n.match?(/\Aweb[0-9a-f]+\z/i)
  end

  # Retry preferred NICK a few times (sibling QUIT may free the nick).
  def schedule_nick_reclaim!(driver, force: false)
    desired = (@desired_nick.presence || auth_nick).to_s
    return if desired.empty?

    @nick_reclaim_attempts = 0 if force
    max = 8
    Thread.new do
      max.times do |i|
        sleep(0.5 + i * 0.4)
        break unless has_credentials?
        break if !temporary_nick?(@current_nick) && @current_nick.to_s.casecmp?(desired)
        break unless @ws_state == :ready || @reg_phase == :ready || @reg_phase == :sasl_result

        @nick_reclaim_attempts = i + 1
        Rails.logger.info(
          "nick reclaim attempt #{@nick_reclaim_attempts}: NICK #{desired} (local=#{@current_nick})"
        ) if defined?(Rails)
        begin
          driver.text("NICK #{desired}\r\n")
        rescue StandardError => e
          Rails.logger.warn("nick reclaim send failed: #{e.class}: #{e.message}") if defined?(Rails)
          break
        end
      end
    end
  end

  # :oldnick!user@host NICK :newnick  (only if oldnick is us)
  def parse_self_nick_change(line)
    line = line.to_s.chomp.delete_suffix("\r")
    line = line.sub(/\A@\S+\s+/, "")
    return nil unless line.start_with?(":")
    rest = line[1..]
    sp = rest.index(" ") or return nil
    prefix = rest[0...sp]
    after = rest[(sp + 1)..]
    return nil unless after.start_with?("NICK ")
    old = prefix.split("!").first.to_s
    return nil if old.empty?
    return nil unless our_nicks_include?(old)

    new =
      if after.start_with?("NICK :")
        after.sub(/\ANICK :/, "").split(/\s/, 2).first
      else
        after.split(/\s+/, 3)[1]
      end
    new.to_s.empty? ? nil : new
  end

  def our_nicks_include?(nick)
    candidates = [@current_nick, auth_nick, @desired_nick]
    candidates.concat(@known_nicks.to_a) if @known_nicks
    candidates.compact.any? { |n| n.to_s.casecmp?(nick) }
  end

  # Best-effort token refresh before SASL. Existing sessions without a
  # refresh_token (logged in before we stored them) skip this — user must
  # re-sign-in once to pick up a refresh_token.
  #
  # Refresh tokens are single-use (ATProto rotates them). Serialize so two
  # concurrent WS reconnects cannot burn the same RT ("Refresh token replayed").
  def refresh_oauth_before_sasl!
    return unless has_credentials?

    @refresh_mutex ||= Mutex.new
    @refresh_mutex.synchronize { refresh_oauth_before_sasl_locked! }
  rescue StandardError => e
    # Never let refresh kill the upstream WS thread (was: NameError Atproto::OAuth).
    Rails.logger.warn(
      "refresh_oauth_before_sasl! error for #{auth_handle}: #{e.class}: #{e.message}"
    )
  end

  def refresh_oauth_before_sasl_locked!
    if @auth.refresh_token.to_s.empty? ||
       @auth.token_endpoint.to_s.empty? ||
       @auth.client_id.to_s.empty?
      Rails.logger.warn(
        "OAuth session for #{auth_handle} has no refresh_token/endpoint/client_id " \
        "(old disk payload?) — SASL will use the access token as-is; re-login if 904"
      )
      return
    end

    ok = Atproto::OAuth.refresh!(@auth)
    if ok
      Rails.logger.info("OAuth access token refreshed for #{auth_handle}")
      begin
        SessionRegistry.instance.persist_auth(@session_id, @auth)
      rescue StandardError => e
        Rails.logger.warn("persist after refresh failed: #{e.class}: #{e.message}")
      end
    else
      Rails.logger.warn(
        "OAuth refresh failed for #{auth_handle} — SASL may fail until re-login. " \
        "Sign out and sign in again (refresh tokens are single-use; a stale cookie " \
        "or double-refresh burns them)."
      )
    end
  end
end