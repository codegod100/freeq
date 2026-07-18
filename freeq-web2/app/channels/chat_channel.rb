# frozen_string_literal: true

# Live IRC updates for one channel. Stream name is ChatChannel.broadcasting_for(bare)
# which expands to "chat:<bare>" — must match IrcBroadcaster.stream_name.
class ChatChannel < ApplicationCable::Channel
  def subscribed
    bare = params[:room].to_s.delete("#").downcase
    return reject if bare.empty?

    stream_for(bare)
    Rails.logger.debug { "ChatChannel subscribed room=#{bare} stream=#{broadcasting_for(bare)}" }
  end

  def unsubscribed; end
end
