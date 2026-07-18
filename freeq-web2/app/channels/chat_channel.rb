# frozen_string_literal: true

# Live IRC updates for one channel. Stream name is ChatChannel.broadcasting_for(bare)
# which expands to "chat:<bare>" — must match IrcBroadcaster.stream_name.
class ChatChannel < ApplicationCable::Channel
  def subscribed
    bare = params[:room].to_s.delete("#").downcase
    return reject if bare.empty?

    stream_for(bare)

    # Replay cached member roster + connection status so the panel isn't
    # blank when the subscription arrives after the upstream already sent
    # 353 NAMES (which would have been broadcast before anyone was listening).
    session = SessionRegistry.instance.get(connection.session_id)
    canonical = IrcRender.canonical_channel(bare)
    members = session.channel_members[canonical]

    cr = CableReady::Channel.new(broadcasting_for(bare))
    cr.inner_html(selector: "#member-panel", html: IrcRender.render_member_list(members)) if members
    status_text =
      case session.ws_state
      when :ready then "connected"
      when :connecting, :registering then "connecting…"
      else "disconnected"
      end
    cr.text_content(selector: "#status", text: status_text)

    transmit("cableReady" => true, "operations" => cr.operations_payload, "version" => CableReady::VERSION)
  rescue => e
    Rails.logger.warn("ChatChannel#subscribed replay failed: #{e.class}: #{e.message}")
  end

  def unsubscribed; end
end
