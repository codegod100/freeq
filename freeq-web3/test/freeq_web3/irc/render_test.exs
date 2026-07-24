defmodule FreeqWeb3.Irc.RenderTest do
  use ExUnit.Case, async: true

  alias FreeqWeb3.Irc.Render

  test "canonical_channel adds #" do
    assert Render.canonical_channel("freeq") == "#freeq"
    assert Render.canonical_channel("#freeq") == "#freeq"
  end

  test "parse_irc_tags" do
    {tags, rest} =
      Render.parse_irc_tags("@msgid=abc;time=2024-01-01T00:00:00.000Z :nick!u@h PRIVMSG #c :hi")

    assert tags["msgid"] == "abc"
    assert String.starts_with?(rest, ":nick!")
  end

  test "should_emit? for PRIVMSG to channel" do
    line = ":alice!a@h PRIVMSG #freeq :hello"
    assert Render.should_emit?(line, "#freeq")
    refute Render.should_emit?(line, "#other")
  end

  test "should_emit? scopes JOIN/PART to the target channel (no fan-out)" do
    join = ":nandi.uk!u@h JOIN #dev"
    assert Render.should_emit?(join, "#dev")
    refute Render.should_emit?(join, "#freeq")
    refute Render.should_emit?(join, "#other")

    # Extended-join / colon form used by some servers.
    join_colon = ":nandi.uk!u@h JOIN :#freeq"
    assert Render.should_emit?(join_colon, "#freeq")
    refute Render.should_emit?(join_colon, "#dev")

    part = ":nandi.uk!u@h PART #dev :bye"
    assert Render.should_emit?(part, "#dev")
    refute Render.should_emit?(part, "#freeq")
  end

  test "extract_irc_target handles JOIN with optional colon" do
    assert Render.extract_irc_target("JOIN #freeq") == "#freeq"
    assert Render.extract_irc_target("JOIN :#freeq") == "#freeq"
    assert Render.extract_irc_target("PART #dev :reason") == "#dev"
    assert Render.extract_irc_target("PRIVMSG alice :hi") == nil
  end

  test "should_emit? ignores TAGMSG and CAP" do
    refute Render.should_emit?("@+react=👍 :a!u@h TAGMSG #freeq", "#freeq")
    refute Render.should_emit?(":server CAP * ACK :sasl", "#freeq")
  end

  test "parse_message_line PRIVMSG" do
    line = "@msgid=m1 :bob!b@h PRIVMSG #freeq :hey there"
    row = Render.parse_message_line(line)
    assert row.kind == :msg
    assert row.nick == "bob"
    assert row.text == "hey there"
    assert row.msgid == "m1"
  end

  test "parse_353_members" do
    line = ":irc.freeq.at 353 me = #freeq :@alice +bob carol"
    members = Render.parse_353_members(line)
    assert length(members) == 3
    alice = Enum.find(members, &(&1.nick == "alice"))
    assert alice.op
    bob = Enum.find(members, &(&1.nick == "bob"))
    assert bob.voiced
  end

  test "nick_color_class is stable" do
    assert Render.nick_color_class("alice") == Render.nick_color_class("alice")
    assert Render.nick_color_class("alice") in ~w(n1 n2 n3 n4 n5 n6 n7 n8)
  end

  test "history_row from REST payload" do
    row =
      Render.history_row(%{
        "sender" => "alice!a@h",
        "text" => "hi",
        "timestamp" => 1_700_000_000,
        "msgid" => "ulid1",
        "tags" => %{}
      })

    assert row.nick == "alice"
    assert row.text == "hi"
    assert row.msgid == "ulid1"
  end

  test "parse_reactions_tag" do
    map = Render.parse_reactions_tag("👍:alice,bob;❤️:carol")
    assert map["👍"] == ["alice", "bob"]
    assert map["❤️"] == ["carol"]
  end

  test "history_row includes reactions from freeq.at/reactions tag" do
    row =
      Render.history_row(%{
        "sender" => "alice!a@h",
        "text" => "hi",
        "timestamp" => 1_700_000_000,
        "msgid" => "ulid1",
        "tags" => %{"+freeq.at/reactions" => "👍:alice"}
      })

    assert row.reactions["👍"] == ["alice"]
  end

  test "parse_tagmsg_reaction add" do
    line = "@+react=👍;+reply=msg123 :bob!b@h TAGMSG #freeq"
    assert {"msg123", "👍", "bob", true, "#freeq"} = Render.parse_tagmsg_reaction(line)
  end

  test "parse_tagmsg_reaction remove" do
    line = "@+freeq.at/unreact=❤️;+reply=msg99 :alice!a@h TAGMSG #freeq"
    assert {"msg99", "❤️", "alice", false, "#freeq"} = Render.parse_tagmsg_reaction(line)
  end

  test "parse_message_line captures +reply parent" do
    line = "@msgid=m2;+reply=m1 :bob!b@h PRIVMSG #freeq :replying"
    row = Render.parse_message_line(line)
    assert row.parent == "m1"
    assert row.reactions == %{}
  end
end
