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
  # Optional form field `edit_to` (original msgid) → `@+draft/edit=<msgid> PRIVMSG …`.
  def send_message
    channel = canonical_channel(element.dataset[:channel])
    msg = params[:msg].to_s.strip
    reply_to = params[:reply_to].to_s.strip
    edit_to = params[:edit_to].to_s.strip
    return if msg.empty?

    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    line =
      if msg.match?(/^\/nick\s+\S/)
        "NICK #{msg[6..].strip}\r\n"
      elsif msg.match?(/^\/whois\s+\S/)
        "WHOIS #{msg[7..].strip}\r\n"
      elsif msg.start_with?("/")
        "#{msg[1..]}\r\n"
      elsif edit_to.present?
        "@+draft/edit=#{IrcRender.escape_tag_value(edit_to)} PRIVMSG #{channel} :#{msg}\r\n"
      elsif reply_to.present?
        "@+reply=#{IrcRender.escape_tag_value(reply_to)} PRIVMSG #{channel} :#{msg}\r\n"
      else
        "PRIVMSG #{channel} :#{msg}\r\n"
      end
    session.enqueue_outbound(line)

    # Clear the input + reply/edit target via CableReady.
    cable_ready
      .set_value(selector: "#message-input", value: "")
      .set_value(selector: "#reply-to-input", value: "")
      .set_value(selector: "#edit-to-input", value: "")
      .inner_html(selector: "#reply-banner", html: "")
      .broadcast
    # Skip the SR PageMorph — it re-renders the full page (all 70+
    # sidebar channel links) on every message send for nothing.
    morph :nothing
  end

  def join
    channel = canonical_channel(params[:channel].presence || element.dataset[:channel])
    # spawn_upstream_if_needed owns the JOIN (deduped via @join_sent) —
    # don't enqueue a second one here.
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    morph :nothing # skip SR page re-render; we redirect instead
    cable_ready.redirect_to(url: "/chat/#{channel.delete('#')}").broadcast
  end

  def part
    channel = canonical_channel(element.dataset[:channel])
    session.remove_channel!(channel)
    session.channel_members.delete(channel)
    session.enqueue_outbound("PART #{channel}\r\n")
    # StimulusReflex re-renders the current page after a reflex by default,
    # which would re-run show → spawn → add_channel! and resurrect the
    # parted channel. Skip the morph; we redirect or remove the row.
    morph :nothing

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
    topic = params[:topic].to_s.strip
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    session.enqueue_outbound("TOPIC #{channel} :#{topic}\r\n")
    # Skip the page re-render — the upstream TOPIC echo updates
    # #channel-topic via the broadcaster; a 482 shows if we're not op.
    morph :nothing
  end

  def react
    channel = canonical_channel(element.dataset[:channel])
    msgid = element.dataset[:msgid].to_s
    emoji = element.dataset[:emoji].to_s
    return if msgid.empty? || emoji.empty?
    session.enqueue_outbound("@+react=#{IrcRender.escape_tag_value(emoji)};+reply=#{IrcRender.escape_tag_value(msgid)} TAGMSG #{channel}\r\n")
    morph :nothing
  end

  def unreact
    channel = canonical_channel(element.dataset[:channel])
    msgid = element.dataset[:msgid].to_s
    emoji = element.dataset[:emoji].to_s
    return if msgid.empty? || emoji.empty?
    session.enqueue_outbound("@+freeq.at/unreact=#{IrcRender.escape_tag_value(emoji)};+reply=#{IrcRender.escape_tag_value(msgid)} TAGMSG #{channel}\r\n")
    morph :nothing
  end

  private

  def session
    @session ||= SessionRegistry.instance.get(connection.session_id)
  end

  def canonical_channel(s)
    IrcRender.canonical_channel(s)
  end
end