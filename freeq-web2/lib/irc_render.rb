# frozen_string_literal: true

# Port of freeq-webui/src/irc_render.rs.
# Pure functions: IRC line → HTML, tag parsing, member-list rendering,
# reaction-chip rendering, nick color hashing, linkification.
module IrcRender
  NICK_CLASSES = %w[n1 n2 n3 n4 n5 n6 n7 n8].freeze

  module_function

  def canonical_channel(s)
    s.start_with?("#") ? s : "##{s}"
  end

  # Parse freeq-server force-rename notices issued at registration:
  #   "Nick foo is registered — renamed to Guest12345. Authenticate to reclaim."
  #   "foo is registered to another identity. You are bar (tied to your account)."
  # Returns the new nick string, or nil.
  def parse_forced_nick_rename(line)
    text = line.to_s
    if (m = text.match(/renamed to (Guest\d+)/i))
      return m[1]
    end
    if (m = text.match(/You are (\S+) \(tied to your account\)/i))
      return m[1]
    end
    nil
  end

  # Live #user-handle markup for the sidebar widget.
  #
  # App identity = SASL (irc_ok). OAuth credentials alone are "signing in",
  # not a locked handle — that was the dual-state lie that let policy 477
  # surprise users who thought they were already signed in.
  #
  #   irc_ok:          SASL succeeded (API-BEARER present)
  #   auth_handle:     handle from OAuth credentials (if any)
  #   signing_in:      credentials present, SASL not finished
  def user_handle_html(nick:, auth_handle: nil, irc_ok: false, signing_in: false)
    nick = nick.to_s
    if irc_ok && auth_handle.to_s != ""
      %(<div class="user-handle" id="user-handle">🔒 #{html_escape(auth_handle)}</div>)
    elsif signing_in && auth_handle.to_s != ""
      %(<div class="user-handle signing-in" id="user-handle">⏳ #{html_escape(auth_handle)}</div>)
    else
      label = nick.empty? ? "guest" : nick
      %(<div class="user-handle guest" id="user-handle">👤 #{html_escape(label)}</div>)
    end
  end

  def user_irc_note_text(nick:, irc_ok: false, authenticated: false, signing_in: false)
    return "" if irc_ok
    return "Signing in to IRC (SASL)…" if signing_in
    if nick.to_s.match?(/\AGuest\d+\z/i)
      return "IRC as #{nick} — reclaiming nick…" if authenticated
      return "IRC as #{nick} — sign in to join policy channels"
    end
    if authenticated && nick.to_s.match?(/_+\z/)
      return "IRC as #{nick} — reclaiming preferred nick…"
    end
    ""
  end

  # Parse `@key=value;... :rest` → [tags_hash, rest_without_tags].
  def parse_irc_tags(line)
    line = line.chomp.delete_suffix("\r")
    return [{}, line] unless line.start_with?("@")

    rest = line[1..]
    sp = rest.index(" ")
    return [{}, line] unless sp

    tag_part = rest[0...sp]
    after = rest[(sp + 1)..]
    tags = {}
    tag_part.split(";").each do |item|
      k, v = item.split("=", 2)
      v = v.nil? ? "" : unescape_tag_value(v)
      tags[k] = v unless k.empty?
    end
    [tags, after]
  end

  def unescape_tag_value(s)
    out = +""
    chars = s.chars
    while (c = chars.shift)
      if c == "\\"
        case chars.shift
        when ":" then out << ";"
        when "s" then out << " "
        when "\\" then out << "\\"
        when "r" then out << "\r"
        when "n" then out << "\n"
        when nil then out << "\\"
        else ->(o) { o << "\\" << c } # unmatched — keep backslash + char
        end
      else
        out << c
      end
    end
    out
  end

  def escape_tag_value(s)
    s.chars.each_with_object(+"") do |c, out|
      case c
      when ";" then out << "\\:"
      when " " then out << "\\s"
      when "\\" then out << "\\\\"
      when "\r" then out << "\\r"
      when "\n" then out << "\\n"
      else out << c
      end
    end
  end

  def html_escape(s)
    s.to_s.chars.each_with_object(+"") do |c, out|
      case c
      when "&" then out << "&amp;"
      when "<" then out << "&lt;"
      when ">" then out << "&gt;"
      when '"' then out << "&quot;"
      when "'" then out << "&#39;"
      else out << c
      end
    end
  end

  # Image URL patterns (aligned with freeq-app MessageList).
  IMAGE_EXT_RE = /\.(?:jpg|jpeg|png|gif|webp)(?:\?|$)/i
  FREEQ_MEDIA_RE = %r{/api/v1/media/}i
  BSKY_CDN_RE = %r{cdn\.bsky\.app/img/}i

  def image_url?(url)
    u = url.to_s
    return true if u.match?(IMAGE_EXT_RE)
    return true if u.match?(FREEQ_MEDIA_RE) && u.match?(/image|png|jpe?g|gif|webp/i)
    return true if u.match?(BSKY_CDN_RE)
    false
  end

  # Fallback labels (UTC). Browser localizes via data-ts + chat_controller.js.
  def format_date_separator(time)
    t = coerce_utc_time(time)
    now = Time.now.utc
    return "Today" if same_utc_day?(t, now)
    return "Yesterday" if same_utc_day?(t, now - 86_400)

    t.strftime("%A, %B ") + t.day.to_s + t.strftime(", %Y")
  end

  def date_separator_html(time)
    t = coerce_utc_time(time)
    label = format_date_separator(t)
    day = day_key(t).to_s
    epoch = t.to_i
    %(<div class="date-sep" data-ts="#{epoch}" data-day="#{html_escape(day)}" role="separator"><span>#{html_escape(label)}</span></div>)
  end

  def day_key(time)
    coerce_utc_time(time).strftime("%Y-%m-%d")
  rescue StandardError
    nil
  end

  def coerce_utc_time(time)
    return time.getutc if time.is_a?(Time)

    Time.at(time.to_i).utc
  end

  def same_utc_day?(a, b)
    a.year == b.year && a.month == b.month && a.day == b.day
  end

  # Unix epoch + UTC clock as SSR fallback; client rewrites to local time.
  def timestamp_span(time)
    t = coerce_utc_time(time)
    %(<span class="ts" data-ts="#{t.to_i}">#{t.strftime("%H:%M:%S")}</span>)
  end

  # IRCv3 server-time tag → Time, else now.
  def time_from_tags(tags)
    raw = (tags || {})["time"] || (tags || {})["+time"]
    return Time.now.utc if raw.to_s.empty?

    Time.parse(raw.to_s).utc
  rescue StandardError
    Time.now.utc
  end

  def linkify_urls(escaped)
    out = +""
    rest = escaped.to_s
    # Match http(s) so local media and production both work.
    while (m = rest.match(%r{https?://}))
      pos = m.begin(0)
      out << rest[0...pos]
      after = rest[pos..]
      match = after.match(/[\s<]/)
      url_end = match ? match.begin(0) : after.size
      url = after[0...url_end]
      # Trim trailing punctuation commonly glued onto URLs.
      while url.end_with?(".", ",", ")", "]", "!", "?", ";", "'", '"')
        url = url[0...-1]
        url_end -= 1
      end
      if image_url?(url)
        out << %(<a href="#{url}" target="_blank" rel="noopener noreferrer" class="msg-img-url">#{url}</a>)
        out << %(<a href="#{url}" target="_blank" rel="noopener noreferrer" class="msg-img-link">) \
             + %(<img src="#{url}" alt="" class="msg-img" loading="lazy" referrerpolicy="no-referrer"></a>)
      else
        out << %(<a href="#{url}" target="_blank" rel="noopener noreferrer">#{url}</a>)
      end
      rest = after[url_end..]
    end
    out << rest
    out
  end

  def nick_color_class(nick)
    h = 5381
    nick.each_byte { |b| h = (h * 33 + b) & 0xffffffff }
    NICK_CLASSES[h % 8]
  end

  def sanitize_nick(handle)
    out = handle.to_s.chars.first(20).select { |c| c.match?(/[A-Za-z0-9.\-_]/) }.join
    return "" if out.empty?
    out = "u#{out}"[0, 20] unless out[0].match?(/[A-Za-z]/)
    out
  end

  # Parse `BATCH +id type [args…]` / `BATCH -id`.
  # Returns [id, open, batch_type, channel] or nil.
  def parse_batch_line(line)
    line = line.chomp.delete_suffix("\r")
    _tags, after_tags = parse_irc_tags(line)
    rest = after_tags.start_with?(":") ? after_tags[1..] : after_tags
    sp = rest.index(" ") or return nil
    after_prefix = rest[(sp + 1)..]
    parts = after_prefix.split
    return nil unless parts[0] == "BATCH"
    ref = parts[1].to_s
    open, id =
      if ref.start_with?("+")
        [true, ref[1..]]
      elsif ref.start_with?("-")
        [false, ref[1..]]
      else
        return nil
      end
    batch_type = open ? parts[2] : nil
    [id, open, batch_type, parts[3]]
  end

  # Should a raw IRC line be emitted to the message pane for this channel?
  # Returns the original msgid if this line is a +draft/edit=<msgid> PRIVMSG.
  def edit_target(line)
    tags, _ = parse_irc_tags(line)
    tags["+draft/edit"]
  end

  def should_emit?(line, current_channel)
    line = line.chomp.delete_suffix("\r")
    return false if line.start_with?("PING ", "PONG ")

    _tags, after_tags = parse_irc_tags(line)
    rest = after_tags[1..] or return false # strip leading ':'
    return false unless rest

    sp = rest.index(" ") or return false
    after_prefix = rest[(sp + 1)..]
    cmd = after_prefix.split.first.to_s

    # Numerics (001, 353, …) are handled elsewhere.
    return false if cmd.size == 3 && cmd.match?(/\A\d+\z/)

    case cmd
    when "CAP", "AUTHENTICATE", "BATCH", "PING", "PONG", "ERROR", "TAGMSG"
      return false
    when "PRIVMSG", "NOTICE", "JOIN", "PART", "QUIT", "TOPIC", "KICK", "NICK", "MODE"
      nil
    else
      return false
    end

    target = extract_irc_target(after_prefix)

    # PRIVMSG/NOTICE to a *nick* (DM) must never fan out into channel
    # panes. extract_irc_target only returns channel targets; a nil
    # target on PRIVMSG/NOTICE means nick-directed (or malformed).
    # Previously we `return true unless target`, which dumped ENC3 DMs
    # into every joined channel when dm_target_for missed (e.g. Guest rename).
    if %w[PRIVMSG NOTICE].include?(cmd)
      return false unless target

      return canonical_channel(target).casecmp?(canonical_channel(current_channel))
    end

    return true unless target # QUIT/NICK/etc. without a channel — fan out

    canonical_channel(target).casecmp?(canonical_channel(current_channel))
  end

  # Channel target only (#/&/+/!). Nick targets return nil so callers can
  # treat them as DMs rather than channel messages.
  def extract_irc_target(after_prefix)
    cmd_end = after_prefix.index(" ") or return nil
    command = after_prefix[0...cmd_end]
    return nil unless %w[PRIVMSG NOTICE TOPIC MODE KICK INVITE].include?(command)

    rest = after_prefix[(cmd_end + 1)..]
    target_end = rest.index(" ") || rest.size
    target = rest[0...target_end]
    return nil unless target.start_with?("#", "&", "+", "!")

    target
  end

  # Returns [msgid, emoji, nick, added, channel] for a +react / +freeq.at/unreact TAGMSG.
  def parse_tagmsg_reaction(line)
    tags, after = parse_irc_tags(line)
    emoji, added =
      if tags["+react"]
        [tags["+react"], true]
      elsif tags["+freeq.at/unreact"]
        [tags["+freeq.at/unreact"], false]
      else
        return nil
      end
    msgid = tags["+reply"] or return nil
    rest = after[1..] or return nil # strip ':'
    parts = rest.split
    nick = parts[0].to_s.split("!").first
    return nil unless parts[1].to_s.casecmp?("TAGMSG")
    channel = parts[2].to_s.delete_prefix(":")
    [msgid, emoji, nick, added, channel]
  end

  def parse_353_members(line)
    names = (line.rindex(" :") && line[(line.rindex(" :") + 2)..]) || ""
    names.split(" ").reject(&:empty?).map do |token|
      pfx = token.chars.take_while { |c| "@%+~&".include?(c) }
      {
        nick: token[pfx.size..],
        op: pfx.include?("@") || pfx.include?("~") || pfx.include?("&"),
        halfop: pfx.include?("%"),
        voiced: pfx.include?("+")
      }
    end
  end

  def render_member_list(members)
    return %(<div class="member empty">—</div>) if members.empty?

    sorted = members.values.sort_by do |m|
      rank = m[:op] ? 0 : (m[:halfop] ? 1 : (m[:voiced] ? 2 : 3))
      [rank, m[:nick].downcase]
    end
    sorted.map do |m|
      color = nick_color_class(m[:nick])
      safe_nick = html_escape(m[:nick])
      pfx =
        if m[:op]      then %(<span class="pfx op">@</span>)
        elsif m[:halfop] then %(<span class="pfx halfop">%</span>)
        elsif m[:voiced] then %(<span class="pfx voice">+</span>)
        else ""
        end
      did_attr = m[:account] ? %( data-did="#{html_escape(m[:account])}" data-account="#{html_escape(m[:account])}") : ""
      pfx_html = pfx.empty? ? %(<span class="pfx" aria-hidden="true"></span>) : pfx
      %(<div class="member" data-nick="#{safe_nick}"#{did_attr}>#{pfx_html}<span class="nick #{color}" onclick="window.openDm('#{safe_nick}')" title="Message #{safe_nick}">#{safe_nick}</span></div>)
    end.join
  end

  # Parent msgid from IRCv3 reply tags. freeq uses `+reply`; some clients send
  # `draft/reply`.
  def reply_parent_msgid(tags)
    return nil unless tags
    tags["+reply"] || tags["reply"] || tags["draft/reply"]
  end

  # Inline "↪ replying to …" badge. When parent_nick/parent_text are known
  # (history index), show them; otherwise emit a stub the client hydrates
  # from the live message map.
  def render_reply_badge(parent_msgid, parent_nick: nil, parent_text: nil)
    return "" if parent_msgid.to_s.empty?

    mid = html_escape(parent_msgid)
    if parent_nick.present?
      snippet = parent_text.to_s.tr("\n", " ")
      snippet = snippet.bytesize > 80 ? "#{snippet.byteslice(0, 80)}…" : snippet
      label = %(<span class="reply-nick">#{html_escape(parent_nick)}</span> <span class="reply-text">#{html_escape(snippet)}</span>)
    else
      label = %(<span class="reply-nick">message</span> <span class="reply-text"></span>)
    end
    %(<button type="button" class="reply-badge" data-reply-to="#{mid}" onclick="window.scrollToMessage('#{mid}')" title="Jump to original">↪ #{label}</button>)
  end

  def render_reply_btn(msgid)
    return "" if msgid.to_s.empty?
    mid = html_escape(msgid)
    %(<button type="button" class="reply-btn" title="Reply" onclick="window.startReply('#{mid}')">↩</button>)
  end

  # Edit button — only rendered on messages sent by the current user.
  # `own` is checked by the caller (render_irc_line / render_history_row)
  # against the session's auth nick / guest nick.
  def render_edit_btn(msgid)
    return "" if msgid.to_s.empty?
    mid = html_escape(msgid)
    %(<button type="button" class="reply-btn edit-btn" title="Edit" onclick="window.startEdit('#{mid}')">✎</button>)
  end

  # Render a live IRC line (from the upstream WS) as an HTML row.
  # `own_nick`: the current user's nick — when it matches the sender,
  # an edit button is appended to the row.
  def render_irc_line(line, parent_lookup: nil, own_nick: nil, known_nicks: nil)
    line = line.chomp.delete_suffix("\r")
    tags, rest_with_prefix = parse_irc_tags(line)
    msg_time = time_from_tags(tags)
    clock = timestamp_span(msg_time)

    rest = rest_with_prefix[1..] or return notice_row(line, clock)

    sp = rest.index(" ") or return notice_row(line, clock)
    prefix = rest[0...sp]
    cmd_and_args = rest[(sp + 1)..]
    nick = prefix.split("!").first
    parts = cmd_and_args.split(" ", 3)
    cmd = parts[0].to_s

    if %w[PRIVMSG NOTICE].include?(cmd)
      _target = parts[1].to_s
      text = parts[2].to_s.delete_prefix(":")
      cls = cmd == "NOTICE" ? "notice" : "msg"
      color = nick_color_class(nick)
      safe_text = linkify_urls(html_escape(text))
      # For edits (+draft/edit), the original msgid is the DOM identity —
      # the edit replaces the row in place. The new msgid is used for
      # reply/edit targeting but doesn't change the row's position.
      edit_orig = tags["+draft/edit"]
      dom_msgid = edit_orig || tags["msgid"]
      msgid_attr = dom_msgid ? %( data-msgid="#{html_escape(dom_msgid)}") : ""
      nick_attr = %( data-nick="#{html_escape(nick)}")
      account = tags["account"] || tags["+account"]
      account_attr = account && account.start_with?("did:") ? %( data-account="#{html_escape(account)}") : ""
      text_attr = %( data-text="#{html_escape(text)}")
      parent = reply_parent_msgid(tags)
      parent_info = parent_lookup && parent ? parent_lookup[parent] : nil
      reply_html = render_reply_badge(
        parent,
        parent_nick: parent_info && parent_info[:nick],
        parent_text: parent_info && parent_info[:text]
      )
      reactions = parse_reactions_tag(tags["+freeq.at/reactions"]) if tags["+freeq.at/reactions"]
      reaction_html = render_reaction_chips(dom_msgid, reactions || {})
      reply_btn = render_reply_btn(dom_msgid)
      edit_btn = (own_nick && nick&.casecmp?(own_nick)) || (known_nicks && known_nicks.any? { |n| n&.casecmp?(nick) }) ? render_edit_btn(dom_msgid) : ""
      return %(<div class="#{cls}"#{msgid_attr}#{nick_attr}#{account_attr}#{text_attr}>#{clock}<span class="body">#{reply_html}<span class="nick #{color}">#{html_escape(nick)}</span> #{safe_text}#{reaction_html}#{reply_btn}#{edit_btn}</span></div>)
    end


    if %w[JOIN PART QUIT].include?(cmd)
      cls = cmd == "JOIN" ? "join" : "part"
      return %(<div class="#{cls}">#{clock}<span class="body">— #{html_escape(nick)} #{cmd.downcase}</span></div>)
    end

    notice_row(line, clock)
  end

  # parent_lookup: { msgid => { nick:, text: } } built from the history set.
  def render_history_row(msg, parent_lookup: nil, own_nick: nil, known_nicks: nil)
    nick = msg[:sender].to_s.split("!").first
    color = nick_color_class(nick)
    msg_time = begin
      Time.at(msg[:timestamp].to_i).utc
    rescue StandardError
      Time.now.utc
    end
    clock = timestamp_span(msg_time)
    text = msg[:text].to_s
    safe_text = linkify_urls(html_escape(text))
    msgid = msg[:msgid]
    msgid_attr = msgid ? %( data-msgid="#{html_escape(msgid)}") : ""
    nick_attr = %( data-nick="#{html_escape(nick)}")
    account = (msg[:tags] || {})["account"] || (msg[:tags] || {})["+account"]
    account_attr = account && account.start_with?("did:") ? %( data-account="#{html_escape(account)}") : ""
    text_attr = %( data-text="#{html_escape(text)}")
    parent = reply_parent_msgid(msg[:tags] || {})
    parent_info = parent_lookup && parent ? parent_lookup[parent] : nil
    reply_html = render_reply_badge(
      parent,
      parent_nick: parent_info && parent_info[:nick],
      parent_text: parent_info && parent_info[:text]
    )
    reactions = msg[:reactions] || {}
    reaction_html = render_reaction_chips(msgid, reactions)
    reply_btn = render_reply_btn(msgid)
    edit_btn = (own_nick && nick&.casecmp?(own_nick)) || (known_nicks && known_nicks.any? { |n| n&.casecmp?(nick) }) ? render_edit_btn(msgid) : ""
    %(<div class="msg" data-day="#{day_key(msg_time)}"#{msgid_attr}#{nick_attr}#{account_attr}#{text_attr}>#{clock}<span class="body">#{reply_html}<span class="nick #{color}">#{html_escape(nick)}</span> #{safe_text}#{reaction_html}#{reply_btn}#{edit_btn}</span></div>)
  end

  # SSR history list with date separators between day boundaries.
  # Returns [html, last_day_key].
  def render_history_with_separators(history, parent_lookup: nil, own_nick: nil, known_nicks: nil)
    out = +""
    last_day = nil
    Array(history).each do |msg|
      t = begin
        Time.at(msg[:timestamp].to_i).utc
      rescue StandardError
        Time.now.utc
      end
      day = day_key(t)
      if day && day != last_day
        out << date_separator_html(t)
        last_day = day
      end
      out << render_history_row(msg, parent_lookup: parent_lookup, own_nick: own_nick, known_nicks: known_nicks)
    end
    [out, last_day]
  end

  def parse_reactions_tag(value)
    map = {}
    value.to_s.split(";").each do |group|
      emoji, nicks = group.split(":", 2)
      next unless emoji
      nicks = nicks.to_s.split(",").reject(&:empty?)
      map[emoji] = nicks if nicks.any?
    end
    map
  end

  def render_reaction_chips(msgid, reactions)
    return "" if msgid.nil? && reactions.empty?

    out = +%(<span class="reactions">)
    reactions.each do |emoji, nicks|
      title = nicks.join(", ")
      count = nicks.size
      label = count == 1 ? emoji : "#{emoji} #{count}"
      mid = msgid.to_s
      out << %(<button type="button" class="reaction-chip" title="#{html_escape(title)}" data-emoji="#{html_escape(emoji)}" data-msgid="#{html_escape(mid)}" onclick="window.toggleReaction('#{html_escape(mid)}','#{html_escape(emoji)}')">#{html_escape(label)}</button>)
    end
    if msgid
      out << %(<button class="react-btn" type="button" onclick="window.openReactPicker('#{html_escape(msgid)}')" title="React">+</button>)
    end
    out << "</span>"
    out
  end

  # Build msgid → { nick:, text: } from a history list for reply badge fill-in.
  def parent_lookup_from_history(history)
    history.each_with_object({}) do |msg, map|
      mid = msg[:msgid].to_s
      next if mid.empty?
      map[mid] = {
        nick: msg[:sender].to_s.split("!").first,
        text: msg[:text].to_s
      }
    end
  end

  # Returns [channel, ops_array] or nil. ops_array = [[mode_char, adding, target], ...]
  def parse_member_change(line)
    line = line.chomp.delete_suffix("\r")
    rest = line[1..] or return nil # strip ':'
    sp = rest.index(" ") or return nil
    prefix = rest[0...sp]
    cmd_and_args = rest[(sp + 1)..]
    nick = prefix.split("!").first
    parts = cmd_and_args.split
    cmd = parts[0]
    case cmd
    when "JOIN"
      channel = parts[1].to_s.delete_prefix(":")
      # extended-join: JOIN #channel account :realname
      # account is the DID (or * for unauthenticated).
      account = parts[2] && parts[2].start_with?("did:") ? parts[2] : nil
      { kind: :join, channel: channel, nick: nick, account: account }
    when "PART"
      channel = parts[1].to_s.delete_prefix(":")
      { kind: :part, channel: channel, nick: nick }
    when "QUIT"
      { kind: :quit, nick: nick }
    when "MODE"
      channel = parts[1].to_s.delete_prefix(":")
      return nil unless channel.start_with?("#", "&")
      modestring = parts[2].to_s
      ops = []
      adding = true
      arg_idx = 3
      modestring.each_char do |c|
        case c
        when "+" then adding = true
        when "-" then adding = false
        when "o", "h", "v"
          target = parts[arg_idx]
          arg_idx += 1
          ops << [c, adding, target] if target
        end
      end
      { kind: :mode, channel: channel, ops: ops }
    end
  end

  def parse_topic_change(line, current_channel)
    line = line.chomp.delete_suffix("\r")
    rest = line[1..] or return nil # strip ':'
    colon_idx = rest.index(" :") or return nil
    before = rest[0...colon_idx]
    text = rest[(colon_idx + 2)..]
    tokens = before.split
    _source = tokens[0]
    second = tokens[1]
    channel =
      if second.to_s.casecmp?("TOPIC")
        tokens[2]
      elsif second == "332"
        tokens[3] # _nick = tokens[2]
      else
        return nil
      end
    channel.to_s.casecmp?(current_channel) ? text : nil
  end

  def parse_channel_error(line, current_channel)
    line = line.chomp.delete_suffix("\r")
    rest = line[1..] or return nil
    tokens = rest.split
    _server = tokens[0]
    numeric = tokens[1]
    return nil unless %w[442 471 473 474 475 477 482].include?(numeric)
    _nick = tokens[2]
    channel = tokens[3]
    return nil unless channel.to_s.casecmp?(current_channel)
    case numeric
    when "442" then "You are not on that channel."
    when "471" then "#{channel} is full."
    when "473" then "#{channel} is invite-only."
    when "474" then "You are banned from #{channel}."
    when "475" then "#{channel} requires a channel key."
    when "477"
      # Server distinguishes guest vs policy-gated (ACCEPT required).
      trailing = line.split(" :", 2)[1].to_s
      if trailing.include?("policy acceptance")
        "#{channel} requires policy acceptance — open the policy dialog and accept, or wait for auto-accept."
      else
        "#{channel} requires authentication — sign in to join."
      end
    when "482" then "You must be a channel operator to change the topic."
    end
  end

  def is_353?(line)
    line = line.chomp.delete_suffix("\r")
    rest = line[1..] or return false
    sp = rest.index(" ") or return false
    rest[(sp + 1)..].start_with?("353 ")
  end

  def parse_account_did(line)
    line = line.chomp.delete_suffix("\r")
    _prefix, rest = line[1..] ? [line[0], line[1..]] : [nil, nil]
    return nil unless rest
    sp = rest.index(" ") or return nil
    after_prefix = rest[(sp + 1)..]
    cmd, did = after_prefix.split(" ", 2)
    return nil unless cmd == "ACCOUNT"
    return nil if did == "*"
    did
  end

  def parse_333_did(line)
    line = line.chomp.delete_suffix("\r")
    rest = line[1..] or return nil
    _prefix, after = rest.split(" ", 2)
    # after = "333 nick #chan did:plc:xxx timestamp"
    parts = after.split(" ", 4)
    return nil if parts.size < 4 || parts[0] != "333"
    did = parts[3].split(" ").first
    did if did.to_s.start_with?("did:plc:")
  end

  def notice_row(line, ts_html)
    %(<div class="notice">#{ts_html}<span class="body">#{html_escape(line)}</span></div>)
  end
end