using System.Drawing;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PhoneCast;

/// This PC's battery, CPU and memory for Overview (UI thread, every 2 s), plus the other machines'
/// connect times ("Devices to watch", every 5 s) and the auto-lock when the phone leaves.
static class PcStats
{
    public sealed class Sample { public int? Battery, Cpu, Mem; public bool Charging; public string Uptime; }

    static ulong lastIdle, lastTotal;
    static System.Windows.Forms.Timer timer;
    static int ticks;

    public static void Start()
    {
        timer = new System.Windows.Forms.Timer { Interval = 2000 };
        timer.Tick += (_, _) => Tick();
        timer.Start();
        Tick();
    }

    static void Tick()
    {
        var s = Store.Shared;
        s.Pc = Read();
        s.Fire("pc");
        if (s.Connected) SendToPhone(s);
        if (ticks++ % 5 == 0) Probe();   // devices: every 10 s
        if (ticks % 7 == 0) AutoLock.Check();
    }

    /// What the phone's Mac tab shows while it controls this PC (the same keys the Mac sends).
    static void SendToPhone(Store s)
    {
        var p = s.Pc;
        var o = new System.Text.Json.Nodes.JsonObject { ["name"] = Environment.MachineName, ["os"] = "windows" };
        if (p.Battery is int b) { o["battery"] = b; o["charging"] = p.Charging; }
        if (p.Cpu is int c) o["cpu"] = c;
        if (p.Mem is int m) o["mem"] = m;
        o["thermal"] = "—";
        if (s.Rtt >= 0) o["rtt"] = (int)Math.Round(s.Rtt);
        var devs = new System.Text.Json.Nodes.JsonArray();
        foreach (var d in s.Devices)
        {
            var j = new System.Text.Json.Nodes.JsonObject { ["name"] = d.name };
            if (d.ms is double ms) j["ms"] = (int)Math.Round(ms);
            devs.Add(j);
        }
        o["devices"] = devs;
        o["lidAwake"] = KeepAwake.Shared.StatusForPhone();
        s.Link?.SendStatus(o);
    }

    static Sample Read()
    {
        var o = new Sample();
        if (GetSystemPowerStatus(out var p))
        {
            if (p.BatteryLifePercent <= 100 && (p.BatteryFlag & 128) == 0) o.Battery = p.BatteryLifePercent;
            o.Charging = p.ACLineStatus == 1;
        }
        if (GetSystemTimes(out var idle, out var kernel, out var user))
        {
            ulong i = idle.Value, total = kernel.Value + user.Value;   // kernel includes idle
            if (lastTotal > 0 && total > lastTotal) o.Cpu = (int)Math.Round(100.0 * (1 - (double)(i - lastIdle) / (total - lastTotal)));
            lastIdle = i; lastTotal = total;
        }
        var m = new MemStatus { Length = (uint)Marshal.SizeOf<MemStatus>() };
        if (GlobalMemoryStatusEx(ref m)) o.Mem = (int)m.MemoryLoad;
        var up = TimeSpan.FromMilliseconds(Environment.TickCount64);
        o.Uptime = up.TotalDays >= 1 ? tr("{0} d {1} h", (int)up.TotalDays, up.Hours) : tr("{0} h {1} min", up.Hours, up.Minutes);
        return o;
    }

    // ---------- devices to watch ----------

    static bool probing;
    static void Probe()
    {
        var cfg = Store.Shared.DevicesConfig;
        var targets = cfg.Split('\n').Select(l => l.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries))
            .Where(p => p.Length >= 2 && p[^1].Contains(':'))
            .Select(p => (name: string.Join(" ", p[..^1]), hp: p[^1])).ToList();
        if (targets.Count == 0) { if (Store.Shared.Devices.Count > 0) { Store.Shared.Devices = new(); Store.Shared.Fire("devices"); } return; }
        if (probing) return;
        probing = true;
        Task.Run(async () =>
        {
            var results = await Task.WhenAll(targets.Select(async t =>
            {
                var i = t.hp.LastIndexOf(':');
                if (!int.TryParse(t.hp[(i + 1)..], out var port)) return (t.name, (double?)null);
                try
                {
                    using var c = new TcpClient();
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    var task = c.ConnectAsync(t.hp[..i], port);
                    if (await Task.WhenAny(task, Task.Delay(2000)) != task || task.IsFaulted) return (t.name, (double?)null);
                    return (t.name, (double?)sw.Elapsed.TotalMilliseconds);
                }
                catch { return (t.name, (double?)null); }
            }));
            Ui.Post(() => { probing = false; Store.Shared.Devices = results.ToList(); Store.Shared.Fire("devices"); });
        });
    }

    // ---------- Win32 ----------

    [StructLayout(LayoutKind.Sequential)] struct PowerStatus { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public int LifeTime, FullLifeTime; }
    [StructLayout(LayoutKind.Sequential)] struct FileTime { public uint Low, High; public ulong Value => (ulong)High << 32 | Low; }
    [StructLayout(LayoutKind.Sequential)] struct MemStatus { public uint Length, MemoryLoad; public ulong TotalPhys, AvailPhys, TotalPage, AvailPage, TotalVirtual, AvailVirtual, AvailExtended; }
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out PowerStatus s);
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out FileTime idle, out FileTime kernel, out FileTime user);
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemStatus m);
}

