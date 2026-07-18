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
    joined = @session.joined.to_a
    existing = channels.map { |c| c["name"].to_s.downcase }
    joined.each do |ch|
      next if existing.include?(ch.downcase)
      channels << { "name" => ch, "topic" => "", "members" => 0 }
    end
    @session.joined << @channel

    @topic = channels.find { |c| c["name"].to_s.casecmp?(@channel) }&.dig("topic") || ""
    @my_channels, @all_channels = channels.partition do |c|
      joined.any? { |j| j.casecmp?(c["name"].to_s) } || c["name"].to_s.casecmp?(@channel)
    end

    @history = SessionRegistry.instance.fetch_history(@channel, 25)
    @session.note_seen_msgids(@history.filter_map { |m| m[:msgid] })

    # Spawn the upstream WS + per-session broadcaster (IrcBroadcaster).
    @session.spawn_upstream_if_needed(SessionRegistry.instance.upstream_url, @channel)
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

  def current_session
    SessionRegistry.instance.get(session_id)
  end

  def session_id
    cookies.signed[:freeq_session] ||= SecureRandom.hex(16)
  end
end
