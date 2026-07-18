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

    @history = SessionRegistry.instance.fetch_history(@channel, 50)
    # Merge cached reactions (from live TAGMSG +react events) into history
    # so chips survive page refresh within the same session.
    @history.each do |msg|
      msg[:reactions] = @session.merged_reactions(msg[:msgid], msg[:reactions])
    end
    @parent_lookup = IrcRender.parent_lookup_from_history(@history)
    @session.note_seen_msgids(@history.filter_map { |m| m[:msgid] })
    # Keep a per-session lookup so live-rendered replies can show parent context.
    @session.parent_lookup.merge!(@parent_lookup)

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
