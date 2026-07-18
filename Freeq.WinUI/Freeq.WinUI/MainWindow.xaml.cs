using System.Linq;
using Freeq.WinUI.Controls;
using Freeq.WinUI.Models;
using Freeq.WinUI.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;
using Windows.System;

namespace Freeq.WinUI;

public sealed partial class MainWindow : Window
{
    private readonly MainViewModel _vm;
    private DispatcherTimer? _toastTimer;

    public MainWindow()
    {
        InitializeComponent();

        Title = "Freeq";
        _vm = new MainViewModel(DispatcherQueue);

        SidebarControl.Bind(_vm);
        TopBarControl.Bind(_vm);
        MessageListControl.Bind(_vm);
        ComposeBoxControl.Bind(_vm);
        MemberListControl.Bind(_vm);

        ConnectDialogControl.ConnectRequested += OnConnectRequested;
        SidebarControl.ChannelSelected += OnChannelSelected;
        SidebarControl.DisconnectRequested += OnDisconnectRequested;
        SidebarControl.JoinRequested += OnJoinRequested;
        SidebarControl.MuteToggleRequested += OnMuteToggleRequested;
        TopBarControl.MemberListToggled += OnMemberListToggled;

        RegisterKeyboardShortcuts();
        Activated += OnWindowActivated;

        _vm.PropertyChanged += (s, e) =>
        {
            if (e.PropertyName == nameof(MainViewModel.ShowConnectDialog))
            {
                ConnectDialogControl.Visibility = _vm.ShowConnectDialog
                    ? Visibility.Visible : Visibility.Collapsed;
                MainLayout.Visibility = _vm.ShowConnectDialog
                    ? Visibility.Collapsed : Visibility.Visible;

                if (_vm.ShowConnectDialog)
                    ConnectDialogControl.SetConnecting(false);
            }
            else if (e.PropertyName == nameof(MainViewModel.IsMemberListVisible))
            {
                MemberListControl.Visibility = _vm.IsMemberListVisible
                    ? Visibility.Visible : Visibility.Collapsed;
            }
            else if (e.PropertyName == nameof(MainViewModel.ErrorMessage) && _vm.ErrorMessage != null)
            {
                ConnectDialogControl.ShowError(_vm.ErrorMessage);
                ConnectDialogControl.SetConnecting(false);
            }
            else if (e.PropertyName == nameof(MainViewModel.ShowReconnectBanner))
            {
                ReconnectBanner.Visibility = _vm.ShowReconnectBanner ? Visibility.Visible : Visibility.Collapsed;
                ReconnectBannerText.Text = _vm.ReconnectBannerText;
            }
            else if (e.PropertyName == nameof(MainViewModel.ReconnectBannerText))
            {
                ReconnectBannerText.Text = _vm.ReconnectBannerText;
            }
            else if (e.PropertyName == nameof(MainViewModel.ShowMotdBanner))
            {
                MotdBanner.Visibility = _vm.ShowMotdBanner ? Visibility.Visible : Visibility.Collapsed;
                MotdBannerText.Text = _vm.MotdText;
            }
            else if (e.PropertyName == nameof(MainViewModel.MotdText))
            {
                MotdBannerText.Text = _vm.MotdText;
            }
            else if (e.PropertyName == nameof(MainViewModel.UnreadMentionCount))
            {
                UpdateMentionBadge();
            }
        };

        _vm.ToastRequested += ShowInAppToast;
        _vm.WindowsToastRequested += ShowWindowsMentionToast;
        _vm.ThemeChanged += ApplyTheme;
        ApplyTheme(_vm.ThemeMode);
    }

    private async void OnConnectRequested(ConnectRequest request)
    {
        _vm.ServerUrl = request.ServerUrl;
        _vm.Nickname = request.Nickname;

        // Set SASL credentials if AT Protocol login
        if (request.IsAtProto && !string.IsNullOrEmpty(request.SaslToken))
        {
            _vm.SetSaslCredentials(
                request.SaslToken,
                request.Did ?? "",
                request.PdsUrl ?? "",
                "web-token"
            );
        }

        // Queue channels BEFORE connecting — they'll be joined when 001 arrives
        if (!string.IsNullOrWhiteSpace(request.Channels))
        {
            var channels = request.Channels.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            _vm.QueueJoinChannels(channels);
        }

        await _vm.ConnectCommand.ExecuteAsync(null);
    }

    private void OnChannelSelected(ChannelModel channel)
    {
        _vm.SelectedChannel = channel;
    }

    private void OnDisconnectRequested()
    {
        _vm.DisconnectCommand.Execute(null);
    }

    private void OnJoinRequested(string channel)
    {
        _vm.JoinChannelCommand.Execute(channel);
    }

    private void OnMemberListToggled()
    {
        _vm.ToggleMemberListCommand.Execute(null);
    }

