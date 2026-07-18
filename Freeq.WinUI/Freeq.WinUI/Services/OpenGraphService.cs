using System.Text.Json;

namespace Freeq.WinUI.Services;

public class OpenGraphData
{
    public string Url { get; set; } = string.Empty;
    public string? Title { get; set; }
    public string? Description { get; set; }
    public string? Image { get; set; }
    public string? SiteName { get; set; }
}

public static class OpenGraphService
{
    public static async Task<OpenGraphData?> FetchAsync(string serverUrl, string url)
    {
        using var client = new HttpClient();
        var baseUri = UploadService.BuildBaseUri(serverUrl);
        var requestUri = new Uri(baseUri, $"/api/v1/og?url={Uri.EscapeDataString(url)}");

        var resp = await client.GetAsync(requestUri);
        if (!resp.IsSuccessStatusCode) return null;

        var json = await resp.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        return new OpenGraphData
        {
            Url = url,
            Title = root.TryGetProperty("title", out var t) ? t.GetString() : null,
            Description = root.TryGetProperty("description", out var d) ? d.GetString() : null,
            Image = root.TryGetProperty("image", out var i) ? i.GetString() : null,
            SiteName = root.TryGetProperty("site_name", out var s) ? s.GetString() : null,
        };
    }
}
