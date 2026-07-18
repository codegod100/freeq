namespace Freeq.WinUI.Models;

public class UserProfileInfo
{
    public string Nick { get; set; } = string.Empty;
    public string? Did { get; set; }
    public string? BlueskyHandle { get; set; }
    public bool CanModerate { get; set; }

    public string DisplayDid => string.IsNullOrWhiteSpace(Did) ? "Guest" : Did!;
    public string DisplayHandle => string.IsNullOrWhiteSpace(BlueskyHandle) ? "Unavailable" : BlueskyHandle!;
}