    private void OnMuteToggleRequested(ChannelModel channel)
    {
        _vm.ToggleMuteCommand.Execute(channel);
    }

    private void RegisterKeyboardShortcuts()
    {
        // In WinUI 3, Window doesn't inherit UIElement, so attach accelerators to Content (the root Grid).
        var root = (UIElement)this.Content;

        // Ctrl+K — quick channel switcher
        var quickSwitch = new KeyboardAccelerator
        {
            Key = VirtualKey.K,
            Modifiers = VirtualKeyModifiers.Control,
        };
        quickSwitch.Invoked += async (_, _) => await ShowQuickSwitcherAsync();
        root.KeyboardAccelerators.Add(quickSwitch);

        // Ctrl+F — search messages
        var search = new KeyboardAccelerator
        {
            Key = VirtualKey.F,
            Modifiers = VirtualKeyModifiers.Control,
        };
        search.Invoked += async (_, _) => await ShowSearchAsync();
        root.KeyboardAccelerators.Add(search);

        var shortcuts = new KeyboardAccelerator
        {
            Key = (VirtualKey)191, // Oem2: '/' on standard keyboards
            Modifiers = VirtualKeyModifiers.Control,
        };
        shortcuts.Invoked += async (_, _) => await ShowShortcutsAsync();
        root.KeyboardAccelerators.Add(shortcuts);

        // Alt+Up — previous channel
        var altUp = new KeyboardAccelerator
        {
            Key = VirtualKey.Up,
            Modifiers = VirtualKeyModifiers.Menu,
        };
        altUp.Invoked += (_, _) => _vm.SelectPreviousChannelCommand.Execute(null);
        root.KeyboardAccelerators.Add(altUp);

        // Alt+Down — next channel
        var altDown = new KeyboardAccelerator
        {
            Key = VirtualKey.Down,
            Modifiers = VirtualKeyModifiers.Menu,
        };
        altDown.Invoked += (_, _) => _vm.SelectNextChannelCommand.Execute(null);
        root.KeyboardAccelerators.Add(altDown);

        // Alt+1…9, Alt+0 — jump to nth channel
        VirtualKey[] digitKeys =
        [
            VirtualKey.Number1, VirtualKey.Number2, VirtualKey.Number3,
            VirtualKey.Number4, VirtualKey.Number5, VirtualKey.Number6,
            VirtualKey.Number7, VirtualKey.Number8, VirtualKey.Number9,
            VirtualKey.Number0,
        ];
        for (int i = 0; i < digitKeys.Length; i++)
        {
            var digit = i + 1; // 1-based; 10 for index 9 (Alt+0)
            if (digit == 10) digit = 0; // Alt+0 → passed as 0
            var accel = new KeyboardAccelerator
            {
                Key = digitKeys[i],
                Modifiers = VirtualKeyModifiers.Menu,
            };
            var captured = digit;
            accel.Invoked += (_, _) => _vm.SelectChannelByIndexCommand.Execute(captured);
            root.KeyboardAccelerators.Add(accel);
        }
    }

    private async System.Threading.Tasks.Task ShowQuickSwitcherAsync()
    {
        if (!_vm.IsConnected) return;

        var searchBox = new TextBox
        {
            PlaceholderText = "Jump to channel or DM…",
            Margin = new Thickness(0, 0, 0, 8),
        };

        var resultList = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 320,
        };

        void Refresh()
        {
            var filter = searchBox.Text;
            var all = _vm.Channels.Concat<ChannelModel>(_vm.DirectMessages);
            resultList.ItemsSource = (string.IsNullOrWhiteSpace(filter)
                ? all
                : all.Where(c => c.Name.Contains(filter, System.StringComparison.OrdinalIgnoreCase)))
                .ToList();

            if (resultList.Items.Count > 0)
                resultList.SelectedIndex = 0;
        }

        searchBox.TextChanged += (_, _) => Refresh();
        Refresh();

        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(searchBox);
        panel.Children.Add(resultList);

        var dialog = new ContentDialog
        {
            Title = "Quick Switch",
            PrimaryButtonText = "Go",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = this.Content.XamlRoot,
            Content = panel,
        };

