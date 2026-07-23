require "net/http"

# frozen_string_literal: true

# API endpoints for client-side interactions.
class ApiController < ApplicationController
  # E2EE SDK posts pre-key bundles without a CSRF header; these endpoints
  # are same-origin proxies to freeq-server's public keys API.
  # Upload uses FormData from fetch; same boxd CSRF edge as react/logout.
  # AV start/join/leave are same-origin fetch POSTs from the call UI.
  skip_before_action :verify_authenticity_token,
                     only: %i[upload_keys get_keys upload av_start av_join av_leave av_end]
  # Serving application/javascript via a controller triggers Rails'
  # InvalidCrossOriginRequest on non-XHR GETs (protect_from_forgery).
  # These are public MoQ module scripts — skip forgery entirely for the
  # asset proxy (same as static public/ assets).
  skip_forgery_protection only: :av_asset

  # GET /api/policy/:channel — fetch channel policy via POLICY RULES + INFO.
  def policy
    channel = IrcRender.canonical_channel(params[:channel])
    session = current_session
    # Ensure IRC is up, but do NOT JOIN the policy channel — peeking at a
    # channel's policy (sidebar member-count button on ALL CHANNELS) must
    # not promote it into My Channels or server-side auto-rejoin.
    primary = session.channels.to_a.first || session.joined.first || "#freeq"
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, primary)

    rules_lines = fetch_policy_notices(session, channel, "RULES")
    info_lines = fetch_policy_notices(session, channel, "INFO")

    open_join = rules_lines.empty? &&
                info_lines.any? { |l| l.include?("has no policy") || l.include?("open join") }

    if open_join || (rules_lines.empty? && info_lines.empty?)
      render html: no_policy_html.html_safe
      return
    end

    render html: render_policy_dialog(channel, rules_lines, info_lines).html_safe
  end

  # POST /api/dm/send { nick, msg }
  # Sends a PRIVMSG to a nick (DM). The msg is already encrypted by the browser.
  def dm_send
    nick = params[:nick].to_s
    msg = params[:msg].to_s
    if nick.empty? || msg.empty?
      render json: { error: "nick and msg required" }, status: :bad_request
      return
    end
    session = current_session
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, session.joined.first || "#freeq")
    session.enqueue_outbound("PRIVMSG #{nick} :#{msg}\r\n")
    render json: { ok: true }
  end
  # Returns cached DID if known, otherwise sends WHOIS upstream and waits
  # briefly for the 330 (RPL_WHOISACCOUNT) numeric.
  def did_for_nick
    nick = params[:nick].to_s
    session = current_session
    # Ensure the upstream WS is connected (don't join a channel for DID lookup).
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, session.joined.first || "#freeq")
    # Fast path: already cached from extended-join/account-notify/account-tag.
    did = session.did_for_nick(nick)
    if did
      render json: { did: did, cached: true }
      return
    end

    # Slow path: WHOIS the nick and wait for the account numeric.
    did = resolve_did_via_whois(session, nick)

    # Fallback: REST API /api/v1/users/:nick/whois (works for offline users too).
    if did.nil?
      did = fetch_did_via_rest(nick)
      session.record_nick_did(nick, did) if did
    end

    if did
      render json: { did: did, cached: false }
    else
      render json: { did: nil, error: "Could not resolve DID for #{nick}. The recipient may be offline, a guest, or you may need to share a channel first." }, status: :not_found
    end
  end

  # GET /api/v1/keys/*did — proxy pre-key bundle fetch to upstream freeq-server.
  def get_keys
    did = params[:did].to_s
    if did.empty?
      render json: { error: "did required" }, status: :bad_request
      return
    end
    proxy_upstream_json(:get, "/api/v1/keys/#{URI.encode_www_form_component(did)}")
  end

  # GET /api/v1/og?url= — proxy OpenGraph fetch to freeq-server (SSRF-safe there).
  # Used by client-side link embeds in the channel message pane.
  def og_preview
    url = params[:url].to_s.strip
    # Paste noise: zero-width chars, wrapping angles.
    url = url.gsub(/[\u200B-\u200D\uFEFF\u2060\u00AD]/, "").strip
    url = url.delete_prefix("<").delete_suffix(">")
    if url.empty?
      render json: { error: "url required" }, status: :bad_request
      return
    end
    unless url.match?(/\Ahttps?:\/\//i)
      render json: { error: "Invalid URL" }, status: :bad_request
      return
    end
    # freeq-server may spend up to ~5s fetching + parsing remote HTML.
    proxy_upstream_json(
      :get,
      "/api/v1/og?url=#{URI.encode_www_form_component(url)}",
      read_timeout: 10
    )
  end

  # POST /api/v1/keys — proxy pre-key bundle upload to upstream freeq-server.
  # freeq-server requires Bearer = IRC session_id (from API-BEARER NOTICE).
  # Page load races SASL: wait (throttled re-spawn) before giving up.
  def upload_keys
    session = current_session
    unless session.has_credentials?
      render json: {
        error: "Not signed in — pre-key upload requires AT Protocol login.",
        ws_state: session.ws_state,
        has_bearer: false,
        authenticated: false
      }, status: :unauthorized
      return
    end

    primary = session.joined.first || session.channels.to_a.first || "#freeq"
    bearer = session.wait_for_api_bearer(timeout: 15.0, primary: primary)
    if bearer.nil? || bearer.empty?
      render json: {
        error: "Not authenticated to IRC yet — SASL may still be running or failed. " \
               "Wait for status=connected, or sign out and sign in again.",
        ws_state: session.ws_state,
        has_bearer: false,
        authenticated: false,
        has_credentials: true,
        sasl_status: session.sasl_status,
        last_error: session.last_upstream_error
      }, status: :unauthorized
      return
    end
    proxy_upstream_json(:post, "/api/v1/keys", body: request.raw_post, bearer: bearer)
  end

  # GET /api/irc_status — diagnostic snapshot only (no spawn, no side effects).
  def irc_status
    s = current_session
    render json: {
      ws_state: s.ws_state,
      authenticated: s.authenticated?,
      has_credentials: s.has_credentials?,
      sasl_status: s.sasl_status,
      has_bearer: s.api_bearer.to_s != "",
      nick: s.current_nick,
      did: s.auth_did,
      last_error: s.last_upstream_error
    }
  end

  # ── AV voice sessions ───────────────────────────────────────────────
  # Signaling rides IRC TAGMSG; media is browser ↔ SFU (MoQ). These
  # endpoints enqueue the control-plane lines and proxy roster/token REST.

  # POST /api/av/start { channel, instance, title? }
  def av_start
    channel, instance = av_channel_and_instance
    return if performed?

    title = params[:title].to_s.strip
    tags = [
      "+freeq.at/av-start=",
      "+freeq.at/av-instance=#{IrcRender.escape_tag_value(instance)}"
    ]
    tags << "+freeq.at/av-title=#{IrcRender.escape_tag_value(title)}" if title.present?
    enqueue_av_tagmsg(channel, tags)
    render json: { ok: true, channel: channel, instance: instance }
  end

  # POST /api/av/join { channel, session_id, instance }
  def av_join
    channel, instance = av_channel_and_instance
    return if performed?

    session_id = params[:session_id].to_s.strip
    if session_id.empty?
      render json: { error: "session_id required" }, status: :bad_request
      return
    end
    tags = [
      "+freeq.at/av-join=",
      "+freeq.at/av-instance=#{IrcRender.escape_tag_value(instance)}",
      "+freeq.at/av-id=#{IrcRender.escape_tag_value(session_id)}"
    ]
    enqueue_av_tagmsg(channel, tags)
    render json: { ok: true, channel: channel, session_id: session_id, instance: instance }
  end

  # POST /api/av/leave { channel, session_id, instance? }
  def av_leave
    channel = av_require_channel
    return if performed?

    session_id = params[:session_id].to_s.strip
    if session_id.empty?
      render json: { error: "session_id required" }, status: :bad_request
      return
    end
    instance = params[:instance].to_s.strip
    tags = [
      "+freeq.at/av-leave=",
      "+freeq.at/av-id=#{IrcRender.escape_tag_value(session_id)}"
    ]
    tags << "+freeq.at/av-instance=#{IrcRender.escape_tag_value(instance)}" if instance.present?
    enqueue_av_tagmsg(channel, tags)
    render json: { ok: true }
  end

  # POST /api/av/end { channel, session_id }
  def av_end
    channel = av_require_channel
    return if performed?

    session_id = params[:session_id].to_s.strip
    if session_id.empty?
      render json: { error: "session_id required" }, status: :bad_request
      return
    end
    tags = [
      "+freeq.at/av-end=",
      "+freeq.at/av-id=#{IrcRender.escape_tag_value(session_id)}"
    ]
    enqueue_av_tagmsg(channel, tags)
    render json: { ok: true }
  end

  # GET /api/v1/channels/*channel/sessions — proxy active session for a channel.
  def channel_sessions
    name = params[:channel].to_s
    name = "##{name}" unless name.start_with?("#", "&")
    proxy_upstream_json(:get, "/api/v1/channels/#{URI.encode_www_form_component(name)}/sessions")
  end

  # GET /api/v1/sessions/:id — roster + metadata for MoQ mesh.
  def session_detail
    id = params[:id].to_s
    if id.empty?
      render json: { error: "id required" }, status: :bad_request
      return
    end
    proxy_upstream_json(:get, "/api/v1/sessions/#{URI.encode_www_form_component(id)}")
  end

  # GET /api/v1/av/sessions/:id/token — MoQ JWT (Bearer = IRC session_id).
  def av_session_token
    id = params[:id].to_s
    if id.empty?
      render json: { error: "id required" }, status: :bad_request
      return
    end
    session = current_session
    unless session.has_credentials?
      render json: { error: "Sign in required" }, status: :unauthorized
      return
    end
    primary = session.joined.first || session.channels.to_a.first || "#freeq"
    bearer = session.wait_for_api_bearer(timeout: 8.0, primary: primary)
    if bearer.to_s.empty?
      render json: { error: "Not authenticated to IRC yet" }, status: :unauthorized
      return
    end
    proxy_upstream_json(
      :get,
      "/api/v1/av/sessions/#{URI.encode_www_form_component(id)}/token",
      bearer: bearer
    )
  end

  # GET /av/assets/*path — same-origin proxy for moq-publish/moq-watch modules.
  # Relative imports inside those bundles resolve against this path.
  def av_asset
    path = params[:path].to_s
    unless path.match?(/\A[A-Za-z0-9._\-]+\z/)
      head :bad_request
      return
    end
    base = SessionRegistry.instance.rest_base
    uri = URI("#{base}/av/assets/#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 15
    http.open_timeout = 5
    resp = http.request(Net::HTTP::Get.new(uri.request_uri))
    unless resp.is_a?(Net::HTTPSuccess)
      head resp.code.to_i
      return
    end
    content_type =
      if path.end_with?(".js") then "text/javascript; charset=utf-8"
      elsif path.end_with?(".wasm") then "application/wasm"
      else resp["Content-Type"].presence || "application/octet-stream"
      end
    response.headers["Cache-Control"] = "public, max-age=86400"
    # ES modules may load sibling chunks cross-origin from the upstream host
    # if hashes embed absolute URLs; allow CORP for media workers.
    response.headers["Cross-Origin-Resource-Policy"] = "cross-origin"
    send_data resp.body, type: content_type, disposition: "inline"
  rescue StandardError => e
    Rails.logger.warn("av_asset #{path}: #{e.class}: #{e.message}")
    head :bad_gateway
  end

  # POST /upload — multipart proxy for screenshots/images.
  # Fields: file (required), channel (optional), alt (optional).
  # freeq-server stores private media and returns { url, content_type, size }.
  def upload
    session = current_session
    unless session.has_credentials? && session.auth_did.to_s.start_with?("did:")
      return render json: { error: "Sign in to upload images" }, status: :unauthorized
    end

    # Ensure our IRC connection holds the DID so freeq-server accepts the upload.
    if !session.authenticated?
      session.ensure_authenticated!(SessionRegistry.instance.upstream_url, timeout: 12.0)
    end
    unless session.authenticated?
      return render json: {
        error: "Still signing in to IRC — try again in a moment"
      }, status: :unauthorized
    end

    uploaded = params[:file]
    unless uploaded.respond_to?(:tempfile) || uploaded.respond_to?(:read)
      return render json: { error: "No file provided" }, status: :unprocessable_entity
    end

    io = uploaded.respond_to?(:tempfile) ? uploaded.tempfile : uploaded
    io.rewind if io.respond_to?(:rewind)
    bytes = io.read
    if bytes.nil? || bytes.empty?
      return render json: { error: "Empty file" }, status: :unprocessable_entity
    end
    if bytes.bytesize > 10 * 1024 * 1024
      return render json: { error: "File too large (max 10MB)" }, status: :payload_too_large
    end

    content_type = uploaded.content_type.presence || "application/octet-stream"
    filename = uploaded.original_filename.presence || "screenshot.png"
    channel = params[:channel].to_s
    alt = params[:alt].to_s

    result = proxy_upstream_multipart(
      "/api/v1/upload",
      file_bytes: bytes,
      filename: filename,
      content_type: content_type,
      fields: {
        "did" => session.auth_did,
        "channel" => channel,
        "alt" => alt
      }.reject { |_k, v| v.to_s.empty? }
    )
    render json: result[:json], status: result[:status]
  rescue StandardError => e
    Rails.logger.warn("upload failed: #{e.class}: #{e.message}") if defined?(Rails)
    render json: { error: "Upload failed: #{e.message}" }, status: :bad_gateway
  end

  private

  # Multipart POST to FREEQ_UPSTREAM_REST (no extra gems).
  def proxy_upstream_multipart(path, file_bytes:, filename:, content_type:, fields: {})
    base = SessionRegistry.instance.rest_base
    uri = URI("#{base}#{path}")
    boundary = "----FreeqWeb2#{SecureRandom.hex(16)}"
    body = +""
    fields.each do |name, value|
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
      body << value.to_s
      body << "\r\n"
    end
    body << "--#{boundary}\r\n"
    body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename.to_s.gsub('"', '')}\"\r\n"
    body << "Content-Type: #{content_type}\r\n\r\n"
    body = body.b
    body << file_bytes.b
    body << "\r\n--#{boundary}--\r\n".b

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 60
    http.open_timeout = 10
    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    req["Content-Length"] = body.bytesize.to_s
    req.body = body
    resp = http.request(req)
    json =
      begin
        JSON.parse(resp.body)
      rescue JSON::ParserError
        { "error" => resp.body.to_s.presence || "invalid upstream response", "status" => resp.code.to_i }
      end
    { status: resp.code.to_i, json: json }
  end

  def av_require_auth!
    session = current_session
    unless session.has_credentials? && session.auth_did.to_s.start_with?("did:")
      render json: { error: "Sign in with AT Protocol to use voice" }, status: :unauthorized
      return false
    end
    true
  end

  def av_require_channel
    return nil unless av_require_auth!

    raw = params[:channel].to_s.strip
    if raw.empty?
      render json: { error: "channel required" }, status: :bad_request
      return nil
    end
    IrcRender.canonical_channel(raw)
  end

  def av_channel_and_instance
    channel = av_require_channel
    return [nil, nil] unless channel

    instance = params[:instance].to_s.strip
    if instance.empty? || !instance.match?(/\A[0-9a-f]{8}\z/)
      render json: { error: "instance must be 8 hex chars" }, status: :bad_request
      return [nil, nil]
    end
    [channel, instance]
  end

  def enqueue_av_tagmsg(channel, tags)
    session = current_session
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    line = "@#{tags.join(';')} TAGMSG #{channel}\r\n"
    session.enqueue_outbound(line)
  end

  # Forward a JSON request to FREEQ_UPSTREAM_REST and return the response as-is.
  def proxy_upstream_json(method, path, body: nil, bearer: nil, read_timeout: 5)
    base = SessionRegistry.instance.rest_base
    uri = URI("#{base}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = read_timeout
    http.open_timeout = 3
    req =
      case method
      when :get then Net::HTTP::Get.new(uri.request_uri)
      when :post
        r = Net::HTTP::Post.new(uri.request_uri)
        r["Content-Type"] = "application/json"
        r.body = body.to_s
        r
      else
        raise ArgumentError, "unsupported method #{method}"
      end
    req["Authorization"] = "Bearer #{bearer}" if bearer && !bearer.empty?
    resp = http.request(req)
    render json: (JSON.parse(resp.body) rescue { "error" => resp.body.to_s }),
           status: resp.code.to_i
  rescue StandardError => e
    Rails.logger.warn("proxy_upstream_json #{path}: #{e.class}: #{e.message}")
    render json: { error: "upstream unavailable" }, status: :bad_gateway
  end

  # which carries the account/DID. Gap-based timeout like fetch_policy_notices.
  def resolve_did_via_whois(session, nick)
    deadline = Time.now + 3.0
    did = nil
    queue = Queue.new
    # Set the queue BEFORE sending WHOIS — the response can arrive
    # before we reach the read loop otherwise.
    session.whois_response_queue = queue
    session.enqueue_outbound("WHOIS #{nick}\r\n")
    begin
      while Time.now < deadline
        begin
          line = queue.pop(true) # non-blocking
        rescue ThreadError
          sleep 0.05
          next
        end
        # :server 330 ournick nick did:plc:xxx :is logged in as
        if line.include?(" 330 ") && line.include?("did:")
          parts = line.split(" ")
          idx = parts.index { |p| p.start_with?("did:") }
          did = parts[idx] if idx
          break if did
        end
        # End of WHOIS
        break if line.include?(" 318 ") || line.include?(" 401 ")
      end
    ensure
      session.whois_response_queue = nil
    end
    session.record_nick_did(nick, did) if did
    did
  end

  # Query the upstream REST API /api/v1/users/:nick/whois for the DID.
  # This works even for offline users (via nick_owners).
  def fetch_did_via_rest(nick)
    base = SessionRegistry.instance.rest_base
    uri = URI("#{base}/api/v1/users/#{URI.encode_www_form_component(nick)}/whois")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 3
    http.open_timeout = 3
    begin
      resp = http.get(uri.request_uri)
      return nil unless resp.code == "200"
      data = JSON.parse(resp.body)
      data["did"]&.to_s&.presence
    rescue StandardError
      nil
    end
  end

  # ── Policy NOTICE collection ──────────────────────────────────────────

  # Send POLICY <channel> <subcommand> over the upstream WS and collect
  # nick-directed NOTICE replies. Uses a gap-based timeout: stop after 500ms
  # of silence once the first line arrives (server sends one NOTICE per line).
  # Falls back to a 3s overall deadline as a safety net.
  def fetch_policy_notices(session, channel, subcommand)
    capture = session.start_policy_capture
    session.enqueue_outbound("POLICY #{channel} #{subcommand}\r\n")

    lines = []
    overall_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0

    loop do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if now >= overall_deadline

      # Gap timeout: 1500ms for first line, 500ms between subsequent lines.
      gap = lines.empty? ? 1.5 : 0.5
      remaining = [gap, overall_deadline - now].min
      break if remaining <= 0

      begin
        line = Timeout.timeout(remaining) { capture.pop }
        break unless line
      rescue Timeout::Error
        # Gap elapsed — if we got any lines, we're done.
        break unless lines.empty?
        next
      end

      text = parse_policy_notice(line)
      next unless text

      # Terminal markers — stop collecting.
      if text.include?("has no policy") || text.include?("Policy error")
        lines << text
        break
      end

      # Skip unrelated control notices.
      next if text.start_with?("DPOP_NONCE ", "API-BEARER ")

      lines << text
    end

    session.stop_policy_capture
    lines
  end

  # Parse a user-directed IRC NOTICE trailing text.
  def parse_policy_notice(line)
    line = line.to_s.chomp.delete_suffix("\r")
    # Strip IRCv3 tags if present.
    line = line.sub(/\A@\S+\s+/, "")
    rest = line.sub(/\A:/, "")
    sp = rest.index(" ") or return nil
    after_cmd = rest[(sp + 1)..]
    return nil unless after_cmd.start_with?("NOTICE ")
    rest = after_cmd["NOTICE ".length..]
    target_end = rest.index(" ") or return nil
    target = rest[0...target_end]
    return nil if target.start_with?("#", "&")
    trailing = rest.split(" :", 2)[1]
    trailing
  end

  # ── Policy parsing ────────────────────────────────────────────────────

  def parse_rules_section(lines)
    rules_hash = nil
    body = []
    lines.each do |line|
      t = line.strip
      next if t.empty?
      if t.start_with?("Rules for ")
        if (start = t.index("rules_hash="))
          h = t[start + "rules_hash=".length..].to_s.sub(/[):]+$/, "")
          rules_hash = h unless h.empty?
        end
        next
      end
      next if t.include?("rules text isn't available") ||
              t.include?("Rules text isn't available") ||
              t.start_with?("Policy error") ||
              t.include?("has no policy")
      body << t
    end
    { text: body.join("\n"), rules_hash: rules_hash }
  end

  def parse_info_section(lines)
    info = { version: nil, policy_id: nil, effective: nil, validity: nil,
             requirement: nil, roles: [] }
    lines.each do |line|
      t = line.strip
      next if t.empty? || t.start_with?("Policy for ")
      next if t.include?("has no policy") || t.start_with?("Policy error")
      t = t.lstrip

      if t.start_with?("Version:")
        info[:version] = t.delete_prefix("Version:").strip
      elsif t.start_with?("Policy ID:")
        info[:policy_id] = t.delete_prefix("Policy ID:").strip
      elsif t.start_with?("Effective:")
        info[:effective] = t.delete_prefix("Effective:").strip
      elsif t.start_with?("Validity:")
        raw = t.delete_prefix("Validity:").strip
        info[:validity] = case raw
                          when "JoinTime" then "Checked at join"
                          when "Continuous" then "Checked continuously"
                          else raw
                          end
      elsif t.start_with?("Requirement:")
        info[:requirement] = humanize_requirement(t.delete_prefix("Requirement:").strip)
      elsif t.start_with?("Role '")
        if (match = t.match(/\ARole '([^']+)':\s*(.+)/))
          info[:roles] << { name: match[1], requirement: humanize_requirement(match[2].strip) }
        end
      elsif t.start_with?("Role ")
        if (match = t.match(/\ARole\s+(\w+):\s*(.+)/))
          info[:roles] << { name: match[1], requirement: humanize_requirement(match[2].strip) }
        end
      end
    end
    info
  end

  # Turn DSL dumps like ACCEPT(0b5752...) / ALL(ACCEPT(...), PRESENT(...))
  # into short readable labels.
  def humanize_requirement(raw)
    s = raw.to_s.strip
    return "—" if s.empty?

    if s.start_with?("ACCEPT(")
      hash = s.delete_prefix("ACCEPT(").delete_suffix(")")
      short = hash.length > 10 ? hash[0..9] : hash
      return "Accept channel rules (#{short}…)"
    end
    if s.start_with?("PRESENT(")
      inner = s.delete_prefix("PRESENT(").delete_suffix(")")
      cred = inner.split(",").first.to_s.strip
      label = case cred
              when "github_membership" then "GitHub org member"
              when "github_repo" then "GitHub repo collaborator"
              when "bluesky_follower" then "Bluesky follower"
              when "channel_moderator" then "Moderator appointment"
              else cred
              end
      return "Present credential: #{label}"
    end
    if s.start_with?("PROVE(")
      inner = s.delete_prefix("PROVE(").delete_suffix(")")
      return "Prove: #{inner}"
    end
    if s.start_with?("ALL(")
      out = s.sub("ALL(", "All of: ").delete_suffix(")")
      return out.gsub("ACCEPT(", "accept rules (").gsub("PRESENT(", "credential (")
    end
    if s.start_with?("ANY(")
      out = s.sub("ANY(", "Any of: ").delete_suffix(")")
      return out
    end
    s
  end

  # ── Rendering ─────────────────────────────────────────────────────────

  def render_policy_dialog(channel, rules_lines, info_lines)
    rules = parse_rules_section(rules_lines)
    info = parse_info_section(info_lines)

    sections = +""

    # Rules text
    sections << %(<section class="policy-section">)
    sections << %(<h3 class="policy-heading">Rules</h3>)
    if rules[:text].empty?
      sections << %(<p class="policy-empty">No rules text is stored for this policy.</p>)
    else
      sections << %(<p class="policy-rules-text">#{html_escape(rules[:text])}</p>)
    end
    if (h = rules[:rules_hash])
      short = h.length > 12 ? h[0..11] : h
      sections << %(<p class="policy-hash" title="#{html_escape(h)}">hash · #{html_escape(short)}…</p>)
    end
    sections << %(</section>)

    # Policy info
    if info[:requirement] || info[:version] || info[:policy_id] || info[:effective] || info[:validity]
      sections << %(<section class="policy-section policy-bordered">)
      sections << %(<h3 class="policy-heading">Policy</h3>)
      sections << %(<dl class="policy-dl">)
      sections << kv_row("Version", info[:version]) if info[:version]
      sections << kv_row("Validity", info[:validity]) if info[:validity]
      if info[:effective]
        display = info[:effective].length > 19 ? info[:effective][0..18] : info[:effective]
        sections << kv_row("Effective", display.tr("T", " "))
      end
      sections << kv_row("To join", info[:requirement]) if info[:requirement]
      if (pid = info[:policy_id])
        short = pid.length > 16 ? pid[0..15] : pid
        sections << %(<dt class="policy-dt">Policy ID</dt><dd class="policy-dd policy-mono" title="#{html_escape(pid)}">#{html_escape(short)}…</dd>)
      end
      sections << %(</dl></section>)
    end

    # Roles
    if info[:roles].any?
      sections << %(<section class="policy-section policy-bordered">)
      sections << %(<h3 class="policy-heading">Roles</h3>)
      sections << %(<ul class="policy-roles">)
      info[:roles].each do |role|
        mode = case role[:name].downcase
               when "op", "admin", "owner" then "+o"
               when "moderator", "halfop" then "+h"
               when "voice" then "+v"
               else ""
               end
        mode_badge = mode.empty? ? "" : %(<span class="policy-role-mode">#{mode}</span>)
        sections << %(<li class="policy-role">
          <div class="policy-role-header">
            <span class="policy-role-icon">⚡</span>
            <span class="policy-role-name">#{html_escape(role[:name])}</span>
            #{mode_badge}
          </div>
          <p class="policy-role-req">#{html_escape(role[:requirement])}</p>
        </li>)
      end
      sections << %(</ul></section>)
    end

    %(<div class="policy-body">#{sections}</div>)
  end

  def kv_row(label, value)
    %(<dt class="policy-dt">#{html_escape(label)}</dt><dd class="policy-dd">#{html_escape(value)}</dd>)
  end

  def no_policy_html
    %(<div class="policy-body">
      <p class="policy-open">Open channel — no policy.</p>
      <p class="policy-open-sub">Anyone can join and participate freely.</p>
    </div>)
  end

  def html_escape(s)
    s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
  end
end
