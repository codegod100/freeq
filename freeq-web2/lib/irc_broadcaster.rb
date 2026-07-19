# frozen_string_literal: true

# Turns inbound IRC lines into CableReady DOM ops broadcast on ChatChannel.
# One broadcaster thread per SessionState; stream name is always
# ChatChannel.broadcasting_for(bare_channel) so it matches stream_for(bare).
module IrcBroadcaster
  module_function

  def stream_name(channel)
    bare = channel.to_s.delete("#").downcase
    ChatChannel.broadcasting_for(bare)
  end

  def cable_for(channel)
    CableReady::Channel.new(stream_name(channel))
  end

  # Process a single inbound IRC line for a known viewing context, or
  # fan-out to every joined channel when the line is not channel-scoped.
  def handle(session, line)
    # Server force-renamed us (Guest* / derived nick). Update sidebar widget.
    # session_state already applied the nick; this paints the UI.
    if (renamed = IrcRender.parse_forced_nick_rename(line))
      session.apply_nick!(renamed)
      broadcast_user_identity(session)
      # Fall through so the NOTICE still shows in chat.
    end

    # Forward policy NOTICEs to the capture queue if one is active, and
    # suppress them from the chat output.
    if session.policy_response_queue && policy_notice?(line)
      session.policy_response_queue << line
      return
    end

    # Forward WHOIS reply numerics (330/318/401) to the capture queue.
    if session.whois_response_queue && (line.include?(" 330 ") || line.include?(" 318 ") || line.include?(" 401 "))
      session.whois_response_queue << line
      return
    end

    # Track IRCv3 BATCH so JOIN chathistory is not re-appended (REST already
    # rendered scrollback on page load). When REST failed for the batch's
    # channel (+i/+k → 403), render the replay instead.
    if (batch = IrcRender.parse_batch_line(line))
      id, open, batch_type, batch_channel = batch
      if open && batch_type.to_s.casecmp?("chathistory")
        if batch_channel && session.replay_allowed?(batch_channel)
          session.clear_replay!(batch_channel)
          session.track_replay_batch(id)
        else
          session.suppress_history_batches << id
        end
      elsif !open
        session.suppress_history_batches.delete(id)
        session.untrack_replay_batch(id)
      end
      return
    end

    tags, _ = IrcRender.parse_irc_tags(line)

    # While a suppressed chathistory batch is open (BATCH +id), or the line
    # itself carries a suppressed batch= tag, skip message-pane emit.
    # Deliberately do NOT mark msgids seen here: a suppressed replay (e.g.
    # the login-time JOIN replay) would poison the seen-set, and a later
    # replay we're actually rendering (REST scrollback failed →
    # CHATHISTORY) would be deduped away to nothing.
    bid = tags["batch"].to_s
    in_history_batch =
      if bid.empty?
        session.suppress_history_batches.any?
      else
        !session.replay_batch?(bid) &&
          (session.suppress_history_batches.include?(bid) || bid.start_with?("hist"))
      end

    if in_history_batch
      # Still process NAMES / member changes / reactions.
      unless IrcRender.is_353?(line) || IrcRender.parse_member_change(line) || IrcRender.parse_tagmsg_reaction(line)
        return
      end
    end

    # Reactions are channel-scoped TAGMSG.
    if (rx = IrcRender.parse_tagmsg_reaction(line))
      msgid, emoji, nick, added, ch = rx
      # Cache so chips survive page refresh.
      session.apply_reaction(msgid, emoji, nick, added)
      broadcast_reaction(ch, msgid, emoji, nick, added)
      return
    end

    # NAMES (353) — extract channel from the line if possible.
    if IrcRender.is_353?(line)
      ch = channel_from_353(line) || session.joined.first
      return unless ch
      members = IrcRender.parse_353_members(line)
      map = session.channel_members[ch] ||= {}
      members.each { |e| map[e[:nick]] = e }
      cable_for(ch).inner_html(selector: "#member-panel", html: IrcRender.render_member_list(map)).broadcast
      return
    end

    if (change = IrcRender.parse_member_change(line))
      ch = change[:channel] || session.joined.find { true }
      # Quit has no channel — apply to all joined.
      targets =
        if change[:kind] == :quit
          session.joined.to_a
        else
          [change[:channel]].compact
        end
      targets.each do |target|
        html = apply_member_change(session, target, change)
        cable_for(target).inner_html(selector: "#member-panel", html: html).broadcast if html
      end
      return
    end

    # account-notify: update the member's DID so DMs can resolve nick→DID.
    if (acct = IrcRender.parse_account_did(line))
      prefix_nick = line[1..]&.split("!")&.first
      session.record_nick_did(prefix_nick, acct) if prefix_nick
      session.channel_members.each do |_ch, map|
        entry = map[prefix_nick] if prefix_nick
        if entry
          entry[:account] = acct
        end
      end
      # Re-render any member panel that has this nick.
      prefix_nick = line[1..]&.split("!")&.first
      session.channel_members.each do |ch, map|
        next unless prefix_nick && map.key?(prefix_nick)
        cable_for(ch).inner_html(selector: "#member-panel", html: IrcRender.render_member_list(map)).broadcast
      end
      return
    end

    # Record nick→DID from the +account message tag (account-tag cap).
    # This is the primary source for DM partners we've never seen in a channel.
    record_account_from_tags(session, line)

    # Route to the DM stream so the DM view renders it.
    if (dm_target = dm_target_for(session, line))
      html = IrcRender.render_irc_line(line, parent_lookup: session.parent_lookup, own_nick: session.current_nick, known_nicks: session.known_nicks)
      unless html.empty?
        session.cache_row(dm_target, html)
        cable_for(dm_target).append(selector: "#messages", html: html).broadcast
      end
      return
    end

    # Channel-scoped messages: try each joined channel for should_emit.
    session.joined.each do |ch|
      if (topic = IrcRender.parse_topic_change(line, ch))
        cable_for(ch).text_content(selector: "#channel-topic", text: topic).broadcast
      end

      if (err = IrcRender.parse_channel_error(line, ch))
        ts = Time.now.utc.strftime("%H:%M:%S")
        html = %(<div class="notice"><span class="ts">#{ts}</span><span class="body">#{IrcRender.html_escape(err)}</span></div>)
        session.cache_row(ch, html)
        cable_for(ch).append(selector: "#messages", html: html).broadcast
      end
      next unless IrcRender.should_emit?(line, ch)

      # Edit: +draft/edit=<orig_msgid> on a PRIVMSG replaces the original
      # message row entirely (not just its children — morph only swaps
      # innerHTML, leaving stale attributes and losing the edit button).
      if (edit_target = IrcRender.edit_target(line))
        html = IrcRender.render_irc_line(line, parent_lookup: session.parent_lookup, own_nick: session.current_nick, known_nicks: session.known_nicks)
        next if html.empty?
        cable_for(ch)
          .replace(selector: ".msg[data-msgid=\"#{edit_target}\"]", html: html)
          .broadcast
        next
      end

      # No msgid seen-set: this is IRC, not email. Replay-vs-REST overlap
      # is handled by batch suppression, and DOM-level dups by the client's
      # filterDupes. Requested history (CHATHISTORY) must re-render on
      html = IrcRender.render_irc_line(line, parent_lookup: session.parent_lookup, own_nick: session.current_nick, known_nicks: session.known_nicks)

      session.cache_row(ch, html)
      cable_for(ch).append(selector: "#messages", html: html).broadcast
    end
  rescue => e
    Rails.logger.warn("IrcBroadcaster error: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
  end

  # Extract the DM target (nick) from a nick-targeted PRIVMSG/NOTICE.
  # Returns the nick if this is a DM (target doesn't start with # or &),
  # and it involves us (either as sender or recipient). Returns nil otherwise.
  def dm_target_for(session, line)
    tags, rest_with_prefix = IrcRender.parse_irc_tags(line)
    rest = rest_with_prefix[1..] or return nil
    sp = rest.index(" ") or return nil
    prefix = rest[0...sp]
    cmd_and_args = rest[(sp + 1)..]
    parts = cmd_and_args.split(" ", 3)
    cmd = parts[0].to_s
    return nil unless %w[PRIVMSG NOTICE].include?(cmd)

    target = parts[1].to_s
    return nil if target.start_with?("#", "&")

    # Sender nick
    sender = prefix.split("!").first
    own = session.current_nick
    return nil unless own

    # Is this a DM involving us? Either we're the sender (echo) or the recipient.
    if sender&.casecmp?(own)
      # We sent it — the DM partner is the target
      target
    elsif target.casecmp?(own)
      # We received it — the DM partner is the sender
      sender
    else
      nil
    end
  end

  # Push current IRC identity into the sidebar #user-handle widget on every
  # stream this session is subscribed to (per-room + session stream).
  def broadcast_user_identity(session)
    irc_ok = session.api_bearer.to_s != ""
    handle_html = IrcRender.user_handle_html(
      nick: session.current_nick,
      auth_handle: (session.authenticated? ? session.auth_handle : nil),
      irc_ok: irc_ok && session.authenticated?
    )
    note = IrcRender.user_irc_note_text(
      nick: session.current_nick,
      irc_ok: irc_ok && session.authenticated?,
      authenticated: session.authenticated?
    )

    ops = lambda do |cable|
      cable.outer_html(selector: "#user-handle", html: handle_html)
      if note.empty?
        cable.set_attribute(selector: "#user-irc-note", name: "style", value: "display:none")
        cable.text_content(selector: "#user-irc-note", text: "")
      else
        cable.set_attribute(
          selector: "#user-irc-note",
          name: "style",
          value: "display:block;color:var(--muted);font-size:.65rem;margin-top:.15rem"
        )
        cable.text_content(selector: "#user-irc-note", text: note)
      end
    end

    # Session-wide stream (ChatChannel always joins freeq:session:<id>).
    session_cable = CableReady::Channel.new("freeq:session:#{session.session_id}")
    ops.call(session_cable)
    session_cable.broadcast

    session.joined.each do |ch|
      c = cable_for(ch)
      ops.call(c)
      c.broadcast
    end
  rescue => e
    Rails.logger.warn("broadcast_user_identity: #{e.class}: #{e.message}") if defined?(Rails)
  end

  def broadcast_reaction(channel, msgid, emoji, nick, added)
    payload = {
      msgid: msgid,
      emoji: emoji,
      nick: nick,
      added: added
    }.to_json
    # Custom event so the chat controller can update chips without a full morph.
    cable_for(channel).dispatch_event(
      selector: "#freeq-chat",
      name: "freeq:reaction",
      detail: { msgid: msgid, emoji: emoji, nick: nick, added: added }
    ).broadcast
  rescue => e
    # Fallback: just log; chips will catch up on next history load.
    Rails.logger.warn("broadcast_reaction failed: #{e.class}: #{e.message}")
  end

  # When a policy capture is active, capture ALL nick-directed NOTICEs.
  # The server sends rules text as individual NOTICE lines — the body lines
  # have no policy keywords, so keyword matching would miss them.
  # The parser in ApiController sorts out which lines are relevant.
  def policy_notice?(line)
    return false unless line.include?("NOTICE")
    rest = line.to_s.sub(/\A@\S+\s+/, "") # strip tags
    rest = rest[1..] || rest  # strip leading ':'
    sp = rest.index(" ") or return false
    after_prefix = rest[(sp + 1)..]
    cmd_and_args = after_prefix
    return false unless cmd_and_args.start_with?("NOTICE ")
    # Only capture nick-directed (not channel-directed) NOTICEs.
    target = cmd_and_args.split(" ", 3)[1].to_s
    !target.start_with?("#", "&")
  end

  def channel_from_353(line)
    # :server 353 nick = #chan :nicks
    rest = line.to_s.sub(/\A@\S+\s+/, "")
    parts = rest.split
    idx = parts.index { |p| p.start_with?("#") }
    idx ? parts[idx] : nil
  end

  def apply_member_change(session, channel, change)
    map = session.channel_members[channel] ||= {}
    case change[:kind]
    when :join
      entry = map[change[:nick]] ||= { nick: change[:nick], op: false, halfop: false, voiced: false }
      entry[:account] = change[:account] if change[:account]
      session.record_nick_did(change[:nick], change[:account]) if change[:account]
    when :part, :quit
      map.delete(change[:nick])
    when :mode
      change[:ops].each do |mode_char, adding, target|
        entry = map[target] ||= { nick: target, op: false, halfop: false, voiced: false }
        case mode_char
        when "o" then entry[:op] = adding
        when "h" then entry[:halfop] = adding
        when "v" then entry[:voiced] = adding
        end
      end
    end
    IrcRender.render_member_list(map)
  end

  # Extract the +account tag from a PRIVMSG/NOTICE and record nick→DID.
  # The account-tag capability tags every message with the sender's DID.
  def record_account_from_tags(session, line)
    return unless line.include?("PRIVMSG") || line.include?("NOTICE")
    tags, rest_with_prefix = IrcRender.parse_irc_tags(line)
    acct = tags["account"] || tags["+account"]
    return unless acct && acct.start_with?("did:")
    rest = rest_with_prefix[1..] or return
    sp = rest.index(" ") or return
    prefix = rest[0...sp]
    nick = prefix.split("!").first
    session.record_nick_did(nick, acct) if nick
  end
end