        // Enter in search box should confirm
        searchBox.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter)
                dialog.Hide(); // triggers Primary path via keyboard
        };

        ChannelModel? selected = null;

        // Enter in search box selects first item and closes dialog as Primary
        searchBox.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter && resultList.Items.Count > 0)
            {
                selected = resultList.SelectedItem as ChannelModel ?? resultList.Items[0] as ChannelModel;
                dialog.Hide();
            }
        };

        resultList.DoubleTapped += (_, _) =>
        {
            selected = resultList.SelectedItem as ChannelModel;
            dialog.Hide();
        };

        var result = await dialog.ShowAsync();
        var target = result == ContentDialogResult.Primary
            ? resultList.SelectedItem as ChannelModel
            : selected;

        if (target != null)
            _vm.SelectedChannel = target;
    }

    private async System.Threading.Tasks.Task ShowSearchAsync()
    {
        if (!_vm.IsConnected) return;

        var searchBox = new TextBox
        {
            PlaceholderText = "Search messages...",
            Margin = new Thickness(0, 0, 0, 8),
        };

        var listView = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            MaxHeight = 360,
            ItemsSource = _vm.SearchResults,
        };

        listView.ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("""
            <DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\">
                <StackPanel Padding=\"4,6\" Spacing=\"2\">
                    <TextBlock Text=\"{Binding Label}\" TextWrapping=\"Wrap\" />
                    <TextBlock Text=\"{Binding TimeLabel}\" Foreground=\"Gray\" FontSize=\"11\" />
                </StackPanel>
            </DataTemplate>
            """);

        searchBox.TextChanged += (_, _) => _vm.SearchMessages(searchBox.Text);

        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(searchBox);
        panel.Children.Add(listView);

        var dialog = new ContentDialog
        {
            Title = "Search Messages",
            PrimaryButtonText = "Jump",
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = this.Content.XamlRoot,
            Content = panel,
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary && listView.SelectedItem is MessageSearchResult selected)
            _vm.JumpToMessage(selected.Channel, selected.MessageId);
    }

    private void OnDismissReconnectBanner(object sender, RoutedEventArgs e)
    {
        _vm.DismissReconnectBanner();
    }

    private void OnDismissMotdBanner(object sender, RoutedEventArgs e)
    {
        _vm.DismissMotdBanner();
    }

    private void ShowInAppToast(string text)
    {
        InAppToastText.Text = text;
        InAppToast.Visibility = Visibility.Visible;

        _toastTimer ??= new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        _toastTimer.Stop();
        _toastTimer.Tick -= OnToastTick;
        _toastTimer.Tick += OnToastTick;
        _toastTimer.Start();
    }

    private void OnToastTick(object? sender, object e)
    {
        if (_toastTimer == null) return;
        _toastTimer.Stop();
        InAppToast.Visibility = Visibility.Collapsed;
    }

    private void OnWindowActivated(object sender, WindowActivatedEventArgs args)
    {
        _vm.SetForeground(args.WindowActivationState != WindowActivationState.Deactivated);
    }

    private void ShowWindowsMentionToast(string text)
    {
        try
        {
            var xml = ToastNotificationManager.GetTemplateContent(ToastTemplateType.ToastText02);
            var nodes = xml.GetElementsByTagName("text");
            nodes[0].AppendChild(xml.CreateTextNode("Freeq mention"));
            nodes[1].AppendChild(xml.CreateTextNode(text));
            var toast = new ToastNotification(xml);
            ToastNotificationManager.CreateToastNotifier("Freeq.WinUI").Show(toast);
        }
        catch
        {
            // Ignore if toast APIs are unavailable in this runtime mode.
        }
    }

    private void UpdateMentionBadge()
    {
        Title = _vm.UnreadMentionCount > 0 ? $"Freeq ({_vm.UnreadMentionCount})" : "Freeq";

        try
        {
            var badgeXml = BadgeUpdateManager.GetTemplateContent(BadgeTemplateType.BadgeNumber);
            var badgeElement = (XmlElement)badgeXml.SelectSingleNode("/badge")!;
            badgeElement.SetAttribute("value", Math.Max(0, _vm.UnreadMentionCount).ToString());
            var notification = new BadgeNotification(badgeXml);
            BadgeUpdateManager.CreateBadgeUpdaterForApplication().Update(notification);
        }
        catch
        {
            // Badges can fail for unpackaged apps; title fallback above is always applied.
        }
    }

    private void ApplyTheme(ThemeMode mode)
    {
        var root = this.Content as FrameworkElement;
        if (root == null) return;

        App.SetColorTheme(mode);

        root.RequestedTheme = mode switch
        {
            ThemeMode.Dark => ElementTheme.Dark,
            ThemeMode.Light => ElementTheme.Light,
            _ => ElementTheme.Default,
        };
    }

    private async Task ShowShortcutsAsync()
    {
        var text = string.Join("\n",
            "Ctrl+K  Quick channel switch",
            "Ctrl+F  Message search",
            "Ctrl+/  Keyboard shortcuts",
            "Alt+1..9, Alt+0  Jump to channel",
            "Alt+Up / Alt+Down  Previous/next channel",
            "Enter  Send message",
            "Shift+Enter  New line",
            "Tab  Nick autocomplete",
            "Esc  Cancel edit/autocomplete");

        var dialog = new ContentDialog
        {
            Title = "Keyboard Shortcuts",
            PrimaryButtonText = "Close",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = this.Content.XamlRoot,
            Content = new TextBlock { Text = text, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Code"), TextWrapping = TextWrapping.Wrap },
        };

        await dialog.ShowAsync();
    }
}
