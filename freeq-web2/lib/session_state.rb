# frozen_string_literal: true

require "set"
require "monitor"
require "socket"
require "openssl"
require "uri"
require "websocket/driver"

# In-memory per-session state, the analog of freeq-webui's SessionHandle.
# One upstream WebSocket connection per browser session; incoming IRC lines
# are buffered and drained by the ChatChannel (StimulusReflex → CableReady).
class SessionState
  include MonitorMixin

  attr_reader :session_id, :joined, :channel_members, :irc_out, :irc_in, :parent_lookup
  attr_accessor :auth   # :guest or { did:, nick:, handle:, oauth: ... } (OAuth port = TODO)
  attr_accessor :ws_state # :disconnected, :connecting, :registering, :ready

  def initialize(session_id)
    super()
    @session_id = session_id
    @joined = Set.new
    @channel_members = {} # channel => { nick => {op:, halfop:, voiced:, nick:} }
    @irc_out = Queue.new    # outbound IRC lines (PRIVMSG/JOIN/…)
    @irc_in  = Queue.new    # inbound IRC lines, drained by the broadcaster
    @auth = :guest
    @ws_state = :disconnected
    @seen_msgids = Set.new
    # Open IRCv3 BATCH ids of type chathistory — suppress message-pane emit
    # (scrollback already loaded via REST).
    @suppress_history_batches = Set.new
    # msgid → { nick:, text: } for reply badge context.
    @parent_lookup = {}
    # msgid → { emoji => Set<nick> } — cached reactions so chips survive refresh.
    @reaction_cache = {}
    @task = nil
    @broadcaster = nil
    @task_mutex = Mutex.new
  end

  attr_reader :suppress_history_batches, :reaction_cache

  # Record a reaction event (from IrcBroadcaster) so chips persist across
  # page refreshes within the same session.
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

  # Merge cached reactions into a history message's reactions hash.
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

  def remember_message(msgid, nick, text)
    return if msgid.to_s.empty?
    synchronize do
      @parent_lookup[msgid] = { nick: nick.to_s, text: text.to_s }
      # Bound memory.
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

  # Returns true if already shown (skip). Marks new ids as seen.
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

  def spawn_upstream_if_needed(upstream_url, channel)
    target = IrcRender.canonical_channel(channel)
    synchronize { @joined << target }
    ensure_broadcaster!

    @task_mutex.synchronize do
      if @task && @task.alive?
        # Already connected — just JOIN the new channel.
        enqueue_outbound("JOIN #{target}\r\n")
        return
      end

      (@joined - [target]).each { |c| enqueue_outbound("JOIN #{c}\r\n") }
      enqueue_outbound("JOIN #{target}\r\n")
      @task = Thread.new { run_upstream(upstream_url.to_s, target) }
    end
  end

  # Drain irc_in and push CableReady ops. One thread per session.
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

  # websocket-driver client I/O callbacks. The driver calls #url and #write.
  attr_reader :url

  def write(data)
    @socket&.write(data)
  end

  # The upstream WS connection task. Mirrors run_upstream_ws in upstream.rs.
  # Supports both ws:// (plaintext) and wss:// (TLS via OpenSSL).
  def run_upstream(upstream_url, channel)
    uri = URI(upstream_url)
    tls = uri.scheme == "wss"
    port = uri.port || (tls ? 443 : 80)
    @url = upstream_url.to_s

    tcp = TCPSocket.new(uri.host, port)
    @socket =
      if tls
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.hostname = uri.host # SNI
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

    # Emit the HTTP upgrade handshake.
    driver.start

    self.ws_state = :connecting

    # Read loop: forward bytes from the socket into the driver parser, and
    # also drain the outbound queue when registered.
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
      elsif ws_state == :ready
        # Drain outbound when upstream is quiet.
        begin
          line = irc_out.pop(true)
          driver.text(line)
        rescue ThreadError
          sleep 0.01
        end
      else
        sleep 0.01
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
    driver.text("NICK #{guest_nick}\r\n")
    driver.text("USER web2 0 * :freeq-web2\r\n")
    driver.text("CAP REQ :sasl account-notify message-tags batch server-time echo-message\r\n")
  end

  def handle_upstream_line(line, driver, channel)
    if (token = ping_token(line))
      driver.text("PONG :#{token}\r\n")
      return
    end

    if line.include?(" 433 ")
      driver.text("NICK #{guest_nick}\r\n")
      return
    end

    case ws_state
    when :registering
      if (caps = parse_cap_ack(line))
        # Guest mode in core port (no OAuth creds). Finish registration.
        driver.text("CAP END\r\n")
        driver.text("JOIN #{channel}\r\n")
        self.ws_state = :ready
        flush_outbound(driver)
        return
      end
      if line =~ / 00[1-4] / # numeric registration without CAP
        driver.text("CAP END\r\n")
        driver.text("JOIN #{channel}\r\n")
        self.ws_state = :ready
        flush_outbound(driver)
      end
    when :ready
      irc_in << line
    end
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

  def parse_cap_ack(line)
    parts = line.split
    return nil unless parts[1] == "CAP" && parts[3] == "ACK"
    parts[5..].map { |c| c.delete_prefix(":") }
  end

  def guest_nick
    "web" + rand(0xffffffff).to_s(16)
  end

  def trim_seen
    return if @seen_msgids.size <= 1000
    @seen_msgids = Set.new(@seen_msgids.to_a.drop(@seen_msgids.size / 2))
  end
end