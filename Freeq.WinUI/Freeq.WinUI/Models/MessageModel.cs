using Microsoft.UI.Xaml.Media;
using System.Collections.ObjectModel;
using System.ComponentModel;

namespace Freeq.WinUI.Models;

public class MessageModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private void Notify(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // Self-reference for x:Bind Tag bindings
    public MessageModel Self => this;

    public string Id { get; set; } = string.Empty;
    public string Nick { get; set; } = string.Empty;
    public DateTimeOffset Timestamp { get; set; }
    public bool IsVerified { get; set; }
    public string? Did { get; set; }
    public bool IsSigned { get; set; }

    private string _content = string.Empty;
    public string Content
    {
        get => _content;
        set { _content = value; Notify(nameof(Content)); }
    }

    private bool _isEdited;
    public bool IsEdited
    {
        get => _isEdited;
        set { _isEdited = value; Notify(nameof(IsEdited)); }
    }

    private bool _isDeleted;
    public bool IsDeleted
    {
        get => _isDeleted;
        set { _isDeleted = value; Notify(nameof(IsDeleted)); }
    }

    public string TimeString => Timestamp.LocalDateTime.ToString("h:mm tt");
    public string DateString => Timestamp.LocalDateTime.ToString("MMMM d, yyyy");
    public string NickInitial => string.IsNullOrEmpty(Nick) ? "?" : Nick[..1].ToUpper();

    // Design system: hash-assigned nick color from the 5-hue palette
    public SolidColorBrush NickBrush => NickColor.ForNick(Nick);
    public SolidColorBrush AvatarBackgroundBrush => NickColor.AvatarBackgroundForNick(Nick);

    // Shortened DID for the verified badge chip (first 16 chars: "did:plc:abcdefgh")
    public string ShortDid => Did is { Length: > 16 } d ? d[..16] : Did ?? "";
    public bool HasDid => !string.IsNullOrEmpty(Did);

    // Aggregated reactions rendered as emoji bubbles below the message body.
    public ObservableCollection<ReactionSummary> Reactions { get; } = [];
    public bool HasReactions => Reactions.Count > 0;

    private readonly Dictionary<string, HashSet<string>> _reactionUsers = new(StringComparer.Ordinal);

    public void AddReaction(string emoji, string nick, bool isSelf)
    {
        if (string.IsNullOrWhiteSpace(emoji) || string.IsNullOrWhiteSpace(nick)) return;

        if (!_reactionUsers.TryGetValue(emoji, out var users))
        {
            users = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            _reactionUsers[emoji] = users;
        }

        users.Add(nick);
        RebuildReactionSummaries(isSelfNick: nick, isSelf: isSelf);
    }

    public void ToggleReaction(string emoji, string nick)
    {
        if (string.IsNullOrWhiteSpace(emoji) || string.IsNullOrWhiteSpace(nick)) return;

        if (!_reactionUsers.TryGetValue(emoji, out var users))
        {
            users = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            _reactionUsers[emoji] = users;
        }

        if (!users.Add(nick))
            users.Remove(nick);

        if (users.Count == 0)
            _reactionUsers.Remove(emoji);

        RebuildReactionSummaries(isSelfNick: nick, isSelf: true);
    }

    public bool HasReactionFrom(string emoji, string nick)
    {
        return _reactionUsers.TryGetValue(emoji, out var users) && users.Contains(nick);
    }

    private void RebuildReactionSummaries(string isSelfNick, bool isSelf)
    {
        var mine = isSelf ? isSelfNick : string.Empty;
        var updated = _reactionUsers
            .OrderBy(kv => kv.Key, StringComparer.Ordinal)
            .Select(kv => new ReactionSummary
            {
                Emoji = kv.Key,
                Count = kv.Value.Count,
                IsMine = !string.IsNullOrEmpty(mine) && kv.Value.Contains(mine),
            })
            .ToList();

        Reactions.Clear();
        foreach (var item in updated)
            Reactions.Add(item);

        Notify(nameof(Reactions));
        Notify(nameof(HasReactions));
    }
}
