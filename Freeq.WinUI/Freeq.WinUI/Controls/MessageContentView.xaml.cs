using Freeq.WinUI.Models;
using Freeq.WinUI.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Text.RegularExpressions;
using System.Linq;
using Windows.Media.Core;
using Windows.System;

namespace Freeq.WinUI.Controls;

public sealed class MessageContentView : UserControl
{
    private static readonly Regex UrlRegex = new(@"https?://\S+", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex BskyRegex = new(@"https?://(?:www\.)?bsky\.app/profile/(?<handle>[^/]+)/post/(?<rkey>[^\s/?#]+)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex CoordinationRegex = new(@"^\[(?<kind>TASK|DECISION|EVENT)\]\s*(?<title>.+)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private readonly StackPanel _root = new() { Spacing = 6 };

    public MessageContentView()
    {
        Content = _root;
        Loaded += (_, _) => Render();
    }

    public MessageModel? Message
    {
        get => (MessageModel?)GetValue(MessageProperty);
        set => SetValue(MessageProperty, value);
    }

    public static readonly DependencyProperty MessageProperty =
        DependencyProperty.Register(nameof(Message), typeof(MessageModel), typeof(MessageContentView),
            new PropertyMetadata(null, (d, _) => ((MessageContentView)d).Render()));

    public bool AutoLoadExternalMedia
    {
        get => (bool)GetValue(AutoLoadExternalMediaProperty);
        set => SetValue(AutoLoadExternalMediaProperty, value);
    }

    public static readonly DependencyProperty AutoLoadExternalMediaProperty =
        DependencyProperty.Register(nameof(AutoLoadExternalMedia), typeof(bool), typeof(MessageContentView),
            new PropertyMetadata(true, (d, _) => ((MessageContentView)d).Render()));

    public string ServerUrl
    {
        get => (string)GetValue(ServerUrlProperty);
        set => SetValue(ServerUrlProperty, value);
    }

    public static readonly DependencyProperty ServerUrlProperty =
        DependencyProperty.Register(nameof(ServerUrl), typeof(string), typeof(MessageContentView),
            new PropertyMetadata("https://irc.freeq.at/irc", (d, _) => ((MessageContentView)d).Render()));

    private void Render()
    {
        _root.Children.Clear();
        if (Message == null) return;

        var coordinationCard = BuildCoordinationCard(Message.Content);
        if (coordinationCard != null)
            _root.Children.Add(coordinationCard);

        _root.Children.Add(BuildMarkdownBlock(Message.Content));

        if (!AutoLoadExternalMedia) return;

        var urls = UrlRegex.Matches(Message.Content).Select(m => m.Value.TrimEnd('.', ',', ';', ')')).Distinct().Take(3).ToList();
        foreach (var url in urls)
        {
            if (IsImage(url))
                _root.Children.Add(BuildImagePreview(url));
            else if (IsAudio(url) || IsVideo(url))
                _root.Children.Add(BuildMediaPlayer(url));
            else if (BskyRegex.IsMatch(url))
                _ = AddBlueskyCardAsync(url);
            else
                _ = AddOpenGraphPreviewAsync(url);
        }
    }

    private RichTextBlock BuildMarkdownBlock(string text)
    {
        var rtb = new RichTextBlock
        {
            IsTextSelectionEnabled = true,
            Foreground = (Brush)Application.Current.Resources["FgBrush"],
            FontSize = (double)Application.Current.Resources["BodyFontSize"],
            TextWrapping = TextWrapping.Wrap,
        };

        var p = new Paragraph();
        foreach (var inline in ParseMarkdown(text))
            p.Inlines.Add(inline);
        rtb.Blocks.Add(p);
        return rtb;
    }

    private IEnumerable<Inline> ParseMarkdown(string input)
    {
        var text = input.Replace("\\n", "\n");

        var codeBlockMatch = Regex.Match(text, @"```(?<code>[\s\S]*?)```", RegexOptions.Multiline);
        if (codeBlockMatch.Success)
        {
            var before = text[..codeBlockMatch.Index];
            var code = codeBlockMatch.Groups["code"].Value;
            var after = text[(codeBlockMatch.Index + codeBlockMatch.Length)..];
            foreach (var i in ParseInline(before)) yield return i;
            yield return new LineBreak();
            yield return new Run { Text = code.Trim(), FontFamily = new FontFamily("Cascadia Code"), Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0xC5, 0xD3, 0xE0)) };
            yield return new LineBreak();
            foreach (var i in ParseInline(after)) yield return i;
            yield break;
        }

        foreach (var i in ParseInline(text)) yield return i;
    }

    private IEnumerable<Inline> ParseInline(string text)
    {
        var idx = 0;
        while (idx < text.Length)
        {
            var link = Regex.Match(text[idx..], @"\[(?<label>[^\]]+)\]\((?<url>https?://[^\)]+)\)");
            if (!link.Success)
            {
                foreach (var i in ParseFormattingRuns(text[idx..])) yield return i;
                break;
            }

            if (link.Index > 0)
            {
                foreach (var i in ParseFormattingRuns(text.Substring(idx, link.Index))) yield return i;
            }

            var url = link.Groups["url"].Value;
            var label = link.Groups["label"].Value;
            var h = new Hyperlink();
            h.Inlines.Add(new Run { Text = label });
            h.Click += async (_, _) => await Launcher.LaunchUriAsync(new Uri(url));
            yield return h;

            idx += link.Index + link.Length;
        }
    }

