# frozen_string_literal: true

# ChatReflex replaces freeq-webui's POST mutation routes (send/join/part/topic/react).
# Each method is invoked from the browser via StimulusReflex; the upstream IRC
# line is enqueued on the per-session outbound queue and the upstream WS task
# flushes it once registration completes.
#
# Forms carry `data-reflex-serialize-form="true"` so StimulusReflex serializes
# their field values into `params`. Read form fields via `params[:name]`;
# read static attributes via `element.dataset[:name]`.
class ChatReflex < ApplicationReflex

  # Send a PRIVMSG (or a slash command) to the current channel.
  # Optional form field `reply_to` (parent msgid) → `@+reply=<msgid> PRIVMSG …`.
  def send_message
    channel = canonical_channel(element.dataset[:channel])
    msg = params[:msg].to_s.strip
    reply_to = params[:reply_to].to_s.strip
    logger.info "[ChatReflex#send_message] channel=#{channel} msg=#{msg.inspect} reply_to=#{reply_to.inspect}"
    return if msg.empty?

    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    line =
      if msg.match?(/^\/nick\s+\S/)
        "NICK #{msg[6..].strip}\r\n"
      elsif msg.match?(/^\/whois\s+\S/)
        "WHOIS #{msg[7..].strip}\r\n"
      elsif msg.start_with?("/")
        "#{msg[1..]}\r\n"
      elsif reply_to.present?
        "@+reply=#{IrcRender.escape_tag_value(reply_to)} PRIVMSG #{channel} :#{msg}\r\n"
      else
        "PRIVMSG #{channel} :#{msg}\r\n"
      end
    session.enqueue_outbound(line)

    # Clear the input + reply target via CableReady.
    cable_ready
      .set_value(selector: "#message-input", value: "")
      .set_value(selector: "#reply-to-input", value: "")
      .inner_html(selector: "#reply-banner", html: "")
      .broadcast
  end

  def join
    channel = canonical_channel(params[:channel].presence || element.dataset[:channel])
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    session.enqueue_outbound("JOIN #{channel}\r\n")
    cable_ready.redirect_to(url: "/chat/#{channel.delete('#')}").broadcast
  end

  def part
    channel = canonical_channel(element.dataset[:channel])
    session.joined.delete(channel)
    session.unconfirm_channel!(channel)
    session.channel_members.delete(channel)
    session.enqueue_outbound("PART #{channel}\r\n")

    bare = channel.delete("#")
    current_bare = request.path.to_s[%r{\A/chat/([^/]+)\z}, 1]
    if current_bare && current_bare.casecmp?(bare)
      # Parting the channel we're viewing — go to the channel list.
      cable_ready.redirect_to(url: "/chat").broadcast
    else
      # Parting a sidebar channel we're not viewing — just drop the row.
      cable_ready
        .remove(selector: "#sidebar-channel-#{bare}")
        .broadcast
    end
  end

  def set_topic
    channel = canonical_channel(element.dataset[:channel])
    topic = params[:topic].to_s
    session.enqueue_outbound("TOPIC #{channel} :#{topic}\r\n")
  end

  def react
    channel = canonical_channel(element.dataset[:channel])
    msgid = element.dataset[:msgid].to_s
    emoji = element.dataset[:emoji].to_s
    return if msgid.empty? || emoji.empty?
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    session.enqueue_outbound("@+react=#{IrcRender.escape_tag_value(emoji)};+reply=#{IrcRender.escape_tag_value(msgid)} TAGMSG #{channel}\r\n")
  end

  def unreact
    channel = canonical_channel(element.dataset[:channel])
    msgid = element.dataset[:msgid].to_s
    emoji = element.dataset[:emoji].to_s
    return if msgid.empty? || emoji.empty?
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    session.enqueue_outbound("@+freeq.at/unreact=#{IrcRender.escape_tag_value(emoji)};+reply=#{IrcRender.escape_tag_value(msgid)} TAGMSG #{channel}\r\n")
  end

  private

  def session
    @session ||= SessionRegistry.instance.get(connection.session_id)
  end

  def canonical_channel(s)
    IrcRender.canonical_channel(s)
  end
end