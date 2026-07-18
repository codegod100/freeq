using System.Text;
using System.Text.Json;
using Freeq.WinUI.Services;

namespace Freeq.WinUI.Tests;

public class OAuthPayloadTests
{
    private static string ToBase64Url(string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        return Convert.ToBase64String(bytes)
            .Replace('+', '-')
            .Replace('/', '_')
            .TrimEnd('=');
    }

    [Fact]
    public void DecodeOAuthPayload_ValidPayload_ReturnsResult()
    {
        var json = """{"did":"did:plc:abc123","web_token":"tok","pds_url":"https://pds.example.com"}""";
        var encoded = ToBase64Url(json);

        var result = OAuthCallbackServer.DecodeOAuthPayload(encoded);

        Assert.NotNull(result);
        Assert.Equal("did:plc:abc123", result.Did);
        Assert.Equal("tok", result.WebToken);
        Assert.Equal("https://pds.example.com", result.PdsUrl);
    }

    [Fact]
    public void DecodeOAuthPayload_EffectiveToken_PrefersWebToken()
    {
        var json = """{"did":"did:plc:x","web_token":"web","token":"app","access_jwt":"jwt"}""";
        var result = OAuthCallbackServer.DecodeOAuthPayload(ToBase64Url(json));

        Assert.Equal("web", result!.EffectiveToken);
    }

    [Fact]
    public void DecodeOAuthPayload_NoWebToken_FallsBackToToken()
    {
        var json = """{"did":"did:plc:x","token":"app","access_jwt":"jwt"}""";
        var result = OAuthCallbackServer.DecodeOAuthPayload(ToBase64Url(json));

        Assert.Equal("app", result!.EffectiveToken);
    }

    [Fact]
    public void DecodeOAuthPayload_NoTokensAtAll_EffectiveTokenIsEmpty()
    {
        var json = """{"did":"did:plc:x"}""";
        var result = OAuthCallbackServer.DecodeOAuthPayload(ToBase64Url(json));

        Assert.Equal("", result!.EffectiveToken);
    }

    [Fact]
    public void DecodeOAuthPayload_InvalidBase64_ReturnsNull()
    {
        var result = OAuthCallbackServer.DecodeOAuthPayload("not-valid-base64!!!");
        Assert.Null(result);
    }

    [Fact]
    public void DecodeOAuthPayload_InvalidJson_ReturnsNull()
    {
        var result = OAuthCallbackServer.DecodeOAuthPayload(ToBase64Url("not json at all"));
        Assert.Null(result);
    }

    [Fact]
    public void DecodeOAuthPayload_PaddingStripped_StillDecodes()
    {
        // Verify that base64url without padding is handled
        var json = """{"did":"did:plc:paddingtest","web_token":"t"}""";
        var encoded = ToBase64Url(json); // already strips padding
        Assert.DoesNotContain("=", encoded);

        var result = OAuthCallbackServer.DecodeOAuthPayload(encoded);
        Assert.Equal("did:plc:paddingtest", result!.Did);
    }

    [Fact]
    public void DecodeOAuthPayload_UrlSafeChars_DecodesCorrectly()
    {
        // Verify - and _ are treated as + and / from standard base64
        var json = """{"did":"did:plc:urlsafe","web_token":"x"}""";
        var standard = Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
        // Manually introduce - and _ to simulate URL-safe encoding
        var urlSafe = standard.Replace('+', '-').Replace('/', '_').TrimEnd('=');

        var result = OAuthCallbackServer.DecodeOAuthPayload(urlSafe);
        Assert.Equal("did:plc:urlsafe", result!.Did);
    }
}
