# frozen_string_literal: true

class ChatController < ApplicationController
  # GET /chat — channel list (the "channels" page).
  def index
    @channels = SessionRegistry.instance.fetch_channels
    @session = current_session
  end

  # GET /chat/:channel — chat shell for a channel.
  def show
    @channel = IrcRender.canonical_channel(params[:channel])
    @bare = @channel.delete("#")
    @session = current_session

    # Kick IRC early so SASL can finish before we request restricted history.
    @session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, @channel)

    channels = SessionRegistry.instance.fetch_channels
    mine = @session.channels.to_a
    existing = channels.map { |c| c["name"].to_s.downcase }
    # MY CHANNELS is client-authoritative: show our own list even when the
    # upstream REST channel list is stale or missing entries.
    mine.each do |ch|
      next if existing.include?(ch.downcase)
      channels << { "name" => ch, "topic" => "", "members" => 0 }
    end

    @topic = channels.find { |c| c["name"].to_s.casecmp?(@channel) }&.dig("topic") || ""
    @my_channels, @all_channels = channels.partition do |c|
      mine.any? { |j| j.casecmp?(c["name"].to_s) } || c["name"].to_s.casecmp?(@channel)
    end

    # Restricted channels need Bearer = IRC session_id (API-BEARER after SASL)
    # AND the DID must be a current channel member on freeq-server. Wait for
    # bearer → :ready → 353 NAMES (JOIN landed), then fetch with retries.
    bearer =
      if @session.authenticated?
        @session.wait_for_api_bearer(timeout: 8.0, primary: @channel)
      else
        @session.api_bearer # guests never get one; public channels still work
      end
    if bearer
      if @session.ws_state != :ready
        ready_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
        while @session.ws_state != :ready &&
              Process.clock_gettime(Process::CLOCK_MONOTONIC) < ready_deadline
          sleep 0.1
        end
      end
      # After SASL, force re-JOIN (clears sticky guest 477) then wait for 353.
      joined = @session.wait_until_joined(@channel, timeout: 8.0)
      Rails.logger.info(
        "history preflight #{@channel}: bearer=yes ready=#{@session.ws_state} " \
        "roster=#{joined ? 'yes' : 'no'}"
      )
    end
    # Only hammer REST history when we actually joined; otherwise 403 is certain.
    rest_history =
      if bearer && @session.channel_members[@channel]&.any?
        SessionRegistry.instance.fetch_history(@channel, 50, bearer: bearer)
      elsif !bearer
        SessionRegistry.instance.fetch_history(@channel, 50, bearer: nil, retries: 0)
      else
        Rails.logger.info("fetch_history #{@channel}: skipped (not in channel yet)")
        nil
      end
    # REST failed / skipped — fall back to JOIN chathistory replay.
    if rest_history.nil?
      @session.allow_replay!(@channel)
      @session.request_backlog!(@channel)
    end
    @history = rest_history || []
    # Merge cached reactions (from live TAGMSG +react events) into history
    # so chips survive page refresh within the same session.
    @history.each do |msg|
      msg[:reactions] = @session.merged_reactions(msg[:msgid], msg[:reactions])
    end
    @parent_lookup = IrcRender.parent_lookup_from_history(@history)
    # Keep a per-session lookup so live-rendered replies can show parent context.
    @session.parent_lookup.merge!(@parent_lookup)
    @own_nick = @session.authenticated? ? @session.auth_nick : @session.current_nick
    @known_nicks = @session.known_nicks

    # Cached member roster (may be empty on first visit; populated by 353 NAMES).
    @members_html =
      if @session.channel_members[@channel]
        IrcRender.render_member_list(@session.channel_members[@channel])
      else
        nil
      end
  end

  # GET /chat/dm/:nick — DM chat shell for a direct message conversation.
  # DMs are E2EE (browser-side Double Ratchet); the server only relays
  # ciphertext. History comes via CHATHISTORY over WS, not REST.
  def dm
    @dm_nick = params[:nick]
    @channel = @dm_nick  # reuse the show template's @channel for the nav
    @bare = @dm_nick
    @session = current_session

    channels = SessionRegistry.instance.fetch_channels
    mine = @session.channels.to_a
    existing = channels.map { |c| c["name"].to_s.downcase }
    mine.each do |ch|
      next if existing.include?(ch.downcase)
      channels << { "name" => ch, "topic" => "", "members" => 0 }
    end
    @topic = ""
    @my_channels, @all_channels = channels.partition do |c|
      mine.any? { |j| j.casecmp?(c["name"].to_s) }
    end

    # No REST history for DMs — request via CHATHISTORY over WS.
    # allow_replay! is done inside request_dm_backlog! so the BATCH is not
    # suppressed (channel history is suppressed when REST already rendered).
    @history = []
    @session.request_dm_backlog!(@dm_nick)

    @parent_lookup = {}
    @own_nick = @session.authenticated? ? @session.auth_nick : @session.current_nick
    @known_nicks = @session.known_nicks
    @members_html = nil
    @is_dm = true

    # as_dm: true — never JOIN the partner nick as a channel.
    @session.spawn_upstream_if_needed(
      SessionRegistry.instance.upstream_url,
      @dm_nick,
      as_dm: true
    )
    render :show
  end

  # POST /chat/:channel/react  { msgid, emoji }
  def react
    enqueue_reaction(added: true)
  end

  # POST /chat/:channel/unreact  { msgid, emoji }
  def unreact
    enqueue_reaction(added: false)
  end

  private

  def enqueue_reaction(added:)
    channel = IrcRender.canonical_channel(params[:channel])
    msgid = params[:msgid].to_s
    emoji = params[:emoji].to_s
    if msgid.empty? || emoji.empty?
      return render json: { ok: false, error: "msgid and emoji required" }, status: :unprocessable_entity
    end

    session = current_session
    session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, channel)
    tag = added ? "+react" : "+freeq.at/unreact"
    line = "@#{tag}=#{IrcRender.escape_tag_value(emoji)};+reply=#{IrcRender.escape_tag_value(msgid)} TAGMSG #{channel}\r\n"
    session.enqueue_outbound(line)
    render json: { ok: true }
  end
end
