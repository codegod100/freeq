using Freeq.WinUI.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace Freeq.WinUI.Controls;

public sealed partial class MemberList : UserControl
{
    private MainViewModel? _vm;

    public MemberList()
    {
        InitializeComponent();
    }

    public void Bind(MainViewModel vm)
    {
        _vm = vm;
        OpsList.ItemsSource = vm.Operators;
        VoicedList.ItemsSource = vm.Voiced;
        MembersList.ItemsSource = vm.Members;

        vm.Operators.CollectionChanged += (s, e) =>
        {
            OpsSection.Visibility = vm.Operators.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            OpsHeader.Text = $"OPERATORS — {vm.Operators.Count}";
        };

        vm.Voiced.CollectionChanged += (s, e) =>
        {
            VoicedSection.Visibility = vm.Voiced.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            VoicedHeader.Text = $"VOICED — {vm.Voiced.Count}";
        };

        vm.Members.CollectionChanged += (s, e) =>
        {
            MembersHeader.Text = $"MEMBERS — {vm.Members.Count}";
        };
    }

    private async void OnMemberClick(object sender, ItemClickEventArgs e)
    {
        if (_vm == null || e.ClickedItem is not Models.MemberModel member) return;

        var profile = _vm.GetUserProfile(member.Nick);
        var panel = new StackPanel { Spacing = 6, MinWidth = 220 };
        panel.Children.Add(new TextBlock { Text = profile.Nick, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, FontSize = 14 });
        panel.Children.Add(new TextBlock { Text = $"DID: {profile.DisplayDid}", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = $"Bluesky: {profile.DisplayHandle}", TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = $"Safety number: {_vm.GetSafetyNumber(profile.Nick)}", TextWrapping = TextWrapping.Wrap });

        var openBtn = new Button { Content = "Open on Bluesky", HorizontalAlignment = HorizontalAlignment.Left };
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
            var opBtn = new Button { Content = "Op" };
            var deopBtn = new Button { Content = "Deop" };
            var voiceBtn = new Button { Content = "Voice" };
            var devoBtn = new Button { Content = "Devoice" };
            opBtn.Click += (_, _) => _vm.SetMemberOperator(member.Nick, true);
            deopBtn.Click += (_, _) => _vm.SetMemberOperator(member.Nick, false);
            voiceBtn.Click += (_, _) => _vm.SetMemberVoice(member.Nick, true);
            devoBtn.Click += (_, _) => _vm.SetMemberVoice(member.Nick, false);
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
            XamlRoot = this.XamlRoot,
            Content = panel,
        };

        await dialog.ShowAsync();
    }

    public static Visibility BoolToVis(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility AwayToVisibility(Models.PresenceStatus status) =>
        status == Models.PresenceStatus.Away ? Visibility.Visible : Visibility.Collapsed;
}
