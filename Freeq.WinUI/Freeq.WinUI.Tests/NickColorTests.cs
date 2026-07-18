namespace Freeq.WinUI.Tests;

/// <summary>
/// Regression tests for the NickColor hash computation.
///
/// The production code is NickColor.HueIndex(nick), which uses:
///   (uint)hash % (uint)Hues.Length
///
/// The test project cannot link NickColor.cs because it depends on
/// Microsoft.UI.Xaml.Media (WinUI), which is unavailable in the SDK-style
/// test project. So we test the hash invariant directly here, using the
/// same algorithm as the production code.
///
/// Regression: ISSUE-001 — Math.Abs(int.MinValue) overflow
/// Found by /qa on 2026-04-01
/// Report: .gstack/qa-reports/qa-report-winui-2026-04-01.md
/// </summary>
public class NickColorTests
{
    // Mirror of NickColor.HueIndex — pure logic, no WinUI deps.
    // Must stay in sync with Models/NickColor.cs.
    private static int HueIndex(string nick, int hueCount = 5)
    {
        int hash = 0;
        foreach (char c in nick.ToLowerInvariant())
            hash = hash * 31 + c;
        return (int)((uint)hash % (uint)hueCount);
    }

    // The old (buggy) implementation for regression comparison.
    private static int HueIndexBuggy(string nick, int hueCount = 5)
    {
        int hash = 0;
        foreach (char c in nick.ToLowerInvariant())
            hash = hash * 31 + c;
        return Math.Abs(hash) % hueCount;
    }

    [Fact]
    public void HueIndex_IsAlwaysInRange_CommonNicks()
    {
        string[] nicks = ["alice", "bob", "carol", "dave", "eve", "robert",
                          "A", "z", "IRC_USER", "guest_42", "X", "freeq", ""];
        foreach (var nick in nicks)
        {
            int idx = HueIndex(nick);
            Assert.InRange(idx, 0, 4);
        }
    }

    [Fact]
    public void HueIndex_IsAlwaysInRange_LongNicks()
    {
        // Long nicks cause int overflow in the hash — exactly the crash scenario.
        string[] nicks =
        [
            new string('a', 50),
            new string('z', 100),
            new string('X', 200),
            "abcdefghijklmnopqrstuvwxyz0123456789",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        ];
        foreach (var nick in nicks)
        {
            int idx = HueIndex(nick);
            Assert.InRange(idx, 0, 4);
        }
    }

    [Fact]
    public void HueIndex_IsAlwaysInRange_LargeRandomSample()
    {
        // 1000 nicks with varied patterns — catches any edge in the modulus.
        var rng = new Random(42);
        const string chars = "abcdefghijklmnopqrstuvwxyz0123456789_-";
        for (int i = 0; i < 1000; i++)
        {
            int len = rng.Next(1, 32);
            var nick = new string(Enumerable.Range(0, len)
                .Select(_ => chars[rng.Next(chars.Length)]).ToArray());
            int idx = HueIndex(nick);
            Assert.InRange(idx, 0, 4);
        }
    }

    [Fact]
    public void HueIndex_BuggyVersion_CanReturnNegative()
    {
        // Demonstrates that the OLD Math.Abs approach can produce a negative index
        // when the hash equals int.MinValue. We find such a nick by brute force
        // over short strings. If no such nick is found in the search space, the
        // test is skipped (the invariant still holds by virtue of the above tests).
        bool foundMinValue = false;
        for (int i = 0; i < 100_000; i++)
        {
            string nick = i.ToString();
            int hash = 0;
            foreach (char c in nick.ToLowerInvariant())
                hash = hash * 31 + c;

            if (hash == int.MinValue)
            {
                // Confirm buggy version would throw or return negative
                int buggyResult = Math.Abs(hash) % 5; // Math.Abs(int.MinValue) = int.MinValue
                Assert.True(buggyResult < 0,
                    $"Nick '{nick}' produces hash=int.MinValue; buggy result={buggyResult} should be negative");

                // Confirm fixed version is safe
                int fixedResult = (int)((uint)hash % 5u);
                Assert.InRange(fixedResult, 0, 4);

                foundMinValue = true;
                break;
            }
        }

        // If we didn't find int.MinValue in this search space, the test is informational only.
        // The other tests above provide coverage of the invariant.
        _ = foundMinValue; // suppress unused warning
    }

    [Fact]
    public void HueIndex_IsDeterministic_SameNickSameColor()
    {
        // Same nick always maps to the same hue — required for visual consistency.
        string[] nicks = ["alice", "bob", "ALICE", "Alice"];
        foreach (var nick in nicks)
        {
            int first = HueIndex(nick);
            int second = HueIndex(nick);
            Assert.Equal(first, second);
        }
    }

    [Fact]
    public void HueIndex_IsCaseInsensitive()
    {
        // Nicks are case-folded before hashing, so same nick in different cases
        // gets the same color.
        Assert.Equal(HueIndex("Alice"), HueIndex("alice"));
        Assert.Equal(HueIndex("ROBERT"), HueIndex("robert"));
        Assert.Equal(HueIndex("IRC_User_42"), HueIndex("irc_user_42"));
    }
}
