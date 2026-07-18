using Microsoft.UI;
using Microsoft.UI.Xaml.Media;

namespace Freeq.WinUI.Models;

/// <summary>
/// Deterministic nick-to-color mapping using the 5-hue palette from DESIGN.md.
/// The authenticated user's own nick is always teal (AccentColor).
/// </summary>
internal static class NickColor
{
    // 5 hues from the design palette — purple, blue, pink, orange, teal
    private static readonly (byte R, byte G, byte B)[] Hues =
    [
        (0xB1, 0x8C, 0xFF), // Purple  #B18CFF
        (0x5C, 0x9E, 0xFF), // Blue    #5C9EFF
        (0xFF, 0x6E, 0xB4), // Pink    #FF6EB4
        (0xFF, 0x95, 0x47), // Orange  #FF9547
        (0x00, 0xD4, 0xAA), // Teal    #00D4AA
    ];

    public static SolidColorBrush ForNick(string nick)
    {
        var (r, g, b) = Hues[HueIndex(nick)];
        return new SolidColorBrush(ColorHelper.FromArgb(0xFF, r, g, b));
    }

    /// <summary>A 12%-opacity tint of the nick color, used for avatar backgrounds.</summary>
    public static SolidColorBrush AvatarBackgroundForNick(string nick)
    {
        var (r, g, b) = Hues[HueIndex(nick)];
        return new SolidColorBrush(ColorHelper.FromArgb(0x1E, r, g, b)); // ~12% opacity
    }

    // Cast to uint before modulus: Math.Abs(int.MinValue) overflows and stays negative,
    // making % return a negative index. uint modulus is always non-negative.
    internal static int HueIndex(string nick)
    {
        int hash = 0;
        foreach (char c in nick.ToLowerInvariant())
            hash = hash * 31 + c;
        return (int)((uint)hash % (uint)Hues.Length);
    }
}
