using System.Globalization;

namespace PhoneCast;

/// English and German: PhoneCast follows Windows' display language (PHONECAST_LANG=de/en overrides).
/// The German texts are in L10n.De.cs; a missing entry falls back to English.
static partial class L10n
{
    public static readonly bool German = (Environment.GetEnvironmentVariable("PHONECAST_LANG") ?? CultureInfo.CurrentUICulture.TwoLetterISOLanguageName) == "de";

    public static string tr(string s) => s != null && German && De.TryGetValue(s, out var d) ? d : s;

    public static string tr(string s, params object[] args)
    {
        try { return string.Format(tr(s), args); } catch { return s; }
    }
}