/// Opt-in: lock this PC when the phone leaves. Only when the link has been gone for the chosen time
/// after having been connected AND nobody touched the keyboard or mouse for that long either.
static class AutoLock
{
    static DateTime? lostAt;
    static bool wasConnected;

    public static void Changed(bool connected)
    {
        if (connected) { wasConnected = true; lostAt = null; }
        else if (wasConnected && lostAt == null) lostAt = DateTime.Now;
    }

    public static void Check()
    {
        var s = Store.Shared;
        if (!s.AutoLock || lostAt is not DateTime lost || s.Connected) return;
        double wait = Math.Max(1, s.AutoLockMinutes) * 60;
        double idle = IdleSeconds();
        if ((DateTime.Now - lost).TotalSeconds < wait || idle < wait) return;
        lostAt = null; wasConnected = false;   // once per departure
        App.Log($"autolock: phone gone {(int)(DateTime.Now - lost).TotalSeconds} s, PC idle {(int)idle} s -> locking");
        LockWorkStation();
    }

    public static double IdleSeconds()
    {
        var li = new LastInput { Size = (uint)Marshal.SizeOf<LastInput>() };
        if (!GetLastInputInfo(ref li)) return 0;
        return (uint)(Environment.TickCount - (int)li.Time) / 1000.0;
    }

    [StructLayout(LayoutKind.Sequential)] struct LastInput { public uint Size, Time; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput li);
    [DllImport("user32.dll")] public static extern bool LockWorkStation();
}

/// Clipboard both ways (UI thread). Copies on this PC go to the phone by themselves when "Copy to the
/// phone automatically" is on; what comes from the phone isn't sent back.
static class ClipboardSync
{
    static Listener listener;
    static uint ours;
    static System.Windows.Forms.Timer debounce;

    public static void Start()
    {
        listener = new Listener();
        debounce = new System.Windows.Forms.Timer { Interval = 300 };
        debounce.Tick += (_, _) => { debounce.Stop(); Send(auto: true); };
    }

    public static void FromPhone(string text)
    {
        try { Clipboard.SetText(text); ours = GetClipboardSequenceNumber(); } catch (Exception e) { App.Log("clip: " + e.Message); }
    }

    public static void FromPhone(Image img, string file = null)
    {
        try
        {
            var data = new DataObject();
            data.SetImage(new Bitmap(img));
            if (file != null) data.SetFileDropList(new System.Collections.Specialized.StringCollection { file });
            Clipboard.SetDataObject(data, true);
            ours = GetClipboardSequenceNumber();
        }
        catch (Exception e) { App.Log("clip picture: " + e.Message); }
    }

    public static void SendNow() => Send(auto: false);

    static void Send(bool auto)
    {
        var s = Store.Shared;
        if (!s.Connected) { if (!auto) Banners.Info(tr("The phone isn't linked"), tr("Open PhoneCast on the phone; the link connects by itself.")); return; }
        try
        {
            if (Clipboard.ContainsImage() && Clipboard.GetImage() is Image img) { s.Link.SendClipImage(img); return; }
            if (Clipboard.ContainsFileDropList())
            {
                if (auto) return;   // copying files in Explorer shouldn't upload them
                s.Link.SendFiles(Clipboard.GetFileDropList().Cast<string>().ToArray());
                return;
            }
            var t = Clipboard.GetText();
            if (string.IsNullOrEmpty(t)) { if (!auto) Banners.Info(tr("The clipboard is empty"), ""); return; }
            if (t.Length > 1_000_000) return;
            s.Link.SendClipText(t);
            if (!auto) Banners.Info(tr("Copied to the phone"), t.Length > 80 ? t[..80] + "…" : t);
        }
        catch (Exception e) { App.Log("clip send: " + e.Message); }
    }

    sealed class Listener : NativeWindow
    {
        public Listener()
        {
            CreateHandle(new CreateParams { Parent = (IntPtr)(-3) });   // message-only window
            AddClipboardFormatListener(Handle);
        }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x031D && Store.Shared.AutoClipboard && GetClipboardSequenceNumber() != ours) // WM_CLIPBOARDUPDATE
            {
                debounce.Stop(); debounce.Start();
            }
            base.WndProc(ref m);
        }
    }

    [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
}