    private static IEnumerable<Inline> ParseFormattingRuns(string s)
    {
        var i = 0;
        while (i < s.Length)
        {
            if (TryWrap(s, i, "**", out var boldText, out var nextBold))
            {
                yield return new Bold { Inlines = { new Run { Text = boldText } } };
                i = nextBold;
                continue;
            }
            if (TryWrap(s, i, "*", out var italicText, out var nextItalic))
            {
                yield return new Italic { Inlines = { new Run { Text = italicText } } };
                i = nextItalic;
                continue;
            }
            if (TryWrap(s, i, "~~", out var strikeText, out var nextStrike))
            {
                // WinUI RichTextBlock has no per-run strikethrough property; preserve content plainly.
                yield return new Run { Text = strikeText };
                i = nextStrike;
                continue;
            }
            if (TryWrap(s, i, "`", out var codeText, out var nextCode))
            {
                yield return new Run { Text = codeText, FontFamily = new FontFamily("Cascadia Code") };
                i = nextCode;
                continue;
            }

            var nextSpecial = FindNextSpecial(s, i);
            var chunk = nextSpecial < 0 ? s[i..] : s[i..nextSpecial];
            var lines = chunk.Split('\n');
            for (var li = 0; li < lines.Length; li++)
            {
                var part = lines[li];
                if (part.Length > 0) yield return new Run { Text = part };
                if (li < lines.Length - 1) yield return new LineBreak();
            }

            if (nextSpecial < 0) break;
            i = nextSpecial;
        }
    }

    private static int FindNextSpecial(string s, int start)
    {
        var markers = new[] { "**", "*", "~~", "`" };
        var min = -1;
        foreach (var m in markers)
        {
            var at = s.IndexOf(m, start, StringComparison.Ordinal);
            if (at >= 0 && (min < 0 || at < min)) min = at;
        }
        return min;
    }

    private static bool TryWrap(string s, int start, string marker, out string inner, out int next)
    {
        inner = string.Empty;
        next = start;
        if (!s.AsSpan(start).StartsWith(marker.AsSpan(), StringComparison.Ordinal)) return false;
        var end = s.IndexOf(marker, start + marker.Length, StringComparison.Ordinal);
        if (end < 0) return false;
        inner = s.Substring(start + marker.Length, end - (start + marker.Length));
        next = end + marker.Length;
        return true;
    }

    private UIElement BuildImagePreview(string url)
    {
        var img = new Image
        {
            Source = new BitmapImage(new Uri(url)),
            MaxHeight = 260,
            Stretch = Stretch.UniformToFill,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        img.Tapped += async (_, _) => await ShowImageLightboxAsync(url);

        return new Border
        {
            BorderBrush = (Brush)Application.Current.Resources["BorderBrush"],
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)Application.Current.Resources["MediumRadius"],
            Child = img,
            MaxWidth = 420,
        };
    }

    private async Task ShowImageLightboxAsync(string url)
    {
        var slider = new Slider { Minimum = 0.5, Maximum = 3.0, Value = 1.0, Width = 260 };
        var image = new Image
        {
            Source = new BitmapImage(new Uri(url)),
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Width = 900,
        };

        slider.ValueChanged += (_, e) =>
        {
            image.Width = 900 * e.NewValue;
        };

        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(slider);
        panel.Children.Add(new ScrollViewer { Content = image, Height = 520 });

        var dialog = new ContentDialog
        {
            Title = "Image",
            PrimaryButtonText = "Close",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
            Content = panel,
        };

        await dialog.ShowAsync();
    }

    private UIElement BuildMediaPlayer(string url)
    {
        var mpe = new MediaPlayerElement
        {
            Source = MediaSource.CreateFromUri(new Uri(url)),
            AreTransportControlsEnabled = true,
            AutoPlay = false,
            Width = 420,
            Height = IsVideo(url) ? 240 : 84,
        };
        return mpe;
    }

