namespace Freeq.WinUI.Models;

public class BookmarkEntry
{
    public string Channel { get; set; } = string.Empty;
    public string MessageId { get; set; } = string.Empty;
    public string Nick { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public DateTimeOffset MessageTimestamp { get; set; }
    public DateTimeOffset BookmarkedAt { get; set; } = DateTimeOffset.Now;

    public string Label => $"{Channel} · {Nick}";
    public string Preview => Content.Length <= 120 ? Content : Content[..120] + "...";
}