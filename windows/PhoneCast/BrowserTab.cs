using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace PhoneCast;

/// "Browser tab to the phone": the address of the page open in the front-most browser window (Chrome, Edge,
/// Brave, Vivaldi, Opera, Firefox), read from its address bar with UI Automation (nothing is typed or clicked).
static class BrowserTab
{
    static readonly string[] Browsers = { "chrome", "msedge", "brave", "vivaldi", "opera", "firefox", "arc" };

    public static string Current()
    {
        try
        {
            // the browser window nearest the top of the window stack
            for (var h = GetTopWindow(IntPtr.Zero); h != IntPtr.Zero; h = GetWindow(h, 2 /* GW_HWNDNEXT */))
            {
                if (!IsWindowVisible(h) || IsIconic(h)) continue;
                GetWindowThreadProcessId(h, out var pid);
                string name;
                try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant(); } catch { continue; }
                if (!Browsers.Contains(name)) continue;
                var url = AddressOf(h, name);
                if (url != null) return url;
            }
        }
        catch (Exception e) { App.Log("browser tab: " + e.Message); }
        return null;
    }

    static string AddressOf(IntPtr hwnd, string browser)
    {
        var win = AutomationElement.FromHandle(hwnd);
        if (win == null) return null;
        // the address bar is an edit field; Chromium names it "Address and search bar", Firefox "Search or enter address"
        var edits = win.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
        foreach (AutomationElement e in edits)
        {
            if (!e.TryGetCurrentPattern(ValuePattern.Pattern, out var vp)) continue;
            var v = ((ValuePattern)vp).Current.Value?.Trim();
            if (string.IsNullOrEmpty(v) || v.Contains(' ')) continue;
            if (e.Current.HasKeyboardFocus) continue;   // being typed in: not the page
            if (!v.Contains("://")) v = "https://" + v;
            if (Uri.TryCreate(v, UriKind.Absolute, out var u) && (u.Scheme == "http" || u.Scheme == "https") && u.Host.Contains('.'))
                return u.AbsoluteUri;
        }
        return null;
    }

    [DllImport("user32")] static extern IntPtr GetTopWindow(IntPtr h);
    [DllImport("user32")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
