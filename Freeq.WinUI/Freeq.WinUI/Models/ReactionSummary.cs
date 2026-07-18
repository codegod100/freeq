namespace Freeq.WinUI.Models;

public class ReactionSummary
{
    // Self-reference for x:Bind Tag bindings
    public ReactionSummary Self => this;

    public string Emoji { get; set; } = string.Empty;
    public int Count { get; set; }
    public bool IsMine { get; set; }

    public string Label => $"{Emoji} {Count}";
}
