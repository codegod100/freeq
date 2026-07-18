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

    rest_history = SessionRegistry.instance.fetch_history(@channel, 50)
    # REST failed (e.g. 403 on +i/+k channels) — fall back to the JOIN
    # chathistory replay instead of suppressing it. If we're already
    # joined (no fresh JOIN → no auto replay), fetch backlog explicitly.
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

    # Spawn the upstream WS + per-session broadcaster (IrcBroadcaster).
    @session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, @channel)
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
    @history = []
    @session.request_dm_backlog!(@dm_nick) if @session.ws_state == :ready

    @parent_lookup = {}
    @own_nick = @session.authenticated? ? @session.auth_nick : @session.current_nick
    @known_nicks = @session.known_nicks
    @members_html = nil
    @is_dm = true

    @session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, @dm_nick)
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
