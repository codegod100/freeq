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
  delegate :url_helpers, to: "Rails.application.routes"

  # Send a PRIVMSG (or a slash command) to the current channel.
  def send_message
    channel = canonical_channel(element.dataset[:channel])
    msg = params[:msg].to_s.strip
    logger.info "[ChatReflex#send_message] channel=#{channel} msg=#{msg.inspect} element=#{element&.id.inspect} dataset=#{element.dataset.to_h.inspect}"
    return if msg.empty?

    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    line =
      if msg.match?(/^\/nick\s+\S/)
        "NICK #{msg[6..].strip}\r\n"
      elsif msg.match?(/^\/whois\s+\S/)
        "WHOIS #{msg[7..].strip}\r\n"
      elsif msg.start_with?("/")
        "#{msg[1..]}\r\n"
      else
        "PRIVMSG #{channel} :#{msg}\r\n"
      end
    session.enqueue_outbound(line)

    # Clear the input field via CableReady.
    cable_ready.set_value(selector: "#message-input", value: "").broadcast
  end

  def join
    channel = canonical_channel(params[:channel].presence || element.dataset[:channel])
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    session.enqueue_outbound("JOIN #{channel}\r\n")
    cable_ready.redirect_to(url: url_helpers.chat_channel_path(channel.delete("#"))).broadcast
  end

  def part
    channel = canonical_channel(element.dataset[:channel])
    session.joined.delete(channel)
    session.enqueue_outbound("PART #{channel}\r\n")
    cable_ready.redirect_to(url: url_helpers.chat_path).broadcast
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