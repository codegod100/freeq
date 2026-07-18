# frozen_string_literal: true

require "monitor"

require_relative "session_state"
require_relative "session_store"
require_relative "irc_render"

# Global registry of browser sessions → upstream IRC connections.
# One SessionState per session_id (a signed cookie set on first request).
#
# Authenticated OAuth sessions are also mirrored to an encrypted on-disk
# SessionStore (see freeq-webui) so identity survives process restarts.
class SessionRegistry
  include MonitorMixin

  class << self
    def instance
      @instance ||= SessionRegistry.new
    end
  end

  attr_reader :session_store

  def initialize(session_store: SessionStore.open)
    super()
    @states = {} # session_id => SessionState
    @session_store = session_store
  end

  def upstream_url
    ENV.fetch("FREEQ_UPSTREAM", "wss://irc.freeq.at/irc")
  end

  def rest_base
    ENV.fetch("FREEQ_UPSTREAM_REST", "https://irc.freeq.at")
  end

  # Return the live SessionState for `session_id`, creating it on first
  # touch. On create, try restoring an authenticated OAuth session from
  # the encrypted disk store so the user stays signed in across restarts.
  def get(session_id)
    synchronize do
      existing = @states[session_id]
      return existing if existing

      state = SessionState.new(session_id)
      if (oauth = @session_store&.load(session_id))
        state.auth = oauth
        Rails.logger.info(
          "restored authenticated session from disk " \
          "session=#{session_id[0, 8]}… did=#{oauth.did}"
        ) if defined?(Rails)
      end
      # Client-authoritative channel list — restored from disk and
      # re-asserted to the upstream on the next WS connect.
      if @session_store
        state.restore_channels!(@session_store.load_channels(session_id))
      end
      @states[session_id] = state
      state
    end
  end

  # Persist the user's channel list (client-authoritative).
  def persist_channels(session_id, channels)
    @session_store&.save_channels(session_id, channels)
  rescue StandardError => e
    Rails.logger.warn("persist_channels failed: #{e.class}: #{e.message}") if defined?(Rails)
  end

  # Persist (or refresh) an authenticated OAuth session to disk.
  def persist_auth(session_id, oauth)
    @session_store&.save(session_id, oauth)
  rescue StandardError => e
    Rails.logger.warn("persist_auth failed: #{e.class}: #{e.message}") if defined?(Rails)
  end

  # Drop a persisted session (logout).
  def clear_auth(session_id)
    @session_store&.remove(session_id)
  rescue StandardError => e
    Rails.logger.warn("clear_auth failed: #{e.class}: #{e.message}") if defined?(Rails)
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
  # Returns nil when the fetch fails (e.g. 403 on a +i/+k channel) so the
  # caller can fall back to the JOIN chathistory replay; an array
  # (possibly empty) when the fetch succeeded.
  def fetch_history(channel, limit = 25)
    require "net/http"
    require "json"
    encoded = channel.delete("#")
    uri = URI("#{rest_base}/api/v1/channels/#{encoded}/history?limit=#{limit}")
    resp = Net::HTTP.get_response(uri)
    unless resp.is_a?(Net::HTTPSuccess)
      Rails.logger.info("fetch_history #{channel}: HTTP #{resp.code}") if defined?(Rails)
      return nil
    end
    msgs = JSON.parse(resp.body)
    msgs.map do |m|
      tags = m["tags"] || {}
      {
        sender: m["sender"],
        text: m["text"],
        timestamp: m["timestamp"],
        msgid: m["msgid"],
        tags: tags,
        reactions: IrcRender.parse_reactions_tag(tags["+freeq.at/reactions"].to_s)
      }
    end
  rescue StandardError => e
    Rails.logger.warn("fetch_history failed: #{e.class}: #{e.message}")
    nil
  end
end