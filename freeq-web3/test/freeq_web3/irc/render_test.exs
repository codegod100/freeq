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
end
