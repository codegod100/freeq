namespace Freeq.WinUI.Models;

public class GovernanceEvent
{
    public DateTimeOffset Timestamp { get; set; } = DateTimeOffset.Now;
    public string Channel { get; set; } = string.Empty;
    public string Actor { get; set; } = string.Empty;
    public string Action { get; set; } = string.Empty;
    public string Detail { get; set; } = string.Empty;

    public string Label => $"{Timestamp.LocalDateTime:t}  {Actor}  {Action}";
    public string Description => string.IsNullOrWhiteSpace(Detail) ? Channel : $"{Channel}  {Detail}";
}