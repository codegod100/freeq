using Freeq.WinUI.Services;

namespace Freeq.WinUI.Tests;

public class IrcParserTests
{
    // --- Basic command ---

    [Fact]
    public void ParseIrcMessage_Ping_NoPrefix()
    {
        var msg = IrcClient.ParseIrcMessage("PING :server.example.com");
        Assert.Null(msg.Prefix);
        Assert.Equal("PING", msg.Command);
        Assert.Single(msg.Params);
        Assert.Equal("server.example.com", msg.Params[0]);
    }

    // --- Prefix + command ---

    [Fact]
    public void ParseIrcMessage_Privmsg_WithPrefixAndTrailingParam()
    {
        var msg = IrcClient.ParseIrcMessage(":alice!alice@host PRIVMSG #freeq :hello world");
        Assert.Equal("alice!alice@host", msg.Prefix);
        Assert.Equal("PRIVMSG", msg.Command);
        Assert.Equal(2, msg.Params.Length);
        Assert.Equal("#freeq", msg.Params[0]);
        Assert.Equal("hello world", msg.Params[1]);
    }

    // --- Numeric ---

    [Fact]
    public void ParseIrcMessage_001_Welcome()
    {
        var msg = IrcClient.ParseIrcMessage(":irc.freeq.at 001 alice :Welcome to the Freeq IRC Network alice");
        Assert.Equal("irc.freeq.at", msg.Prefix);
        Assert.Equal("001", msg.Command);
        Assert.Equal(2, msg.Params.Length);
        Assert.Equal("alice", msg.Params[0]);
        Assert.StartsWith("Welcome", msg.Params[1]);
    }

    // --- Tags ---

    [Fact]
    public void ParseIrcMessage_TagsPresent_ParsedCorrectly()
    {
        var msg = IrcClient.ParseIrcMessage("@msgid=abc123;time=2026-04-01T00:00:00Z :alice!a@h PRIVMSG #ch :hi");
        Assert.Equal("abc123", msg.Tags["msgid"]);
        Assert.Equal("2026-04-01T00:00:00Z", msg.Tags["time"]);
        Assert.Equal("PRIVMSG", msg.Command);
        Assert.Equal("hi", msg.Params[1]);
    }

    [Fact]
    public void ParseIrcMessage_TagWithNoValue_EmptyString()
    {
        var msg = IrcClient.ParseIrcMessage("@+typing :alice!a@h TAGMSG #ch");
        Assert.True(msg.Tags.ContainsKey("+typing"));
        Assert.Equal("", msg.Tags["+typing"]);
    }

    // --- Extended JOIN (account-notify) ---

    [Fact]
    public void ParseIrcMessage_ExtendedJoin_ThreeParams()
    {
        var msg = IrcClient.ParseIrcMessage(":alice!alice@freeq/plc/abcd JOIN #freeq did:plc:abcd :Alice");
        Assert.Equal("JOIN", msg.Command);
        Assert.Equal(3, msg.Params.Length);
        Assert.Equal("#freeq", msg.Params[0]);
        Assert.Equal("did:plc:abcd", msg.Params[1]);
        Assert.Equal("Alice", msg.Params[2]);
    }

    // --- 353 NAMES reply ---

    [Fact]
    public void ParseIrcMessage_NamesReply_FourParams()
    {
        var msg = IrcClient.ParseIrcMessage(":server 353 alice = #freeq :@alice +bob carol");
        Assert.Equal("353", msg.Command);
        Assert.Equal(4, msg.Params.Length);
        Assert.Equal("#freeq", msg.Params[2]);
        Assert.Equal("@alice +bob carol", msg.Params[3]);
    }

    // --- Malformed / edge cases ---

    [Fact]
    public void ParseIrcMessage_EmptyParams_ReturnsEmptyArray()
    {
        var msg = IrcClient.ParseIrcMessage(":server PONG");
        Assert.Equal("PONG", msg.Command);
        Assert.Empty(msg.Params);
    }

    [Fact]
    public void ParseIrcMessage_ColonOnlyTrailing_EmptyString()
    {
        // A trailing param of ":" means an empty string parameter
        var msg = IrcClient.ParseIrcMessage(":nick!u@h QUIT :");
        Assert.Equal("QUIT", msg.Command);
        Assert.Single(msg.Params);
        Assert.Equal("", msg.Params[0]);
    }

    [Fact]
    public void ParseIrcMessage_MultipleMiddleParams()
    {
        var msg = IrcClient.ParseIrcMessage(":server 332 alice #freeq :The topic here");
        Assert.Equal("332", msg.Command);
        Assert.Equal(3, msg.Params.Length);
        Assert.Equal("alice", msg.Params[0]);
        Assert.Equal("#freeq", msg.Params[1]);
        Assert.Equal("The topic here", msg.Params[2]);
    }

    // --- AUTHENTICATE ---

    [Fact]
    public void ParseIrcMessage_Authenticate_Plus()
    {
        var msg = IrcClient.ParseIrcMessage("AUTHENTICATE +");
        Assert.Equal("AUTHENTICATE", msg.Command);
        Assert.Single(msg.Params);
        Assert.Equal("+", msg.Params[0]);
    }

    [Fact]
    public void ParseIrcMessage_Authenticate_Base64Challenge()
    {
        var challenge = "dGVzdC1jaGFsbGVuZ2U=";
        var msg = IrcClient.ParseIrcMessage($"AUTHENTICATE {challenge}");
        Assert.Equal("AUTHENTICATE", msg.Command);
        Assert.Equal(challenge, msg.Params[0]);
    }

    [Fact]
    public void ParseIrcMessage_TagMsg_ReactionWithReply()
    {
        var msg = IrcClient.ParseIrcMessage("@+react=👍;+reply=msg-123 :bob!u@h TAGMSG #freeq");
        Assert.Equal("TAGMSG", msg.Command);
        Assert.Equal("#freeq", msg.Params[0]);
        Assert.Equal("👍", msg.Tags["+react"]);
        Assert.Equal("msg-123", msg.Tags["+reply"]);
    }

    [Fact]
    public void ParseIrcMessage_AwayNotify_WithReason()
    {
        var msg = IrcClient.ParseIrcMessage(":alice!u@h AWAY :stepped out");
        Assert.Equal("AWAY", msg.Command);
        Assert.Single(msg.Params);
        Assert.Equal("stepped out", msg.Params[0]);
    }
}
