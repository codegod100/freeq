using System;
using System.Linq;
using Freeq.WinUI.Models;
using Freeq.WinUI.Services;
using Freeq.WinUI.ViewModels;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Freeq.WinUI.Controls;

public sealed partial class Sidebar : UserControl
{
    public MainViewModel? ViewModel { get; set; }

    public event Action<ChannelModel>? ChannelSelected;
    public event Action? DisconnectRequested;
    public event Action<string>? JoinRequested;
    public event Action<ChannelModel>? MuteToggleRequested;

    public Sidebar()
    {
        InitializeComponent();
    }

    public void Bind(MainViewModel vm)
    {
        ViewModel = vm;
        ChannelsList.ItemsSource = vm.Channels;
        FavoritesList.ItemsSource = vm.FavoriteChannels;
        DmsList.ItemsSource = vm.DirectMessages;

        vm.PropertyChanged += (s, e) =>
        {
            switch (e.PropertyName)
            {
                case nameof(MainViewModel.Nickname):
                    UserNick.Text = vm.Nickname;
                    UserInitial.Text = string.IsNullOrEmpty(vm.Nickname) ? "?" : vm.Nickname[..1].ToUpper();
                    break;
                case nameof(MainViewModel.ConnectionState):
                    UpdateStatusDot(vm.ConnectionState);
                    UserStatus.Text = vm.ConnectionStatus;
                    break;
                case nameof(MainViewModel.ConnectionStatus):
                    UserStatus.Text = vm.ConnectionStatus;
                    break;
                case nameof(MainViewModel.IsAway):
                    UpdateAwayButton(vm.IsAway);
                    break;
            }
        };

        vm.FavoriteChannels.CollectionChanged += (s, e) =>
        {
            FavoritesSection.Visibility = vm.FavoriteChannels.Count > 0
                ? Visibility.Visible : Visibility.Collapsed;
        };

        UpdateAwayButton(vm.IsAway);
    }

    private void UpdateAwayButton(bool isAway)
    {
        AwayButton.Foreground = new SolidColorBrush(isAway
            ? ColorHelper.FromArgb(0xFF, 0xFF, 0xB5, 0x47)
            : ColorHelper.FromArgb(0xFF, 0x88, 0x8B, 0x96));
        ToolTipService.SetToolTip(AwayButton, isAway ? "Set Back" : "Set Away");
    }

