using System.Net.Http.Headers;
using System.Text.Json;

namespace Freeq.WinUI.Services;

public class UploadResult
{
    public string Url { get; set; } = string.Empty;
}

public static class UploadService
{
    public static async Task<UploadResult> UploadAsync(string serverUrl, string filePath, string? bearerToken, string? channel, string? altText)
    {
        using var client = new HttpClient();
        var baseUri = BuildBaseUri(serverUrl);
        var uploadUri = new Uri(baseUri, "/api/v1/upload");

        if (!string.IsNullOrWhiteSpace(bearerToken))
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);

        using var form = new MultipartFormDataContent();
        using var fs = File.OpenRead(filePath);
        using var content = new StreamContent(fs);
        content.Headers.ContentType = new MediaTypeHeaderValue(GuessContentType(filePath));
        form.Add(content, "file", Path.GetFileName(filePath));

        if (!string.IsNullOrWhiteSpace(channel))
            form.Add(new StringContent(channel), "channel");

        if (!string.IsNullOrWhiteSpace(altText))
            form.Add(new StringContent(altText), "alt");

        var resp = await client.PostAsync(uploadUri, form);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Upload failed: {(int)resp.StatusCode} {await resp.Content.ReadAsStringAsync()}");

        var json = await resp.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        var url = root.TryGetProperty("url", out var urlEl)
            ? urlEl.GetString()
            : (root.TryGetProperty("blob_url", out var blobEl) ? blobEl.GetString() : null);

        if (string.IsNullOrWhiteSpace(url))
            throw new InvalidOperationException("Upload succeeded but no URL was returned by server");

        return new UploadResult { Url = url! };
    }

    public static Uri BuildBaseUri(string serverUrl)
    {
        var uri = new Uri(serverUrl);
        var scheme = uri.Scheme.Equals("wss", StringComparison.OrdinalIgnoreCase) ? "https"
            : (uri.Scheme.Equals("ws", StringComparison.OrdinalIgnoreCase) ? "http" : uri.Scheme);
        return new Uri($"{scheme}://{uri.Host}{(uri.IsDefaultPort ? "" : $":{uri.Port}")}");
    }

    private static string GuessContentType(string path)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        return ext switch
        {
            ".png" => "image/png",
            ".jpg" or ".jpeg" => "image/jpeg",
            ".gif" => "image/gif",
            ".webp" => "image/webp",
            ".mp4" => "video/mp4",
            ".webm" => "video/webm",
            ".mp3" => "audio/mpeg",
            ".ogg" => "audio/ogg",
            ".wav" => "audio/wav",
            ".pdf" => "application/pdf",
            _ => "application/octet-stream",
        };
    }
}
