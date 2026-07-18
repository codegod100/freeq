using Microsoft.UI.Xaml.Media;

namespace Freeq.WinUI.Models;

public enum MemberRole
{
    Operator,
    HalfOp,
    Voiced,
    Regular
}

public enum PresenceStatus
{
    Online,
    Away,
    Offline
}

public class MemberModel
{
    public string Nick { get; set; } = string.Empty;
    public string? Did { get; set; }
    public string? AwayMessage { get; set; }
    public MemberRole Role { get; set; } = MemberRole.Regular;
    public PresenceStatus Status { get; set; } = PresenceStatus.Online;
    public bool IsVerified => !string.IsNullOrEmpty(Did);
    public string NickInitial => string.IsNullOrEmpty(Nick) ? "?" : Nick[..1].ToUpper();

    public string RoleBadge => Role switch
    {
        MemberRole.Operator => "@",
        MemberRole.HalfOp => "%",
        MemberRole.Voiced => "+",
        _ => ""
    };

    // Design system: hash-assigned nick color from the 5-hue palette
    public SolidColorBrush NickBrush => NickColor.ForNick(Nick);
    public SolidColorBrush AvatarBackgroundBrush => NickColor.AvatarBackgroundForNick(Nick);
}
