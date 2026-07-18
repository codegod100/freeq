namespace Freeq.WinUI.Models;

public class MessageSearchResult
{
    public string Channel { get; set; } = string.Empty;
    public string MessageId { get; set; } = string.Empty;
    public string Nick { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public DateTimeOffset Timestamp { get; set; }

    public string Label => $"[{Channel}] {Nick}: {Content}";
    public string TimeLabel => Timestamp.ToLocalTime().ToString("g");
}