    private async Task AddOpenGraphPreviewAsync(string url)
    {
        var og = await OpenGraphService.FetchAsync(ServerUrl, url);
        if (og == null) return;

        await DispatcherQueue.EnqueueAsync(() =>
        {
            var panel = new StackPanel { Spacing = 2 };
            panel.Children.Add(new TextBlock
            {
                Text = og.Title ?? og.Url,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = (Brush)Application.Current.Resources["AccentBrush"],
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            if (!string.IsNullOrWhiteSpace(og.Description))
            {
                panel.Children.Add(new TextBlock
                {
                    Text = og.Description,
                    FontSize = 11,
                    Foreground = (Brush)Application.Current.Resources["FgMutedBrush"],
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 2,
                });
            }

            var b = new Border
            {
                BorderBrush = (Brush)Application.Current.Resources["BorderBrush"],
                BorderThickness = new Thickness(1),
                CornerRadius = (CornerRadius)Application.Current.Resources["MediumRadius"],
                Background = (Brush)Application.Current.Resources["BgTertiaryBrush"],
                Padding = new Thickness(10, 8, 10, 8),
                MaxWidth = 420,
                Child = panel,
            };
            b.Tapped += async (_, _) => await Launcher.LaunchUriAsync(new Uri(url));
            _root.Children.Add(b);
        });
    }

    private async Task AddBlueskyCardAsync(string url)
    {
        var m = BskyRegex.Match(url);
        if (!m.Success) return;

        var handle = m.Groups["handle"].Value;
        var rkey = m.Groups["rkey"].Value;
        var uri = $"https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri={Uri.EscapeDataString($"at://{handle}/app.bsky.feed.post/{rkey}")}&depth=0";

        using var client = new HttpClient();
        var resp = await client.GetAsync(uri);
        if (!resp.IsSuccessStatusCode) return;
        var json = await resp.Content.ReadAsStringAsync();

        using var doc = System.Text.Json.JsonDocument.Parse(json);
        var post = doc.RootElement.TryGetProperty("thread", out var th)
            && th.TryGetProperty("post", out var p) ? p : default;
        if (post.ValueKind == System.Text.Json.JsonValueKind.Undefined) return;

        var text = post.TryGetProperty("record", out var rec) && rec.TryGetProperty("text", out var txt) ? txt.GetString() : "";
        var author = post.TryGetProperty("author", out var a) && a.TryGetProperty("handle", out var h) ? h.GetString() : handle;

        await DispatcherQueue.EnqueueAsync(() =>
        {
            var card = new Border
            {
                BorderBrush = (Brush)Application.Current.Resources["BorderBrush"],
                BorderThickness = new Thickness(1),
                CornerRadius = (CornerRadius)Application.Current.Resources["LargeRadius"],
                Background = (Brush)Application.Current.Resources["BgTertiaryBrush"],
                Padding = new Thickness(10, 8, 10, 8),
                MaxWidth = 420,
                Child = new StackPanel
                {
                    Spacing = 4,
                    Children =
                    {
                        new TextBlock { Text = $"@{author}", FontSize = 11, Foreground = (Brush)Application.Current.Resources["FgDimBrush"] },
                        new TextBlock { Text = text ?? string.Empty, TextWrapping = TextWrapping.Wrap },
                    }
                }
            };
            card.Tapped += async (_, _) => await Launcher.LaunchUriAsync(new Uri(url));
            _root.Children.Add(card);
        });
    }

    private static bool IsImage(string url) => Regex.IsMatch(url, @"\.(png|jpe?g|gif|webp)(\?|$)", RegexOptions.IgnoreCase);
    private static bool IsAudio(string url) => Regex.IsMatch(url, @"\.(mp3|ogg|wav|m4a)(\?|$)", RegexOptions.IgnoreCase);
    private static bool IsVideo(string url) => Regex.IsMatch(url, @"\.(mp4|webm|mov|m4v)(\?|$)", RegexOptions.IgnoreCase);

    private static UIElement? BuildCoordinationCard(string text)
    {
        var lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (lines.Length == 0) return null;

        var header = CoordinationRegex.Match(lines[0]);
        if (!header.Success) return null;

        var kind = header.Groups["kind"].Value.ToUpperInvariant();
        var title = header.Groups["title"].Value;
        var bodyLines = lines.Skip(1).Take(4).ToList();

        var panel = new StackPanel { Spacing = 3 };
        panel.Children.Add(new TextBlock
        {
            Text = kind switch
            {
                "TASK" => "Task",
                "DECISION" => "Decision",
                _ => "Coordination event",
            },
            FontSize = 11,
            Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0x7A, 0xA2, 0xFF)),
        });
        panel.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });

        foreach (var line in bodyLines)
        {
            panel.Children.Add(new TextBlock
            {
                Text = line,
                FontSize = 12,
                Foreground = (Brush)Application.Current.Resources["FgDimBrush"],
                TextWrapping = TextWrapping.Wrap,
            });
        }

        return new Border
        {
            Background = (Brush)Application.Current.Resources["BgTertiaryBrush"],
            BorderBrush = (Brush)Application.Current.Resources["BorderBrush"],
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)Application.Current.Resources["MediumRadius"],
            Padding = new Thickness(10, 8, 10, 8),
            MaxWidth = 460,
            Child = panel,
        };
    }
}

internal static class DispatcherQueueExtensions
{
    public static Task EnqueueAsync(this Microsoft.UI.Dispatching.DispatcherQueue queue, Action action)
    {
        var tcs = new TaskCompletionSource();
        queue.TryEnqueue(() =>
        {
            try
            {
                action();
                tcs.SetResult();
            }
            catch (Exception ex)
            {
                tcs.SetException(ex);
            }
        });
        return tcs.Task;
    }
}
