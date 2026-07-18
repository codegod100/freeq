namespace Freeq.WinUI.Models;

/// <summary>Represents one entry returned by the server LIST command (RPL_LIST 322).</summary>
public class ChannelListEntry
{
    public string Name { get; set; } = string.Empty;
    public int MemberCount { get; set; }
    public string Topic { get; set; } = string.Empty;
}
