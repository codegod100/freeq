# frozen_string_literal: true

require "monitor"

require_relative "session_state"
require_relative "irc_render"

# Global registry of browser sessions → upstream IRC connections.
# One SessionState per session_id (a signed cookie set on first request).
class SessionRegistry
  include MonitorMixin

  class << self
    def instance
      @instance ||= SessionRegistry.new
    end
  end

  def initialize
    super()
    @states = {} # session_id => SessionState
  end

  def upstream_url
    ENV.fetch("FREEQ_UPSTREAM", "wss://irc.freeq.at/irc")
  end

  def rest_base
    ENV.fetch("FREEQ_UPSTREAM_REST", "https://irc.freeq.at")
  end

  def get(session_id)
    synchronize { @states[session_id] ||= SessionState.new(session_id) }
  end

  # Fetch channels from the upstream REST API.
  def fetch_channels
    require "net/http"
    require "json"
    uri = URI("#{rest_base}/api/v1/channels")
    JSON.parse(Net::HTTP.get(uri))
  rescue StandardError => e
    Rails.logger.warn("fetch_channels failed: #{e.class}: #{e.message}")
    []
  end

  # Fetch scrollback history for a channel from the upstream REST API.
  def fetch_history(channel, limit = 25)
    require "net/http"
    require "json"
    encoded = channel.delete("#")
    uri = URI("#{rest_base}/api/v1/channels/#{encoded}/history?limit=#{limit}")
    msgs = JSON.parse(Net::HTTP.get(uri))
    msgs.map do |m|
      {
        sender: m["sender"],
        text: m["text"],
        timestamp: m["timestamp"],
        msgid: m["msgid"],
        tags: m["tags"] || {},
        reactions: IrcRender.parse_reactions_tag(m["tags"]&.fetch("+freeq.at/reactions", ""))
      }
    end
  rescue StandardError => e
    Rails.logger.warn("fetch_history failed: #{e.class}: #{e.message}")
    []
  end
end