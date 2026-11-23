using System.Diagnostics;

namespace PhoneCast;

/// "Advanced (USB debugging)": what Android only allows the shell user, done by starting scrcpy against the phone
/// over adb (USB or wireless debugging), like the Mac's Advanced.swift:
///  - phone apps in their own PC windows (each on its own virtual display)
///  - the phone's camera in a window (share it in a call, or capture it in OBS)
///  - the phone's microphone played on the PC
///  - the phone's screen really off while PhoneCast mirrors it
/// Needs scrcpy (winget install Genymobile.scrcpy, or its folder next to PhoneCast.exe). Nothing here is needed for
/// the normal features.
static class Advanced
{
    static IEnumerable<string> SearchDirs()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        yield return Path.Combine(AppContext.BaseDirectory, "scrcpy");
        yield return Path.Combine(local, "Microsoft", "WinGet", "Links");
        var pk = Path.Combine(local, "Microsoft", "WinGet", "Packages");
        if (Directory.Exists(pk))
            foreach (var d in Directory.GetDirectories(pk, "Genymobile.scrcpy*"))
                foreach (var sub in Directory.GetDirectories(d)) yield return sub;
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "scoop", "shims");
        yield return Path.Combine(local, "Android", "Sdk", "platform-tools");
        foreach (var p in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries)) yield return p;
    }

    static string Tool(string name)
    {
        foreach (var d in SearchDirs())
        {
            try { var f = Path.Combine(d, name + ".exe"); if (File.Exists(f)) return f; } catch { }
        }
        return null;
    }

    public static string Adb => Tool("adb");
    public static string Scrcpy => Tool("scrcpy");

    static readonly Dictionary<string, Process> jobs = new();
    public static bool Running(string job) { lock (jobs) return jobs.TryGetValue(job, out var p) && !p.HasExited; }

    public sealed record Device(string Serial, string Model, bool Wireless);

    public static List<Device> Devices()
    {
        var adb = Adb;
        if (adb == null) return new();
        var outp = Run(adb, "devices -l", 8) ?? "";
        return outp.Split('\n').Skip(1).Select(l => l.Split(' ', StringSplitOptions.RemoveEmptyEntries)).Where(p => p.Length >= 2 && p[1] == "device")
            .Select(p => new Device(p[0], p.FirstOrDefault(x => x.StartsWith("model:"))?[6..].Replace('_', ' ') ?? p[0],
                p[0].Contains(':') || p[0].Contains("._adb-tls-connect"))).ToList();
    }

    public static Device Pick() { var all = Devices(); var want = Settings.Str("advancedSerial"); return all.FirstOrDefault(d => d.Serial == want) ?? all.FirstOrDefault(); }

    /// One line for Settings (slow: runs adb).
    public static string Status()
    {
        if (Scrcpy == null) return tr("scrcpy isn't installed. In a terminal: winget install Genymobile.scrcpy (then restart PhoneCast)");
        if (Adb == null) return tr("adb wasn't found (it comes with scrcpy).");
        var d = Pick();
        if (d == null) return tr("No phone with USB debugging found. Turn on USB debugging (or Wireless debugging) and allow this PC on the phone.");
        return tr("Ready: {0} ({1})", d.Model, d.Wireless ? tr("wireless debugging") : "USB");
    }

    public static string AppShape { get => Settings.Str("appWindowShape") ?? "tall"; set => Settings.Set("appWindowShape", value); }

    /// One phone app in its own window; closing it moves the app back to the phone's screen.
    public static void OpenAppWindow(string pkg, string name)
    {
        var size = AppShape switch { "wide" => "--new-display=2000x1200/320", "phone" => "--new-display", _ => "--new-display=1080x2160/400" };
        Start("app:" + pkg, $"{size} --start-app={pkg} --no-vd-destroy-content --no-vd-system-decorations --no-audio \"--window-title={name}\" --display-ime-policy=local", name);
    }

    public static void Camera(string facing)
    {
        Stop("camera");
        Start("camera", $"--video-source=camera --camera-facing={facing} --max-size=1920 --no-audio --no-control \"--window-title={tr("Phone camera")}\"", tr("Phone camera"));
    }

    public static void Microphone(bool on)
    {
        if (!on) { Stop("mic"); return; }
        Start("mic", "--no-video --no-window --no-control --audio-source=mic", tr("Phone microphone"));
    }

    public static void ScreenOff(bool on)
    {
        Settings.Set("advancedScreenOff", on);
        if (!on) { Stop("screenoff"); return; }
        // a tiny 1 fps stream nobody looks at keeps scrcpy's connection (and its "screen off") alive
        Start("screenoff", "--no-window --no-audio --turn-screen-off --max-size=320 --max-fps=1 --video-bit-rate=200K --no-power-on", tr("Screen off"));
    }

    public static void Stop(string job)
    {
        Process p;
        lock (jobs) { if (!jobs.Remove(job, out p)) return; }
        try { if (!p.HasExited) p.Kill(true); } catch { }
    }

    public static void StopAll() { List<string> keys; lock (jobs) keys = jobs.Keys.ToList(); foreach (var k in keys) Stop(k); }

    static void Start(string job, string args, string what)
    {
        Task.Run(() =>
        {
            var scrcpy = Scrcpy;
            if (scrcpy == null) { Banners.Info(tr("scrcpy isn't installed"), tr("In a terminal: winget install Genymobile.scrcpy")); return; }
            var d = Pick();
            if (d == null) { Banners.Info(tr("No phone with USB debugging"), tr("Turn on USB debugging (or Wireless debugging) and allow this PC on the phone.")); return; }
            Stop(job);
            var psi = new ProcessStartInfo(scrcpy, $"-s {d.Serial} {args}")
                { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true, WorkingDirectory = Path.GetDirectoryName(scrcpy) };
            if (Adb is string adb) psi.Environment["ADB"] = adb;
            var started = DateTime.Now;
            var log = new System.Text.StringBuilder();
            try
            {
                var p = Process.Start(psi);
                p.OutputDataReceived += (_, e) => { if (e.Data != null) lock (log) log.AppendLine(e.Data); };
                p.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (log) log.AppendLine(e.Data); };
                p.BeginOutputReadLine(); p.BeginErrorReadLine();
                p.EnableRaisingEvents = true;
                p.Exited += (_, _) =>
                {
                    lock (jobs) if (jobs.TryGetValue(job, out var cur) && cur == p) jobs.Remove(job);
                    // a quick exit with an error: tell why (old Android, app not found, debugging revoked…)
                    if (p.ExitCode != 0 && (DateTime.Now - started).TotalSeconds < 8)
                    {
                        string outp; lock (log) outp = log.ToString();
                        var line = outp.Split('\n').LastOrDefault(l => l.Contains("ERROR")) ?? outp.Split('\n').LastOrDefault(l => l.Trim() != "") ?? "";
                        Banners.Info(tr("{0} didn't start", what), line.Replace("ERROR: ", "").Trim());
                        App.Log($"scrcpy {job} failed:\n{outp}");
                    }
                };
                lock (jobs) jobs[job] = p;
            }
            catch (Exception e) { Banners.Info(tr("{0} didn't start", what), e.Message); }
        });
    }

    // ---------- wireless debugging (no cable) ----------

    public static string Pair(string hostPort, string code) => Adb is string adb ? (Run(adb, $"pair {hostPort.Trim()} {code.Trim()}", 20) ?? "").Trim() : tr("adb wasn't found (it comes with scrcpy).");
    public static string Connect(string hostPort) => Adb is string adb ? (Run(adb, $"connect {hostPort.Trim()}", 15) ?? "").Trim() : tr("adb wasn't found (it comes with scrcpy).");

    static string Run(string exe, string args, int timeoutS)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true });
            var o = p.StandardOutput.ReadToEndAsync(); var e = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutS * 1000)) { try { p.Kill(true); } catch { } }
            return o.Result + e.Result;
        }
        catch { return null; }
    }
}
