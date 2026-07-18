namespace Freeq.WinUI.Models;

/// <summary>A pinned message reference returned by the PINS IRC command.</summary>
public class PinEntry
{
    public string Channel { get; set; } = string.Empty;
    public string MsgId { get; set; } = string.Empty;
    public string PinnedBy { get; set; } = string.Empty;
    public DateTimeOffset PinnedAt { get; set; }

    public string PinnedAtDisplay => PinnedAt.ToLocalTime().ToString("g");
    public string Label => $"[{MsgId[..Math.Min(8, MsgId.Length)]}…] pinned by {PinnedBy}";
}
