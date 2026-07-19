# frozen_string_literal: true

# Live IRC updates for one channel. Stream name is ChatChannel.broadcasting_for(bare)
# which expands to "chat:<bare>" — must match IrcBroadcaster.stream_name.
class ChatChannel < ApplicationCable::Channel
  def subscribed
    bare = params[:room].to_s.delete("#").downcase
    return reject if bare.empty?

    stream_for(bare)
    # Session-wide stream for identity/nick updates (Guest rename, SASL).
    stream_from "freeq:session:#{session_id}"

    # Replay cached member roster + connection status so the panel isn't
    # blank when the subscription arrives after the upstream already sent
    # 353 NAMES (which would have been broadcast before anyone was listening).
    session = SessionRegistry.instance.get(connection.session_id)
    # Channels use #name for member maps; DM rooms are bare nicks (no #).
    channel_key = bare.start_with?("#") ? bare : "##{bare}"
    members = session.channel_members[channel_key] ||
              session.channel_members[IrcRender.canonical_channel(bare)]

    cr = CableReady::Channel.new(broadcasting_for(bare))
    cr.inner_html(selector: "#member-panel", html: IrcRender.render_member_list(members)) if members
    status_text =
      case session.ws_state
      when :ready then "connected"
      when :connecting, :registering then "connecting…"
      else "disconnected"
      end
    cr.text_content(selector: "#status", text: status_text)
    # Replay cached message rows (one-shot). Broadcasts that fired before
    # this subscription confirmed (page-load race, chathistory replay)
    # are otherwise dropped by the pubsub. Client-side filterDupes strips
    # any overlap with REST scrollback by data-msgid.
    # Use the bare room key so DM nicks match cache_row/history_target_key
    # (do NOT force a leading # — that was dropping all DM cache hits).
    rows = session.take_recent_rows(bare)
    rows.each do |row|
      cr.append(selector: "#messages", html: row)
    end

    # Bypass Channel#transmit — its logger.debug path raises ArgumentError
    # in this environment (actioncable 8.1.3), which has silently killed
    # the roster replay since it was written. connection.transmit takes
    # the same payload without the logging wrapper.
    connection.transmit(
      identifier: @identifier,
      message: { "cableReady" => true, "operations" => cr.operations_payload, "version" => CableReady::VERSION }
    )
  rescue => e
    Rails.logger.warn("ChatChannel#subscribed replay failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(4)&.join("\n")}")
  end

  def unsubscribed; end
end
