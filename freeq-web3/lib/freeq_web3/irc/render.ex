defmodule FreeqWeb3.Irc.Render do
  @moduledoc """
  Port of freeq-web2 `IrcRender` / freeq-webui `irc_render.rs`.

  Pure functions: IRC line parsing, member lists, nick colors, history rows.
  LiveView renders structured maps rather than HTML strings where possible.
  """

  @nick_classes ~w(n1 n2 n3 n4 n5 n6 n7 n8)

  @doc "Ensure channel has a leading `#`."
  def canonical_channel(s) when is_binary(s) do
    if String.starts_with?(s, "#"), do: s, else: "#" <> s
  end

  def canonical_channel(s), do: canonical_channel(to_string(s))

  def bare_channel(s), do: s |> canonical_channel() |> String.trim_leading("#")

  @doc "djb2 nick color class (`n1`…`n8`)."
  def nick_color_class(nick) when is_binary(nick) do
    h =
      nick
      |> :erlang.binary_to_list()
      |> Enum.reduce(5381, fn b, h -> rem(h * 33 + b, 0x1_0000_0000) end)

    Enum.at(@nick_classes, rem(h, 8))
  end

  def nick_color_class(_), do: "n1"

  @doc "Parse `@key=value;… rest` → `{tags_map, rest}`."
  def parse_irc_tags(line) when is_binary(line) do
    line = line |> String.trim_trailing("\r") |> String.trim_trailing("\n")

    if String.starts_with?(line, "@") do
      rest = String.slice(line, 1..-1//1)

      case String.split(rest, " ", parts: 2) do
        [tag_part, after_line] ->
          tags =
            tag_part
            |> String.split(";")
            |> Enum.reduce(%{}, fn item, acc ->
              case String.split(item, "=", parts: 2) do
                [k, v] when k != "" -> Map.put(acc, k, unescape_tag_value(v))
                [k] when k != "" -> Map.put(acc, k, "")
                _ -> acc
              end
            end)

          {tags, after_line}

        _ ->
          {%{}, line}
      end
    else
      {%{}, line}
    end
  end

  def unescape_tag_value(s) do
    do_unescape(String.to_charlist(s), [])
  end

  defp do_unescape([], acc), do: acc |> Enum.reverse() |> List.to_string()

  defp do_unescape([?\\, ?: | rest], acc), do: do_unescape(rest, [?; | acc])
  defp do_unescape([?\\, ?s | rest], acc), do: do_unescape(rest, [?\s | acc])
  defp do_unescape([?\\, ?\\ | rest], acc), do: do_unescape(rest, [?\\ | acc])
  defp do_unescape([?\\, ?r | rest], acc), do: do_unescape(rest, [?\r | acc])
  defp do_unescape([?\\, ?n | rest], acc), do: do_unescape(rest, [?\n | acc])
  defp do_unescape([?\\], acc), do: do_unescape([], [?\\ | acc])
  defp do_unescape([?\\, c | rest], acc), do: do_unescape(rest, [c, ?\\ | acc])
  defp do_unescape([c | rest], acc), do: do_unescape(rest, [c | acc])

  def escape_tag_value(s) when is_binary(s) do
    s
    |> String.graphemes()
    |> Enum.map_join(fn
      ";" -> "\\:"
      " " -> "\\s"
      "\\" -> "\\\\"
      "\r" -> "\\r"
      "\n" -> "\\n"
      c -> c
    end)
  end

  @doc """
  Extract the token from an IRC `PING` line.

  freeq-server sends server-prefixed pings like
  `:irc.freeq.at PING irc.freeq.at`. Also accepts unprefixed `PING :token`
  and tag-prefixed variants. Returns `nil` when the line is not a PING.
  """
  def ping_token(line) when is_binary(line) do
    payload =
      line
      |> String.trim_trailing("\r")
      |> String.trim_trailing("\n")
      |> String.replace(~r/\A@\S+\s+/, "")
      |> String.replace(~r/\A:[^\s]+\s+/, "")

    if String.starts_with?(payload, "PING ") do
      payload
      |> String.slice(5..-1//1)
      |> String.trim_leading(":")
      |> String.trim()
    end
  end

  def ping_token(_), do: nil

  @doc "IRCv3 server-time tag → DateTime (UTC), else now."
  def time_from_tags(tags) when is_map(tags) do
    raw = tags["time"] || tags["+time"] || ""

    case raw do
      "" ->
        DateTime.utc_now()

      ts ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> dt
          _ -> DateTime.utc_now()
        end
    end
  end

  def day_key(%DateTime{} = t), do: Calendar.strftime(t, "%Y-%m-%d")
  def day_key(_), do: nil

  @doc "Parse a live IRC line into a structured row map, or nil if uninteresting."
  def parse_message_line(line, opts \\ []) do
    own_nick = Keyword.get(opts, :own_nick)
    line = String.trim_trailing(line, "\r")
    {tags, rest_with_prefix} = parse_irc_tags(line)
    msg_time = time_from_tags(tags)

    if not String.starts_with?(rest_with_prefix, ":") do
      %{
        id: tags["msgid"] || unique_id(),
        kind: :notice,
        nick: nil,
        text: rest_with_prefix,
        time: msg_time,
        msgid: tags["msgid"],
        tags: tags,
        own: false
      }
    else
      rest = String.slice(rest_with_prefix, 1..-1//1)

      case String.split(rest, " ", parts: 2) do
        [prefix, cmd_and_args] ->
          nick = prefix |> String.split("!") |> hd()
          parts = String.split(cmd_and_args, " ", parts: 3)
          cmd = Enum.at(parts, 0) || ""

          cond do
            cmd in ~w(PRIVMSG NOTICE) ->
              text = (Enum.at(parts, 2) || "") |> String.trim_leading(":")
              edit_orig = tags["+draft/edit"]
              msgid = edit_orig || tags["msgid"]
              own = nick_matches?(nick, own_nick)

              %{
                id: msgid || unique_id(),
                kind: if(cmd == "NOTICE", do: :notice, else: :msg),
                nick: nick,
                text: text,
                time: msg_time,
                msgid: msgid,
                tags: tags,
                own: own,
                color: nick_color_class(nick),
                parent: reply_parent_msgid(tags),
                account: tags["account"] || tags["+account"],
                reactions: parse_reactions_tag(tags["+freeq.at/reactions"] || "")
              }

            cmd in ~w(JOIN PART QUIT) ->
              %{
                id: unique_id(),
                kind: if(cmd == "JOIN", do: :join, else: :part),
                nick: nick,
                text: String.downcase(cmd),
                time: msg_time,
                msgid: nil,
                tags: tags,
                own: false,
                color: nick_color_class(nick)
              }

            true ->
              %{
                id: unique_id(),
                kind: :notice,
                nick: nil,
                text: line,
                time: msg_time,
                msgid: nil,
                tags: tags,
                own: false
              }
          end

        _ ->
          nil
      end
    end
  end

  defp nick_matches?(nick, own) when is_binary(nick) and is_binary(own) do
    String.downcase(nick) == String.downcase(own)
  end

  defp nick_matches?(_, _), do: false

  def reply_parent_msgid(tags) when is_map(tags) do
    tags["+reply"] || tags["reply"] || tags["draft/reply"]
  end

  def reply_parent_msgid(_), do: nil

  @doc "Convert a REST history message into a row map."
  def history_row(msg) when is_map(msg) do
    nick =
      (msg["sender"] || msg[:sender] || "")
      |> to_string()
      |> String.split("!")
      |> hd()

    tags = msg["tags"] || msg[:tags] || %{}
    ts = msg["timestamp"] || msg[:timestamp] || System.system_time(:second)

    time =
      case ts do
        n when is_integer(n) -> DateTime.from_unix!(n)
        n when is_float(n) -> DateTime.from_unix!(trunc(n))
        _ -> DateTime.utc_now()
      end

    msgid = msg["msgid"] || msg[:msgid]

    %{
      id: msgid || unique_id(),
      kind: :msg,
      nick: nick,
      text: to_string(msg["text"] || msg[:text] || ""),
      time: time,
      msgid: msgid,
      tags: tags,
      own: false,
      color: nick_color_class(nick),
      parent: reply_parent_msgid(tags),
      account: tags["account"] || tags["+account"],
      reactions: parse_reactions_tag(tags["+freeq.at/reactions"] || "")
    }
  end

  def parse_reactions_tag(value) when is_binary(value) do
    value
    |> String.split(";")
    |> Enum.reduce(%{}, fn group, acc ->
      case String.split(group, ":", parts: 2) do
        [emoji, nicks] when emoji != "" ->
          list = nicks |> String.split(",") |> Enum.reject(&(&1 == ""))
          if list == [], do: acc, else: Map.put(acc, emoji, list)

        _ ->
          acc
      end
    end)
  end

  def parse_reactions_tag(_), do: %{}

  @doc "Should this line emit into the message pane for `current_channel`?"
  def should_emit?(line, current_channel) do
    line = String.trim_trailing(line, "\r")

    cond do
      String.starts_with?(line, "PING ") or String.starts_with?(line, "PONG ") ->
        false

      true ->
        {_tags, after_tags} = parse_irc_tags(line)

        if not String.starts_with?(after_tags, ":") do
          false
        else
          rest = String.slice(after_tags, 1..-1//1)

          case String.split(rest, " ", parts: 2) do
            [_prefix, after_prefix] ->
              cmd = after_prefix |> String.split(" ") |> hd() |> to_string()

              cond do
                String.match?(cmd, ~r/^\d{3}$/) ->
                  false

                cmd in ~w(CAP AUTHENTICATE BATCH PING PONG ERROR TAGMSG) ->
                  false

                cmd in ~w(PRIVMSG NOTICE JOIN PART QUIT TOPIC KICK NICK MODE) ->
                  target = extract_irc_target(after_prefix)

                  cond do
                    cmd in ~w(PRIVMSG NOTICE) and is_nil(target) ->
                      false

                    cmd in ~w(PRIVMSG NOTICE) ->
                      String.downcase(canonical_channel(target)) ==
                        String.downcase(canonical_channel(current_channel))

                    is_nil(target) ->
                      true

                    true ->
                      String.downcase(canonical_channel(target)) ==
                        String.downcase(canonical_channel(current_channel))
                  end

                true ->
                  false
              end

            _ ->
              false
          end
        end
    end
  end

  @doc """
  Channel target only (`#` / `&` / `+` / `!`). Nick targets return nil so
  callers can treat them as DMs rather than channel messages.

  JOIN/PART must be included — otherwise `should_emit?/2` treats them as
  channel-less and fans one join out into every joined pane (re-JOIN after
  SASL becomes "nandi.uk join" spam N times).
  """
  def extract_irc_target(after_prefix) do
    case String.split(after_prefix, " ", parts: 3) do
      [command, target | _]
      when command in ~w(PRIVMSG NOTICE TOPIC MODE KICK INVITE JOIN PART) ->
        target = String.trim_leading(target, ":")
        if String.starts_with?(target, ["#", "&", "+", "!"]), do: target, else: nil

      _ ->
        nil
    end
  end

  def is_353?(line) do
    line = String.trim_trailing(line, "\r")
    String.contains?(line, " 353 ")
  end

  def parse_353_members(line) do
    case String.split(line, " :", parts: 2) do
      [_, names] ->
        names
        |> String.split(" ")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn token ->
          {pfx, nick} = split_prefix(token)

          %{
            nick: nick,
            op: ?@ in pfx or ?~ in pfx or ?& in pfx,
            halfop: ?% in pfx,
            voiced: ?+ in pfx,
            account: nil
          }
        end)

      _ ->
        []
    end
  end

  defp split_prefix(token) do
    chars = String.to_charlist(token)
    {pfx, rest} = Enum.split_while(chars, &(&1 in ~c"@%+~&"))
    {pfx, List.to_string(rest)}
  end

  def channel_from_353(line) do
    # … 353 nick = #channel :names  OR  353 nick * #channel :names
    {_tags, after_line} = parse_irc_tags(line)

    rest =
      if String.starts_with?(after_line, ":"),
        do: String.slice(after_line, 1..-1//1),
        else: after_line

    parts = String.split(rest)

    Enum.find(parts, fn p -> String.starts_with?(p, ["#", "&"]) end)
  end

  def parse_member_change(line) do
    line = String.trim_trailing(line, "\r")
    {_tags, after_line} = parse_irc_tags(line)

    if not String.starts_with?(after_line, ":") do
      nil
    else
      rest = String.slice(after_line, 1..-1//1)

      case String.split(rest, " ", parts: 2) do
        [prefix, cmd_and_args] ->
          nick = prefix |> String.split("!") |> hd()
          parts = String.split(cmd_and_args)
          cmd = Enum.at(parts, 0)

          case cmd do
            "JOIN" ->
              channel = (Enum.at(parts, 1) || "") |> String.trim_leading(":")
              account = Enum.at(parts, 2)
              account = if account && String.starts_with?(account, "did:"), do: account, else: nil
              %{kind: :join, channel: channel, nick: nick, account: account}

            "PART" ->
              channel = (Enum.at(parts, 1) || "") |> String.trim_leading(":")
              %{kind: :part, channel: channel, nick: nick}

            "QUIT" ->
              %{kind: :quit, nick: nick}

            "MODE" ->
              channel = (Enum.at(parts, 1) || "") |> String.trim_leading(":")

              if String.starts_with?(channel, ["#", "&"]) do
                modestring = Enum.at(parts, 2) || ""
                ops = parse_mode_ops(modestring, Enum.drop(parts, 3))
                %{kind: :mode, channel: channel, ops: ops}
              else
                nil
              end

            _ ->
              nil
          end

        _ ->
          nil
      end
    end
  end

  defp parse_mode_ops(modestring, args) do
    {ops, _} =
      modestring
      |> String.graphemes()
      |> Enum.reduce({[], {true, args}}, fn
        "+", {ops, {_add, args}} ->
          {ops, {true, args}}

        "-", {ops, {_add, args}} ->
          {ops, {false, args}}

        c, {ops, {adding, args}} when c in ~w(o h v) ->
          case args do
            [target | rest] -> {[{c, adding, target} | ops], {adding, rest}}
            [] -> {ops, {adding, args}}
          end

        _, acc ->
          acc
      end)

    Enum.reverse(ops)
  end

  def parse_topic_change(line, current_channel) do
    line = String.trim_trailing(line, "\r")
    {_tags, after_line} = parse_irc_tags(line)

    if not String.starts_with?(after_line, ":") do
      nil
    else
      rest = String.slice(after_line, 1..-1//1)

      case String.split(rest, " :", parts: 2) do
        [before, text] ->
          tokens = String.split(before)
          second = Enum.at(tokens, 1)

          channel =
            cond do
              second && String.upcase(second) == "TOPIC" -> Enum.at(tokens, 2)
              second == "332" -> Enum.at(tokens, 3)
              true -> nil
            end

          if channel &&
               String.downcase(to_string(channel)) ==
                 String.downcase(canonical_channel(current_channel)) do
            text
          else
            nil
          end

        _ ->
          nil
      end
    end
  end

  def parse_channel_error(line, current_channel) do
    line = String.trim_trailing(line, "\r")
    {_tags, after_line} = parse_irc_tags(line)

    rest =
      if String.starts_with?(after_line, ":"),
        do: String.slice(after_line, 1..-1//1),
        else: after_line

    tokens = String.split(rest)
    numeric = Enum.at(tokens, 1)
    channel = Enum.at(tokens, 3)

    if (numeric in ~w(442 471 473 474 475 477 482) and
          channel) &&
         String.downcase(channel) == String.downcase(canonical_channel(current_channel)) do
      case numeric do
        "442" ->
          "You are not on that channel."

        "471" ->
          "#{channel} is full."

        "473" ->
          "#{channel} is invite-only."

        "474" ->
          "You are banned from #{channel}."

        "475" ->
          "#{channel} requires a channel key."

        "477" ->
          trailing = line |> String.split(" :", parts: 2) |> Enum.at(1) || ""

          if String.contains?(trailing, "policy acceptance") do
            "#{channel} requires policy acceptance — open the policy dialog and accept, or wait for auto-accept."
          else
            "#{channel} requires authentication — sign in to join."
          end

        "482" ->
          "You must be a channel operator to change the topic."
      end
    else
      nil
    end
  end

  def parse_batch_line(line) do
    line = String.trim_trailing(line, "\r")
    {_tags, after_tags} = parse_irc_tags(line)

    rest =
      if String.starts_with?(after_tags, ":"),
        do: String.slice(after_tags, 1..-1//1),
        else: after_tags

    parts =
      case String.split(rest, " ", parts: 2) do
        [_prefix, after_prefix] ->
          p = String.split(after_prefix)
          if Enum.at(p, 0) == "BATCH", do: p, else: nil

        _ ->
          p = String.split(rest)
          if Enum.at(p, 0) == "BATCH", do: p, else: nil
      end

    case parts do
      nil ->
        nil

      p ->
        ref = Enum.at(p, 1) || ""

        cond do
          String.starts_with?(ref, "+") ->
            {String.slice(ref, 1..-1//1), true, Enum.at(p, 2), Enum.at(p, 3)}

          String.starts_with?(ref, "-") ->
            {String.slice(ref, 1..-1//1), false, nil, nil}

          true ->
            nil
        end
    end
  end

  def parse_tagmsg_reaction(line) do
    {tags, after_line} = parse_irc_tags(line)

    {emoji, added} =
      cond do
        tags["+react"] -> {tags["+react"], true}
        tags["+freeq.at/unreact"] -> {tags["+freeq.at/unreact"], false}
        true -> {nil, nil}
      end

    msgid = tags["+reply"]

    if is_nil(emoji) or is_nil(msgid) or msgid == "" do
      nil
    else
      rest =
        if String.starts_with?(after_line, ":"),
          do: String.slice(after_line, 1..-1//1),
          else: after_line

      parts = String.split(rest)
      nick = parts |> Enum.at(0) |> to_string() |> String.split("!") |> hd()

      if String.upcase(to_string(Enum.at(parts, 1))) == "TAGMSG" do
        channel = (Enum.at(parts, 2) || "") |> String.trim_leading(":")
        {msgid, emoji, nick, added, channel}
      else
        nil
      end
    end
  end

  def parse_forced_nick_rename(line) do
    text = to_string(line)

    cond do
      m = Regex.run(~r/renamed to (Guest\d+)/i, text) -> Enum.at(m, 1)
      m = Regex.run(~r/You are (\S+) \(tied to your account\)/i, text) -> Enum.at(m, 1)
      true -> nil
    end
  end

  @doc """
  Parse an AV state broadcast TAGMSG.
  Returns `{channel, state, session_id, actor, participants, instance, title}` or nil.
  """
  def parse_av_state_tagmsg(line) do
    {tags, after_line} = parse_irc_tags(line)

    if is_nil(tags["+freeq.at/av-state"]) or tags["+freeq.at/av-state"] == "" do
      nil
    else
      rest =
        if String.starts_with?(after_line, ":"),
          do: String.slice(after_line, 1..-1//1),
          else: after_line

      parts = String.split(rest)
      channel = (Enum.at(parts, 2) || "") |> String.trim_leading(":")
      participants = String.to_integer(tags["+freeq.at/av-participants"] || "0")

      {
        canonical_channel(channel),
        tags["+freeq.at/av-state"],
        tags["+freeq.at/av-id"],
        tags["+freeq.at/av-actor"],
        participants,
        tags["+freeq.at/av-instance"],
        tags["+freeq.at/av-title"]
      }
    end
  end

  @doc """
  Parse an AV token directed TAGMSG. Returns `{session_id, token}` or nil.

  `own_nicks` may be a single nick string or a list of candidates (current
  nick, auth nick, etc.) — freeq-server addresses the token to the IRC nick
  at join time, which can race with renames.
  """
  def parse_av_token_tagmsg(line, own_nicks) do
    own_list =
      own_nicks
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    {tags, after_line} = parse_irc_tags(line)

    if is_nil(tags["+freeq.at/av-token"]) or tags["+freeq.at/av-token"] == "" or
         own_list == [] do
      nil
    else
      rest =
        if String.starts_with?(after_line, ":"),
          do: String.slice(after_line, 1..-1//1),
          else: after_line

      parts = String.split(rest)
      target = Enum.at(parts, 2) || ""

      if String.upcase(to_string(Enum.at(parts, 1))) == "TAGMSG" and
           Enum.any?(own_list, &nick_matches?(target, &1)) do
        {tags["+freeq.at/av-id"], tags["+freeq.at/av-token"]}
      else
        nil
      end
    end
  end

  def sanitize_nick(handle) when is_binary(handle) do
    out =
      handle
      |> String.graphemes()
      |> Enum.filter(&String.match?(&1, ~r/[A-Za-z0-9.\-_]/))
      |> Enum.take(20)
      |> Enum.join()

    cond do
      out == "" -> ""
      String.match?(String.first(out), ~r/[A-Za-z]/) -> out
      true -> String.slice("u" <> out, 0, 20)
    end
  end

  # Image URL detection — aligned with freeq-web2 IrcRender / freeq-app MessageList
  # and LinkPreview (so OG cards skip URLs that render as inline images).
  @url_re ~r/https?:\/\/[^\s<>\]\)"'{}|\\^`]+/i
  @image_ext_re ~r/\.(?:jpg|jpeg|png|gif|webp)(?:\?|#|$)/i
  @freeq_media_re ~r/\/api\/v1\/media\//i
  @bsky_cdn_re ~r/cdn\.bsky\.app\/img\//i

  @doc "True when `url` should render as an inline image preview."
  def image_url?(url) when is_binary(url) do
    Regex.match?(@image_ext_re, url) or Regex.match?(@freeq_media_re, url) or
      Regex.match?(@bsky_cdn_re, url)
  end

  def image_url?(_), do: false

  @doc """
  Split message text into typed segments for LiveView rendering.

  Returns a list of:
  - `{:text, binary}` — plain text (may be empty only if input is empty)
  - `{:link, url}` — http(s) URL (not an image)
  - `{:image, url}` — direct image URL / freeq media / bsky CDN

  Only `http`/`https` schemes are linkified. Trailing punctuation is stripped
  from URL matches (web2 parity).
  """
  def text_segments(text) when is_binary(text) do
    if text == "" do
      [{:text, ""}]
    else
      matches = Regex.scan(@url_re, text, return: :index)

      {segments, last} =
        Enum.reduce(matches, {[], 0}, fn [{start, len}], {acc, cursor} ->
          raw = binary_part(text, start, len)
          url = clean_url(raw)
          # How many trailing chars the regex took that clean_url dropped.
          trimmed = byte_size(raw) - byte_size(url)
          url_end = start + len - trimmed

          acc =
            if start > cursor do
              acc ++ [{:text, binary_part(text, cursor, start - cursor)}]
            else
              acc
            end

          acc =
            cond do
              url == "" ->
                # Degenerate — keep original bytes as text
                acc ++ [{:text, binary_part(text, start, len)}]

              image_url?(url) ->
                acc ++ [{:image, url}]

              true ->
                case URI.parse(url) do
                  %URI{scheme: s} when s in ["http", "https"] ->
                    acc ++ [{:link, url}]

                  _ ->
                    acc ++ [{:text, url}]
                end
            end

          {acc, url_end}
        end)

      segments =
        if last < byte_size(text) do
          segments ++ [{:text, binary_part(text, last, byte_size(text) - last)}]
        else
          segments
        end

      if segments == [], do: [{:text, text}], else: segments
    end
  end

  def text_segments(_), do: [{:text, ""}]

  defp clean_url(raw) do
    url =
      raw
      |> to_string()
      |> String.replace(~r/[\x{200B}-\x{200D}\x{FEFF}\x{2060}\x{00AD}]/u, "")
      |> String.trim()
      |> String.trim_leading("<")
      |> String.trim_trailing(">")

    String.replace(url, ~r/[.,;:!?)'"\]]+\z/, "")
  end

  defp unique_id do
    Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end
end
