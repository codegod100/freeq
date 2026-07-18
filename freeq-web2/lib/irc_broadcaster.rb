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
    # Track IRCv3 BATCH so JOIN chathistory is not re-appended (REST already
    # rendered scrollback on page load).
    if (batch = IrcRender.parse_batch_line(line))
      id, open, batch_type = batch
      if open && batch_type.to_s.casecmp?("chathistory")
        session.suppress_history_batches << id
      elsif !open
        session.suppress_history_batches.delete(id)
      end
      return
    end

    tags, _ = IrcRender.parse_irc_tags(line)

    # While a chathistory batch is open (BATCH +id), or the line itself carries
    # a batch= tag (server-stamped history), skip message-pane emit. Still
    # mark msgids so later dups are ignored.
    in_history_batch =
      session.suppress_history_batches.any? ||
      tags["batch"].to_s.start_with?("hist")

    if in_history_batch
      if (mid = tags["msgid"])
        session.check_and_mark_msgid(mid)
      end
      # Still process NAMES / member changes / reactions.
      unless IrcRender.is_353?(line) || IrcRender.parse_member_change(line) || IrcRender.parse_tagmsg_reaction(line)
        return
      end
    end

    # Reactions are channel-scoped TAGMSG.
    if (rx = IrcRender.parse_tagmsg_reaction(line))
      msgid, emoji, nick, added, ch = rx
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

    # Channel-scoped messages: try each joined channel for should_emit.
    session.joined.each do |ch|
      if (topic = IrcRender.parse_topic_change(line, ch))
        cable_for(ch).text_content(selector: "#channel-topic", text: topic).broadcast
      end

      if (err = IrcRender.parse_channel_error(line, ch))
        ts = Time.now.utc.strftime("%H:%M:%S")
        html = %(<div class="notice"><span class="ts">#{ts}</span><span class="body">#{IrcRender.html_escape(err)}</span></div>)
        cable_for(ch).append(selector: "#messages", html: html).broadcast
      end

      next unless IrcRender.should_emit?(line, ch)

      if (mid = line_msgid(line)) && session.check_and_mark_msgid(mid)
        next
      end
      html = IrcRender.render_irc_line(line)
      next if html.empty?

      cable_for(ch).append(selector: "#messages", html: html).broadcast
    end
  rescue => e
    Rails.logger.warn("IrcBroadcaster error: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
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

  def line_msgid(line)
    tags, _ = IrcRender.parse_irc_tags(line)
    tags["msgid"]
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
      map[change[:nick]] ||= { nick: change[:nick], op: false, halfop: false, voiced: false }
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
end
