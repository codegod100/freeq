namespace Freeq.WinUI.Models;

public class ChannelMaskEntry
{
    public string Mask { get; set; } = string.Empty;
    public string SetBy { get; set; } = string.Empty;
    public DateTimeOffset SetAt { get; set; } = DateTimeOffset.Now;

    public string Label => string.IsNullOrWhiteSpace(SetBy)
        ? Mask
        : $"{Mask} (by {SetBy})";
}