using Freeq.WinUI.Models;
using Freeq.WinUI.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Freeq.WinUI.Controls;

public sealed partial class MessageList : UserControl
{
    private MainViewModel? _vm;
    private static string _serverUrl = "https://irc.freeq.at/irc";
    private static bool _autoLoadExternalMedia = true;
    private static MessageDensity _messageDensity = MessageDensity.Default;

    public MessageList()
    {
        InitializeComponent();
    }

    public void Bind(MainViewModel vm)
    {
        _vm = vm;
        _serverUrl = vm.ServerUrl;
        _autoLoadExternalMedia = vm.AutoLoadExternalMedia;
        _messageDensity = vm.MessageDensity;
        MessagesListView.ItemsSource = vm.Messages;

        vm.Messages.CollectionChanged += (s, e) =>
        {
            EmptyState.Visibility = vm.Messages.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

            // Auto-scroll to bottom
            if (vm.Messages.Count > 0)
                MessagesListView.ScrollIntoView(vm.Messages[^1]);
        };

        vm.PropertyChanged += (s, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.SelectedChannel))
            {
                EmptyState.Visibility = vm.Messages.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
                EmptyChannelName.Text = vm.SelectedChannel?.DisplayName ?? "";
            }
            else if (e.PropertyName == nameof(MainViewModel.ServerUrl))
            {
                _serverUrl = vm.ServerUrl;
            }
            else if (e.PropertyName == nameof(MainViewModel.AutoLoadExternalMedia))
            {
                _autoLoadExternalMedia = vm.AutoLoadExternalMedia;
            }
            else if (e.PropertyName == nameof(MainViewModel.MessageDensity))
            {
                _messageDensity = vm.MessageDensity;
            }
        };
    }

    // -----------------------------------------------------------------------
    // Context menu (right-click on a message)
    // -----------------------------------------------------------------------

    private void OnMessageRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (_vm == null) return;

        var msg = FindMessageModel(e.OriginalSource as DependencyObject);
        if (msg == null) return;

        var flyout = new MenuFlyout();

        // Copy text
        var copyItem = new MenuFlyoutItem { Text = "Copy", Icon = new FontIcon { Glyph = "\uE8C8" } };
        copyItem.Click += (_, _) =>
        {
            var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
            dp.SetText(msg.Content);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
            _vm.ShowToast("Message copied");
        };
        flyout.Items.Add(copyItem);

        var copyIdItem = new MenuFlyoutItem { Text = "Copy message ID", Icon = new FontIcon { Glyph = "\uE943" } };
        copyIdItem.Click += (_, _) =>
        {
            var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
            dp.SetText(msg.Id);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
            _vm.ShowToast("Message ID copied");
        };
        flyout.Items.Add(copyIdItem);

        var reactMenu = new MenuFlyoutSubItem { Text = "React" };
        foreach (var emoji in new[] { "👍", "❤️", "🔥", "😂", "👀", "✅" })
        {
            var reactItem = new MenuFlyoutItem { Text = emoji };
            reactItem.Click += (_, _) => _vm.ReactToMessage(msg, emoji);
            reactMenu.Items.Add(reactItem);
        }
        flyout.Items.Add(reactMenu);

        var bookmarkItem = new MenuFlyoutItem { Text = "Bookmark", Icon = new FontIcon { Glyph = "\uE734" } };
        bookmarkItem.Click += (_, _) => _vm.AddBookmark(msg);
        flyout.Items.Add(bookmarkItem);

        var shareItem = new MenuFlyoutItem { Text = "Share to Bluesky", Icon = new FontIcon { Glyph = "\uE72D" } };
        shareItem.Click += async (_, _) =>
        {
            var text = Uri.EscapeDataString($"{msg.Nick}: {msg.Content}");
            var uri = new Uri($"https://bsky.app/intent/compose?text={text}");
            await Launcher.LaunchUriAsync(uri);
            _vm.ShowToast("Opened Bluesky share");
        };
        flyout.Items.Add(shareItem);

        // Edit (only own messages, not deleted)
        if (msg.Nick.Equals(_vm.Nickname, StringComparison.OrdinalIgnoreCase) && !msg.IsDeleted)
        {
            flyout.Items.Add(new MenuFlyoutSeparator());
            var editItem = new MenuFlyoutItem { Text = "Edit", Icon = new FontIcon { Glyph = "\uE70F" } };
            editItem.Click += (_, _) => _vm.BeginEditMessage(msg);
            flyout.Items.Add(editItem);
        }

        // Delete (own messages, not already deleted)
        if (msg.Nick.Equals(_vm.Nickname, StringComparison.OrdinalIgnoreCase) && !msg.IsDeleted)
        {
            var deleteItem = new MenuFlyoutItem
            {
                Text = "Delete",
                Icon = new FontIcon { Glyph = "\uE74D" },
                Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0xFF, 0x55, 0x55))
            };
            deleteItem.Click += (_, _) => _vm.DeleteMessage(msg);
            flyout.Items.Add(deleteItem);
        }

        flyout.ShowAt(MessagesListView, e.GetPosition(MessagesListView));
        e.Handled = true;
    }

    /// <summary>
    /// Walk up the visual tree from <paramref name="element"/> to find the first
    /// FrameworkElement whose Tag is a MessageModel (set via Tag="{x:Bind}" in the DataTemplate).
    /// </summary>
    private static MessageModel? FindMessageModel(DependencyObject? element)
    {
        while (element != null)
        {
            if (element is FrameworkElement fe && fe.Tag is MessageModel msg)
                return msg;
            element = VisualTreeHelper.GetParent(element);
        }
        return null;
    }

    private async void OnUserTapped(object sender, TappedRoutedEventArgs e)
    {
        if (_vm == null) return;
        var msg = FindMessageModel(sender as DependencyObject ?? e.OriginalSource as DependencyObject);
        if (msg == null) return;

        var profile = _vm.GetUserProfile(msg.Nick);
        var panel = new StackPanel { Spacing = 6, MinWidth = 220 };
        panel.Children.Add(new TextBlock { Text = profile.Nick, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, FontSize = 14 });
        panel.Children.Add(new TextBlock { Text = $"DID: {profile.DisplayDid}", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = $"Bluesky: {profile.DisplayHandle}", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = $"Safety number: {_vm.GetSafetyNumber(profile.Nick)}", TextWrapping = TextWrapping.Wrap });

        var openBtn = new Button
        {
            Content = "Open on Bluesky",
            HorizontalAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(8, 4, 8, 4),
        };
        openBtn.Click += async (_, _) =>
        {
            var id = string.IsNullOrWhiteSpace(profile.BlueskyHandle) ? profile.Did : profile.BlueskyHandle;
            if (!string.IsNullOrWhiteSpace(id))
                await Launcher.LaunchUriAsync(new Uri($"https://bsky.app/profile/{id}"));
        };
        panel.Children.Add(openBtn);

        if (profile.CanModerate)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var opBtn = new Button { Content = "Op", Padding = new Thickness(8, 2, 8, 2) };
            var deopBtn = new Button { Content = "Deop", Padding = new Thickness(8, 2, 8, 2) };
            var voiceBtn = new Button { Content = "Voice", Padding = new Thickness(8, 2, 8, 2) };
            var devoBtn = new Button { Content = "Devoice", Padding = new Thickness(8, 2, 8, 2) };
            opBtn.Click += (_, _) => _vm.SetMemberOperator(profile.Nick, true);
            deopBtn.Click += (_, _) => _vm.SetMemberOperator(profile.Nick, false);
            voiceBtn.Click += (_, _) => _vm.SetMemberVoice(profile.Nick, true);
            devoBtn.Click += (_, _) => _vm.SetMemberVoice(profile.Nick, false);
            actions.Children.Add(opBtn);
            actions.Children.Add(deopBtn);
            actions.Children.Add(voiceBtn);
            actions.Children.Add(devoBtn);
            panel.Children.Add(actions);
        }

        var dialog = new ContentDialog
        {
            Title = "User Profile",
            PrimaryButtonText = "Close",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
            Content = panel,
        };
        await dialog.ShowAsync();
        e.Handled = true;
    }

    private void OnReactionTapped(object sender, TappedRoutedEventArgs e)
    {
        if (_vm == null) return;
        if (sender is not FrameworkElement fe || fe.Tag is not ReactionSummary rs) return;
        var msg = FindMessageModel(fe);
        if (msg == null) return;
        _vm.ReactToMessage(msg, rs.Emoji);
        e.Handled = true;
    }

    // -----------------------------------------------------------------------
    // Static helpers for x:Bind
    // -----------------------------------------------------------------------

    public static Visibility BoolToVis(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility BoolToVisInverse(bool value) =>
        value ? Visibility.Collapsed : Visibility.Visible;

    public static string GetServerUrl() => _serverUrl;

    public static bool GetAutoLoadExternalMedia() => _autoLoadExternalMedia;

    public static Visibility GetAvatarVisibility() =>
        _messageDensity == MessageDensity.Compact ? Visibility.Collapsed : Visibility.Visible;

    public static Thickness GetMessagePadding() => _messageDensity switch
    {
        MessageDensity.Cozy => new Thickness(16, 10, 16, 10),
        MessageDensity.Compact => new Thickness(10, 2, 10, 2),
        _ => new Thickness(16, 6, 16, 6),
    };
}
