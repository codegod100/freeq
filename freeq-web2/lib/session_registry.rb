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
  # touch. On create, restore OAuth *credentials* from the encrypted disk
  # store — app identity still requires SASL after the IRC connect.
  #
  # If an in-memory state has no credentials, re-check disk (OAuth callback
  # may have persisted under this id after an earlier guest touch).
  def get(session_id)
    need_sasl_reconnect = false
    state = synchronize do
      existing = @states[session_id]
      if existing
        if !existing.has_credentials? && restore_auth_from_disk!(existing)
          need_sasl_reconnect = existing.ws_state == :ready && existing.api_bearer.to_s.empty?
        end
        existing
      else
        s = SessionState.new(session_id)
        restore_auth_from_disk!(s)
        # Client-authoritative channel list — restored from disk and
        # re-asserted to the upstream on the next WS connect.
        if @session_store
          s.restore_channels!(@session_store.load_channels(session_id))
        end
        @states[session_id] = s
        s
      end
    end
    # Outside the lock — reconnect can take time / re-enter the registry.
    if need_sasl_reconnect
      Rails.logger.warn(
        "disk credentials restored onto guest IRC — reconnecting for SASL " \
        "session=#{session_id.to_s[0, 8]}…"
      ) if defined?(Rails)
      state.request_reconnect(upstream_url)
    end
    state
  end

  # Returns true if OAuth credentials were applied from disk.
  def restore_auth_from_disk!(state)
    return false if state.nil? || state.has_credentials?

    oauth = @session_store&.load(state.session_id)
    return false unless oauth

    state.auth = oauth # credentials; sasl_status becomes :pending
    if defined?(Rails)
      Rails.logger.info(
        "restored OAuth credentials from disk " \
        "session=#{state.session_id.to_s[0, 8]}… did=#{oauth.did}"
      )
    end
    true
  rescue StandardError => e
    Rails.logger.warn("restore_auth_from_disk! failed: #{e.class}: #{e.message}") if defined?(Rails)
    false
  end

  # Persist the user's channel list (client-authoritative).
  def persist_channels(session_id, channels)
    @session_store&.save_channels(session_id, channels)
  rescue StandardError => e
    Rails.logger.warn("persist_channels failed: #{e.class}: #{e.message}") if defined?(Rails)
  end

  # Persist (or refresh) an authenticated OAuth session to disk.
  # Marks the session so the next HTTP request can rewrite the encrypted
  # oauth_session cookie (WS-thread refreshes cannot set cookies).
  def persist_auth(session_id, oauth)
    @session_store&.save(session_id, oauth)
    synchronize do
      @cookie_sync_needed ||= {}
      @cookie_sync_needed[session_id] = true
    end
  rescue StandardError => e
    Rails.logger.warn("persist_auth failed: #{e.class}: #{e.message}") if defined?(Rails)
  end

  # True once after a disk write — ApplicationController rewrites the cookie.
  def take_cookie_sync!(session_id)
    synchronize do
      @cookie_sync_needed ||= {}
      @cookie_sync_needed.delete(session_id)
    end
  end

  # Drop a persisted session (logout).
  def clear_auth(session_id)
    @session_store&.remove(session_id)
  rescue StandardError => e
    Rails.logger.warn("clear_auth failed: #{e.class}: #{e.message}") if defined?(Rails)
  end

  # Disconnect every other in-process freeq-web2 upstream for the same DID
  # (or preferred nick). Only our own sockets — we do not control the IRC
  # server and cannot force off other users' connections.
  def ghost_siblings!(except_sid:, did: nil, nick: nil)
    except_sid = except_sid.to_s
    did = did.to_s
    nick = nick.to_s
    victims = []
    synchronize do
      @states.each do |sid, state|
        next if sid.to_s == except_sid
        match =
          (did != "" && state.has_credentials? && state.auth.did.to_s == did) ||
          (nick != "" && state.current_nick.to_s.casecmp?(nick)) ||
          (nick != "" && state.has_credentials? && state.auth_nick.to_s.casecmp?(nick))
        victims << state if match
      end
    end
    victims.each do |state|
      Rails.logger.info(
        "ghost_siblings: disconnecting sid=#{state.session_id.to_s[0, 8]}… " \
        "nick=#{state.current_nick} for reclaim"
      ) if defined?(Rails)
      state.disconnect_upstream!(reason: "replaced by same-identity login")
    end
    victims.size
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
  # Pass `bearer:` (IRC session_id from API-BEARER) so restricted channels
  # (+i/+k/policy) authorize the caller as a member. Returns nil when the
  # fetch fails so the caller can fall back to JOIN chathistory replay.
  #
  # Retries 403 briefly when authed — freeq-server only grants access once
  # the IRC session is in ch.members, which can lag the API-BEARER NOTICE.
  def fetch_history(channel, limit = 25, bearer: nil, retries: nil)
    retries = bearer.to_s.empty? ? 0 : 4 if retries.nil?
    attempt = 0
    loop do
      result = fetch_history_once(channel, limit, bearer)
      return result if result

      break if attempt >= retries
      attempt += 1
      sleep 0.35 * attempt
    end
    nil
  end

  def fetch_history_once(channel, limit, bearer)
    require "net/http"
    require "json"
    encoded = channel.delete("#")
    uri = URI("#{rest_base}/api/v1/channels/#{URI.encode_www_form_component(encoded)}/history?limit=#{limit}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 3
    http.read_timeout = 5
    req = Net::HTTP::Get.new(uri.request_uri)
    req["Authorization"] = "Bearer #{bearer}" if bearer && !bearer.to_s.empty?
    resp = http.request(req)
    unless resp.is_a?(Net::HTTPSuccess)
      Rails.logger.info(
        "fetch_history #{channel}: HTTP #{resp.code}" \
        "#{bearer.to_s.empty? ? ' (anonymous)' : ' (authed)'}" \
        "#{resp.code == '403' && !bearer.to_s.empty? ? ' — not a member yet or no access' : ''}"
      ) if defined?(Rails)
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
  private :fetch_history_once
end