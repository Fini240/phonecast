using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace PhoneCast;

/// "Stay awake" (the Windows twin of the Mac's LidAwake): the PC doesn't go to sleep, and on a laptop closing the
/// lid does nothing, so the phone can still reach it. For a while (1 h, 2 h, 8 h) or until turned off; turns
/// itself off on battery at or below 20 % and when PhoneCast quits. If PhoneCast crashes, a small helper puts the
/// lid setting back (and the next start does too). Switch it from the tray, Settings or the phone's PC tab.
sealed class KeepAwake
{
    public static readonly KeepAwake Shared = new();

    public bool On { get; private set; }
    public DateTime? Until { get; private set; }
    public string Note { get; private set; } = "";
    public int MinBattery => Settings.Int("keepAwakeMinBattery", 20);
    public event Action Changed;

    Thread holder;
    volatile bool hold;
    System.Threading.Timer timer;
    Process watchdog;

    /// At start: put the lid back if a crash left it changed.
    public void Start()
    {
        if (Settings.Str("lidOwned") is string old && old.Contains(','))
        {
            RestoreLid(old);
            Settings.Remove("lidOwned");
            App.Log("keepawake: restored the lid setting a crash left behind");
        }
        timer = new System.Threading.Timer(_ => Check(), null, 15000, 15000);
    }

    /// "off", or minutes ("0" = until turned off). Any thread.
    public void Action(string a)
    {
        if (a == "off") Disable(null);
        else if (int.TryParse(a, out var min)) Enable(min);
    }

    public void Enable(int minutes)
    {
        lock (this)
        {
            Until = minutes > 0 ? DateTime.Now.AddMinutes(minutes) : null;
            Note = "";
            if (!On)
            {
                On = true;
                hold = true;
                // the execution state belongs to a thread: keep one alive that holds it
                holder = new Thread(() =>
                {
                    SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_AWAYMODE_REQUIRED);
                    while (hold) Thread.Sleep(500);
                    SetThreadExecutionState(ES_CONTINUOUS);
                }) { IsBackground = true, Name = "keepawake" };
                holder.Start();
                if (HasLid()) TakeLid();
            }
        }
        App.Log($"keepawake: on {(minutes > 0 ? minutes + " min" : "until off")}");
        Fire();
    }

    public void Disable(string reason)
    {
        lock (this)
        {
            if (!On) return;
            On = false; Until = null;
            Note = reason ?? "";
            hold = false;
            if (Settings.Str("lidOwned") is string old) { RestoreLid(old); Settings.Remove("lidOwned"); }
            try { if (watchdog is { HasExited: false }) watchdog.Kill(); } catch { }
            watchdog = null;
        }
        App.Log("keepawake: off" + (reason != null ? " (" + reason + ")" : ""));
        if (reason != null) Banners.Info(tr("The PC can sleep again"), reason);
        Fire();
    }

    public void StopOnQuit() { if (On) Disable(null); }

    void Check()
    {
        if (!On) return;
        if (Until is DateTime u && DateTime.Now >= u) { Disable(tr("The time you chose is up.")); return; }
        if (GetSystemPowerStatus(out var p) && p.ACLineStatus == 0 && p.BatteryLifePercent <= 100 && p.BatteryLifePercent <= MinBattery)
            Disable(tr("The battery is at {0} %.", p.BatteryLifePercent));
    }

    void Fire() => Ui.Post(() => { Changed?.Invoke(); Store.Shared.Fire("pc"); });

    public string Summary => !On ? tr("Off") : Until is DateTime u ? tr("Until {0:t}", u) : tr("Until you turn it off");

    public JsonObject StatusForPhone() => new()
    {
        ["on"] = On, ["ready"] = true, ["min"] = MinBattery,
        ["until"] = Until is DateTime u ? new DateTimeOffset(u).ToUnixTimeSeconds() : 0,
        ["note"] = Note,
    };

    // ---------- laptop lid: "do nothing" while on ----------

    const string Lid = "SUB_BUTTONS LIDACTION";

    static bool HasLid()
    {
        var (ok, outp) = Powercfg($"/query SCHEME_CURRENT {Lid}");
        return ok && AcDc(outp) != null;
    }

    void TakeLid()
    {
        var (ok, outp) = Powercfg($"/query SCHEME_CURRENT {Lid}");
        if (!ok) return;
        if (AcDc(outp) is not (string ac, string dc)) return;
        var old = ac + "," + dc;
        Settings.Set("lidOwned", old);
        Powercfg($"/setacvalueindex SCHEME_CURRENT {Lid} 0");
        Powercfg($"/setdcvalueindex SCHEME_CURRENT {Lid} 0");
        Powercfg("/setactive SCHEME_CURRENT");
        // if PhoneCast dies, put the lid back as soon as it's gone
        try
        {
            int pid = Environment.ProcessId;
            var cmd = $"Wait-Process -Id {pid}; powercfg /setacvalueindex SCHEME_CURRENT {Lid} {ac}; powercfg /setdcvalueindex SCHEME_CURRENT {Lid} {dc}; powercfg /setactive SCHEME_CURRENT";
            watchdog = Process.Start(new ProcessStartInfo("powershell.exe", $"-NoProfile -WindowStyle Hidden -Command \"{cmd}\"")
                { CreateNoWindow = true, UseShellExecute = false });
        }
        catch (Exception e) { App.Log("keepawake: watchdog " + e.Message); }
    }

    static void RestoreLid(string old)
    {
        var p = old.Split(',');
        if (p.Length != 2) return;
        Powercfg($"/setacvalueindex SCHEME_CURRENT {Lid} {p[0]}");
        Powercfg($"/setdcvalueindex SCHEME_CURRENT {Lid} {p[1]}");
        Powercfg("/setactive SCHEME_CURRENT");
    }

    /// The last two "…: 0x…" lines of powercfg /query are the AC and DC values (labels are translated, so not by name).
    static (string, string)? AcDc(string outp)
    {
        var v = System.Text.RegularExpressions.Regex.Matches(outp, @":\s*0x([0-9a-fA-F]+)\s*$", System.Text.RegularExpressions.RegexOptions.Multiline)
            .Select(m => Convert.ToInt32(m.Groups[1].Value, 16).ToString()).ToList();
        return v.Count >= 2 ? (v[^2], v[^1]) : null;
    }

    static (bool, string) Powercfg(string args)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo("powercfg.exe", args)
                { CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true });
            var o = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            return (p.ExitCode == 0, o);
        }
        catch (Exception e) { App.Log("powercfg: " + e.Message); return (false, ""); }
    }

    const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 1, ES_AWAYMODE_REQUIRED = 0x40;
    [DllImport("kernel32")] static extern uint SetThreadExecutionState(uint f);
    [StructLayout(LayoutKind.Sequential)] struct PowerStatus { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public int LifeTime, FullLifeTime; }
    [DllImport("kernel32")] static extern bool GetSystemPowerStatus(out PowerStatus s);
}
