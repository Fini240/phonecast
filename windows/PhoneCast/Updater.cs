using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http;
using System.Text.Json;
using System.Windows.Forms;

namespace PhoneCast;

/// <summary>Help → Check for updates: newest GitHub release → download the Windows zip → swap the files
/// after this process quits (a small script) → start the new version. Also checks quietly once at start.</summary>
static class Updater
{
    // github.com's own "latest release" link answers with a redirect to /releases/tag/vX: no API call, so no
    // 60-per-hour limit (that limit is per IP and hits shared school/mobile IPs).
    const string Repo = "https://github.com/Fini240/phonecast";
    static string Current => typeof(Updater).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0";

    public static async Task<(string version, string zip, string page)?> Latest()
    {
        using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });
        http.DefaultRequestHeaders.UserAgent.ParseAdd("PhoneCast-Windows");
        http.Timeout = TimeSpan.FromSeconds(15);
        using var r = await http.GetAsync(Repo + "/releases/latest");
        var loc = r.Headers.Location?.ToString() ?? throw new Exception($"GitHub answered {(int)r.StatusCode}");
        var tag = loc.TrimEnd('/').Split('/').Last();
        if (!tag.StartsWith("v")) throw new Exception("no release found");
        return (tag.TrimStart('v', 'V'), $"{Repo}/releases/download/{tag}/PhoneCast-windows-x64.zip", $"{Repo}/releases/tag/{tag}");
    }

    public static bool Newer(string a, string b)
    {
        var x = a.Split('.').Select(s => int.TryParse(s, out var n) ? n : 0).ToArray();
        var y = b.Split('.').Select(s => int.TryParse(s, out var n) ? n : 0).ToArray();
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            int p = i < x.Length ? x[i] : 0, q = i < y.Length ? y[i] : 0;
            if (p != q) return p > q;
        }
        return false;
    }

    /// <summary>quiet = only say something when there is an update.</summary>
    public static async void Check(IWin32Window owner, bool quiet)
    {
        try
        {
            var r = await Latest();
            if (r is not { } l) return;
            if (!Newer(l.version, Current))
            {
                if (!quiet) MessageBox.Show(owner, tr("PhoneCast {0} is the newest version.", Current), "PhoneCast", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            var ask = MessageBox.Show(owner, tr("PhoneCast {0} is available (you have {1}).\n\nInstall it now? PhoneCast restarts by itself.", l.version, Current),
                tr("Update PhoneCast"), MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (ask != DialogResult.Yes) return;
            if (l.zip == null) { Process.Start(new ProcessStartInfo(l.page) { UseShellExecute = true }); return; }
            await Install(l.zip);
        }
        catch (Exception e)
        {
            App.Log("update: " + e.Message);
            if (!quiet) MessageBox.Show(owner, tr("Couldn't check for updates:\n{0}", e.Message), "PhoneCast", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    static async Task Install(string zipUrl)
    {
        var work = Path.Combine(Path.GetTempPath(), "phonecast-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        var zip = Path.Combine(work, "update.zip");
        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) })
        {
            http.DefaultRequestHeaders.UserAgent.ParseAdd("PhoneCast-Windows");
            await using var s = await http.GetStreamAsync(zipUrl);
            await using var f = File.Create(zip);
            await s.CopyToAsync(f);
        }
        var unpacked = Path.Combine(work, "new");
        ZipFile.ExtractToDirectory(zip, unpacked);
        // the zip may hold the files directly or in one folder
        var src = File.Exists(Path.Combine(unpacked, "PhoneCast.exe")) ? unpacked
            : Directory.GetDirectories(unpacked).FirstOrDefault(d => File.Exists(Path.Combine(d, "PhoneCast.exe")))
            ?? throw new Exception("the download has no PhoneCast.exe");
        var dest = AppContext.BaseDirectory.TrimEnd('\\');
        var exe = Path.Combine(dest, "PhoneCast.exe");
        // wait for this process to quit, copy the new files over, start PhoneCast again
        var script = Path.Combine(work, "update.cmd");
        File.WriteAllText(script,
            "@echo off\r\n" +
            $":wait\r\ntasklist /FI \"PID eq {Environment.ProcessId}\" | find \"{Environment.ProcessId}\" >nul && (timeout /t 1 >nul & goto wait)\r\n" +
            $"robocopy \"{src}\" \"{dest}\" /E /NFL /NDL /NJH /NJS >nul\r\n" +
            $"start \"\" \"{exe}\"\r\n");
        App.Log("update: installing from " + zipUrl);
        Process.Start(new ProcessStartInfo("cmd.exe", $"/c \"{script}\"") { CreateNoWindow = true, UseShellExecute = false });
        Environment.Exit(0);
    }
}
