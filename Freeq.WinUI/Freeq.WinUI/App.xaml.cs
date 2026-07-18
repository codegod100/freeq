using Microsoft.UI.Xaml;
using Freeq.WinUI.Models;

namespace Freeq.WinUI;

public partial class App : Application
{
    private Window? _window;
    public static Window? MainWindowInstance { get; private set; }

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        MainWindowInstance = _window;
        _window.Activate();
    }

    public static void SetColorTheme(ThemeMode mode)
    {
        if (Current?.Resources is not ResourceDictionary resources) return;
        var merged = resources.MergedDictionaries;
        if (merged.Count == 0) return;

        var themeSource = mode switch
        {
            ThemeMode.Light => new Uri("ms-appx:///Themes/Colors.Light.xaml"),
            _ => new Uri("ms-appx:///Themes/Colors.xaml"),
        };

        for (int i = 0; i < merged.Count; i++)
        {
            var src = merged[i].Source?.OriginalString ?? string.Empty;
            if (src.Contains("Themes/Colors", StringComparison.OrdinalIgnoreCase))
            {
                merged[i] = new ResourceDictionary { Source = themeSource };
                return;
            }
        }

        merged.Add(new ResourceDictionary { Source = themeSource });
    }
}
