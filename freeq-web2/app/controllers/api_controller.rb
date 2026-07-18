require "net/http"

# frozen_string_literal: true

# API endpoints for client-side interactions.
class ApiController < ApplicationController
  # GET /api/policy/:channel — fetch channel policy via POLICY RULES + INFO.
  def policy
    channel = IrcRender.canonical_channel(params[:channel])
    session = current_session
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)

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

  private

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