    private void UpdateStatusDot(ConnectionState state)
    {
        // Stop pulse first; restart only for connecting states
        PulseAnimation.Stop();
        StatusDot.Opacity = 1.0;

        switch (state)
        {
            case ConnectionState.Authenticated:
                // Solid teal — connected and authenticated
                StatusDot.Fill = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0x00, 0xD4, 0xAA));
                break;
            case ConnectionState.Connected or ConnectionState.Connecting or ConnectionState.Authenticating:
                // Warning color + pulse — connecting in progress
                StatusDot.Fill = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0xFF, 0xB5, 0x47));
                PulseAnimation.Begin();
                break;
            default:
                // Dim gray — disconnected
                StatusDot.Fill = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0x55, 0x55, 0x70));
                break;
        }
    }

    private void OnChannelClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ChannelModel channel)
            ChannelSelected?.Invoke(channel);
    }

    private async void OnJoinChannelClick(object sender, RoutedEventArgs e)
    {
        var name = await PromptChannelNameAsync("Join Channel", "#channel-name");
        if (!string.IsNullOrWhiteSpace(name))
            JoinRequested?.Invoke(name);
    }

    private async void OnCreateChannelClick(object sender, RoutedEventArgs e)
    {
        var name = await PromptChannelNameAsync("New Channel", "#my-new-channel");
        if (!string.IsNullOrWhiteSpace(name))
            JoinRequested?.Invoke(name); // JOIN auto-creates on the server
    }

    private async void OnBrowseChannelsClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel == null) return;

        // Kick off LIST immediately so results populate while the dialog is open
        ViewModel.RequestChannelListCommand.Execute(null);

        var listView = new ListView
        {
            ItemsSource = ViewModel.ServerChannels,
            SelectionMode = ListViewSelectionMode.Single,
            Height = 400,
        };
        listView.ItemTemplate = BuildChannelListTemplate();

        var searchBox = new TextBox
        {
            PlaceholderText = "Filter channels…",
            Margin = new Thickness(0, 0, 0, 8),
        };

        // Filter the view on text change (client-side, against already-received entries)
        searchBox.TextChanged += (_, _) =>
        {
            var filter = searchBox.Text;
            listView.ItemsSource = string.IsNullOrWhiteSpace(filter)
                ? ViewModel.ServerChannels
                : ViewModel.ServerChannels
                    .Where(c => c.Name.Contains(filter, StringComparison.OrdinalIgnoreCase)
                             || c.Topic.Contains(filter, StringComparison.OrdinalIgnoreCase))
                    .ToList();
        };

        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(searchBox);
        panel.Children.Add(listView);

        var dialog = new ContentDialog
        {
            Title = "Browse Channels",
            PrimaryButtonText = "Join",
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = this.XamlRoot,
            Content = panel,
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary && listView.SelectedItem is ChannelListEntry entry)
            JoinRequested?.Invoke(entry.Name);
    }

    private void OnChannelRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (e.OriginalSource is FrameworkElement { DataContext: ChannelModel channel })
        {
            var menu = new MenuFlyout();
            var muteItem = new MenuFlyoutItem
            {
                Text = channel.IsMuted ? "Unmute Channel" : "Mute Channel",
            };
            muteItem.Click += (_, _) => MuteToggleRequested?.Invoke(channel);
            menu.Items.Add(muteItem);
            menu.ShowAt((FrameworkElement)sender, e.GetPosition((FrameworkElement)sender));
        }
    }

    private async Task<string?> PromptChannelNameAsync(string title, string placeholder)
    {
        var input = new TextBox
        {
            PlaceholderText = placeholder,
            Background = new SolidColorBrush(ColorHelper.FromArgb(255, 28, 28, 36)),
        };

        var dialog = new ContentDialog
        {
            Title = title,
            PrimaryButtonText = "OK",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = this.XamlRoot,
            Content = input,
        };

        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary ? input.Text : null;
    }

    private static DataTemplate BuildChannelListTemplate()
    {
        // Build a simple DataTemplate in code since this is inside a dynamic dialog
        return (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("""
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                          xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
                <Grid Padding="4,6">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="160" />
                        <ColumnDefinition Width="60" />
                        <ColumnDefinition Width="*" />
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="{Binding Name}" FontWeight="SemiBold"
                               TextTrimming="CharacterEllipsis" VerticalAlignment="Center" />
                    <TextBlock Grid.Column="1" Text="{Binding MemberCount}" Foreground="Gray"
                               VerticalAlignment="Center" HorizontalAlignment="Right" Margin="0,0,12,0" />
                    <TextBlock Grid.Column="2" Text="{Binding Topic}" Foreground="Gray"
                               TextTrimming="CharacterEllipsis" VerticalAlignment="Center" FontSize="12" />
                </Grid>
            </DataTemplate>
            """);
    }

    private void OnDisconnectClick(object sender, RoutedEventArgs e)
    {
        DisconnectRequested?.Invoke();
    }

    private async void OnAwayClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel == null) return;

        if (ViewModel.IsAway)
        {
            ViewModel.ToggleAwayStatus();
            return;
        }

        var input = new TextBox { PlaceholderText = "Away message (optional)", Text = "Away" };
        var dialog = new ContentDialog
        {
            Title = "Set Away",
            PrimaryButtonText = "Set Away",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = this.XamlRoot,
            Content = input,
        };

        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            ViewModel.ToggleAwayStatus(input.Text);
    }

    public static Visibility IntToVisibility(int value)
    {
        return value > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
}
