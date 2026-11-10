using System.Diagnostics;
using System.Net;
using System.Windows.Forms;

namespace PhoneCast;

sealed unsafe partial class App
{
    // =====================================================================
    // connecting

    /// Addresses to try, best first: the phone found on this network, the saved IP, then its Tailscale address.
    List<(string host, int port, string label)> WifiCandidates()
    {
        if (TestHost != null) return new() { (TestHost, 27183, "test phone") };
        var outL = new List<(string, int, string)>();
        var seen = new HashSet<string>();
        void Add(string h, int p, string l) { if (seen.Add($"{h}:{p}")) outL.Add((h, p, l)); }
        // USB tethering on the phone: a network over the cable, the phone is that network's gateway
        foreach (var gw in TetherGateways()) Add(gw, 27183, TetherLabel);
        var found = mdns.Current();
        string saved = Settings.Str("service");
        foreach (var f in found.OrderBy(f => f.Name == saved ? 0 : 1)) Add(f.Address.ToString(), f.Port, f.Name);
        var host = Settings.Str("host");
        if (!string.IsNullOrWhiteSpace(host)) Add(host, 27183, host);
        var ts = Settings.Str("tailnetHost");
        if (!string.IsNullOrWhiteSpace(ts)) Add(ts, 27183, ts + " (Tailscale)");
        return outL;
    }

    bool UsbGaveUp => Now < usbRetryAt;

    // ---- QR pairing (this computer's identity; the phone scans it, see ShowPairing) ----

    /// The PIN to log in with, "" when only QR pairing is set up, null when neither is.
    string LoginPin => Settings.Str("pin") ?? (Settings.Bool("qrPaired") ? "" : null);
    /// The phone refused our QR login this session (code not scanned / removed): use the PIN.
    bool qrRejected;

    static (string id, byte[] key) PairIdentity()
    {
        var id = Settings.Str("pairId"); var k = Settings.Str("pairKey");
        if (id == null || k == null || k.Length != 64)
        {
            id = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
            k = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
            Settings.Set("pairId", id); Settings.Set("pairKey", k);
        }
        return (id, Convert.FromHexString(k));
    }

    static string PairCode()
    {
        var (id, key) = PairIdentity();
        return $"phonecast:pair?v=1&id={id}&k={Convert.ToHexString(key).ToLowerInvariant()}&n={Uri.EscapeDataString(Environment.MachineName)}";
    }

    void ShowPairing()
    {
        if (mode == Mode.Game) SetMode(Mode.Normal);
        using var d = new PairDialog(PairCode());
        if (d.ShowDialog(Owner) != DialogResult.OK) return;
        Settings.Set("qrPaired", true);
        qrRejected = false; wifiIndex = 0;
        ConnectSaved();
    }
    const string TetherLabel = "USB cable (tethering)";
    /// The old cable mode (Android Open Accessory via libusb + UsbDk). Off on Windows: Windows puts its
    /// own MTP driver on the accessory interface, so opening it hangs. USB tethering is used instead.
    static readonly bool UseAoa = Environment.GetEnvironmentVariable("PHONECAST_AOA") != null;

    /// Gateways of phone tethering adapters (Remote NDIS / NCM / Samsung), i.e. the phone's address on the cable.
    static List<string> TetherGateways()
    {
        var outL = new List<string>();
        try
        {
            foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                var d = (ni.Description + " " + ni.Name).ToLowerInvariant();
                if (!(d.Contains("remote ndis") || d.Contains("rndis") || d.Contains("ncm") || d.Contains("samsung") || d.Contains("android"))) continue;
                foreach (var g in ni.GetIPProperties().GatewayAddresses)
                    if (g.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any)) outL.Add(g.Address.ToString());
            }
        }
        catch { }
        return outL;
    }
    string lastTether = "";
    double lastPingAt;
    bool tetherProbing;

    /// Windows gives the phone's tethering adapter the same priority as the home network, so part of the
    /// PC's internet would go through the phone (mobile data, extra delay). Offer once to lower it.
    void CheckTetherRoute()
    {
        try
        {
            System.Net.NetworkInformation.NetworkInterface tether = null;
            foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                var d = (ni.Description + " " + ni.Name).ToLowerInvariant();
                if ((d.Contains("remote ndis") || d.Contains("rndis") || d.Contains("ncm") || d.Contains("samsung") || d.Contains("android"))
                    && ni.GetIPProperties().GatewayAddresses.Count > 0) { tether = ni; break; }
            }
            if (tether == null) return;
            int metric = tether.GetIPProperties().GetIPv4Properties()?.Index is int idx ? RouteMetricOf(idx) : -1;
            Log($"cable: tethering adapter '{tether.Name}' metric {metric}");
            if (metric >= 500 || Settings.Bool("tetherRouteDeclined")) return;
            var asked = new ManualResetEventSlim();
            DialogResult r = DialogResult.None;
            Post(() =>
            {
                if (mode != Mode.Game) // never pop up a dialog mid-game; asked next time
                    r = MessageBox.Show(Owner,
                "The phone is connected by USB tethering. Windows now sends part of this PC's internet through the phone too (mobile data, extra delay).\n\n" +
                "Keep the PC's internet on its normal connection and use the cable only for PhoneCast? Windows will ask for administrator permission once.",
                "PhoneCast — USB cable", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                asked.Set();
            });
            asked.Wait();
            if (r == DialogResult.None) return;
            if (r != DialogResult.Yes) { Settings.Set("tetherRouteDeclined", true); return; }
            var ps = $"Set-NetIPInterface -InterfaceAlias '{tether.Name.Replace("'", "''")}' -AddressFamily IPv4 -InterfaceMetric 900";
            var p = Process.Start(new ProcessStartInfo("powershell.exe", $"-NoProfile -WindowStyle Hidden -Command \"{ps}\"") { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden });
            p?.WaitForExit();
            Log($"cable: lowered tethering priority, exit {p?.ExitCode}, metric now {RouteMetricOf(tether.GetIPProperties().GetIPv4Properties().Index)}");
        }
        catch (Exception e) { Log("cable: tether route: " + e.Message); }
    }

    static int RouteMetricOf(int ifIndex)
    {
        try
        {
            var psi = new ProcessStartInfo("powershell.exe", $"-NoProfile -Command \"(Get-NetIPInterface -InterfaceIndex {ifIndex} -AddressFamily IPv4).InterfaceMetric\"")
            { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            using var p = Process.Start(psi);
            var o = p.StandardOutput.ReadToEnd(); p.WaitForExit(5000);
            return int.TryParse(o.Trim(), out var m) ? m : -1;
        }
        catch { return -1; }
    }
    double usbBusySince;
    bool lastPresent, askedUsbDk;

    /// Cable first (if a phone is plugged in), Wi-Fi otherwise.
    void ConnectSaved()
    {
        var pin = LoginPin;
        if (pin == null) { ShowConnect(); return; }
        wantConnected = true;
        var usb = UsbBridge.Shared;
        if (UseAoa && !usbBusy && !UsbGaveUp && !NoUsb && usb.Loaded && usb.PhonePresent())
        {
            if (!usb.HaveUsbDk) { OfferUsbDk(); ConnectWifi(pin); return; }
            usbBusy = true; usbBusySince = Now;
            bool switching = stateText == "Connected" && link != null;
            Log($"cable: trying USB (switching from Wi-Fi: {switching})");
            if (!switching)
            {
                var old = link; link = null; if (old != null) { old.OnState = null; old.Close(); }
                stateText = "Connecting…";
                SetMessage("Connecting over the USB cable…\n(If the phone asks to open PhoneCast for this USB device, tap OK / Always.)");
                UpdateTitle();
            }
            new Thread(() =>
            {
                var port = usb.Start();
                Post(() =>
                {
                    usbBusy = false;
                    Log($"cable: USB start -> {(port.HasValue ? "port " + port : "failed: " + usb.LastError)}");
                    if (port.HasValue) { viaUSB = true; Connect("127.0.0.1", port.Value, "USB cable", pin); }
                    else
                    {
                        usbRetryAt = Now + (usb.HeldByOtherApp ? 30 : 10);
                        if (!(switching && stateText == "Connected")) ConnectWifi(pin);
                        if (usb.HeldByOtherApp) { deviceLabel += " (cable busy: another app is using the phone's USB connection)"; UpdateTitle(); }
                    }
                });
            }) { IsBackground = true }.Start();
            return;
        }
        ConnectWifi(pin);
    }

    void ConnectWifi(string pin)
    {
        var c = WifiCandidates();
        if (c.Count == 0) { ShowConnect(); return; }
        if (wifiIndex >= c.Count) wifiIndex = 0;
        var (h, p, label) = c[wifiIndex];
        Log($"wifi: trying {label} ({wifiIndex + 1} of {c.Count})");
        viaUSB = false;
        Connect(h, p, label, pin);
    }

    /// Every few seconds: switch to the cable when it gets plugged in.
    void WatchCable()
    {
        // tethering cable appeared (or went away): reconnect so the cable is used when it's there
        var tg = string.Join(",", TetherGateways());
        if (tg != lastTether)
        {
            Log($"cable: tethering {(tg == "" ? "gone" : "at " + tg)}");
            bool appeared = tg != "" && lastTether == "";
            lastTether = tg;
            if (appeared) new Thread(CheckTetherRoute) { IsBackground = true }.Start();
            if (appeared && wantConnected && deviceLabel != TetherLabel && LoginPin is string pin0)
            { wifiIndex = 0; ConnectWifi(pin0); return; }
        }
        // On Wi-Fi while the tethering cable is there (the phone wasn't ready on the cable yet when
        // we connected): switch over as soon as the phone answers on the cable.
        if (tg != "" && stateText == "Connected" && deviceLabel != TetherLabel && !tetherProbing && LoginPin is string pin1)
        {
            tetherProbing = true;
            var gw = tg.Split(',')[0];
            new Thread(() =>
            {
                bool ok = false;
                try { using var c = new System.Net.Sockets.TcpClient(); ok = c.ConnectAsync(gw, 27183).Wait(1500) && c.Connected; } catch { }
                Post(() =>
                {
                    tetherProbing = false;
                    if (ok && stateText == "Connected" && deviceLabel != TetherLabel)
                    { Log("cable: the phone answers on the tethering cable, switching to it"); wifiIndex = 0; ConnectWifi(pin1); }
                });
            }) { IsBackground = true }.Start();
        }
        if (!UseAoa || NoUsb || !UsbBridge.Shared.Loaded) return;
        // libusb can hang on a phone that is half-way through switching: never wait on it forever
        if (usbBusy && Now - usbBusySince > 15)
        {
            Log("cable: USB start hangs, using Wi-Fi meanwhile");
            usbBusy = false; usbRetryAt = Now + 30;
            if (stateText != "Connected" && LoginPin is string pin) ConnectWifi(pin);
            return;
        }
        bool present = UsbBridge.Shared.PhonePresent();
        if (present != lastPresent) { Log($"cable: phone {(present ? "plugged in" : "unplugged")} (viaUSB={viaUSB} usbdk={UsbBridge.Shared.HaveUsbDk})"); lastPresent = present; }
        if (!present) usbRetryAt = 0;
        if (wantConnected && present && !viaUSB && !usbBusy && !UsbGaveUp) ConnectSaved();
    }

    void OfferUsbDk()
    {
        if (askedUsbDk || Settings.Bool("usbDkDeclined")) return;
        askedUsbDk = true;
        After(0.1, () => InstallUsbDk(ask: true));
    }

    void InstallUsbDk(bool ask)
    {
        if (mode == Mode.Game) SetMode(Mode.Normal);
        var msi = Path.Combine(AppContext.BaseDirectory, "UsbDk_1.0.22_x64.msi");
        if (ask)
        {
            var r = MessageBox.Show(Owner,
                "A phone is plugged in. For the USB cable mode (lowest delay) Windows needs the free UsbDk USB driver (by Red Hat / Daynix) once.\n\n" +
                "Install it now? Windows will ask for administrator permission.\n\nUntil then PhoneCast keeps using Wi-Fi.",
                "PhoneCast — USB cable mode", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (r != DialogResult.Yes) { Settings.Set("usbDkDeclined", true); return; }
        }
        if (!File.Exists(msi)) { MessageBox.Show(Owner, "UsbDk installer missing next to PhoneCast.exe.", "PhoneCast"); return; }
        try
        {
            SetMessage("Installing the USB driver… (approve the Windows prompt)");
            RedrawOverlay(); Render();
            var p = Process.Start(new ProcessStartInfo("msiexec.exe", $"/i \"{msi}\" /passive /norestart") { UseShellExecute = true, Verb = "runas" });
            p?.WaitForExit();
            Log($"usbdk: installer exit {p?.ExitCode}");
            Settings.Remove("usbDkDeclined");
            UsbBridge.Shared.Init();
            SetMessage(stateText == "Connected" ? null : message);
            MessageBox.Show(Owner, UsbBridge.Shared.HaveUsbDk
                ? "USB driver installed. Unplug the phone and plug it back in — PhoneCast then switches to the cable."
                : "The USB driver doesn't seem to be active yet. Restart Windows once, then plug the phone in again.", "PhoneCast");
            usbRetryAt = 0;
        }
        catch (Exception e) { Log("usbdk: " + e.Message); SetMessage(stateText == "Connected" ? null : message); }
    }

    IWin32Window Owner => new HwndOwner(hwnd);

    void Connect(string host, int port, string label, string pin)
    {
        var old = link;
        if (old != null) { old.OnState = null; old.OnPacket = null; old.Close(); }
        udp?.Stop(); udp = null; udpActive = false;
        ReleaseAll();
        deviceLabel = label;
        linkWasReady = false;
        var l = new Link(host, port);
        link = l;
        dec.Reset();
        sizedOnce = false;
        l.OnState = (st, why) => Post(() =>
        {
            if (link != l) return;
            switch (st)
            {
                case LinkState.Connecting:
                    stateText = "Connecting…";
                    SetMessage(viaUSB ? "Cable connected — waiting for the phone.\nOpen PhoneCast on the phone and tap Start sharing." : $"Connecting to {label}…");
                    break;
                case LinkState.Ready:
                    retryDelay = 2; wifiIndex = 0; linkWasReady = true; lastPong = 0;
                    stateText = "Connected"; SetMessage(null);
                    WindowIcon(true);
                    Log($"connected via {label}{(l.UsedQr ? " (QR pairing, phone verified)" : "")}");
                    if (l.UsedQr) Settings.Set("qrPaired", true);
                    SendSettings();
                    break;
                case LinkState.BadPin:
                    if (l.UsedQr)
                    {
                        // the phone doesn't know this PC's QR code (not scanned, or removed on the phone)
                        Log("pairing: the phone refused our QR login");
                        qrRejected = true;
                        if (!string.IsNullOrEmpty(Settings.Str("pin"))) { After(0.3, () => { if (link == l) ConnectSaved(); }); break; }
                        wantConnected = false;
                        stateText = "Not paired";
                        SetMessage("The phone doesn't know this PC yet.\nScan its QR code with the phone (Ctrl+P)");
                        After(0.2, ShowPairing);
                        break;
                    }
                    wantConnected = false;
                    stateText = "Wrong PIN";
                    SetMessage("Wrong PIN — check the PIN in the phone app");
                    After(0.2, () => ShowConnect());
                    break;
                case LinkState.Closed:
                    Log($"closed ({label}): {why}");
                    udp?.Stop(); udp = null; udpActive = false;
                    if (viaUSB) { UsbBridge.Shared.Stop(); viaUSB = false; }
                    audio.Stop();
                    SetMode(Mode.Normal);
                    stateText = "Disconnected";
                    WindowIcon(false);
                    bool wasWifi = label != "USB cable", neverReady = !linkWasReady;
                    if (wantConnected && wasWifi && neverReady && wifiIndex + 1 < WifiCandidates().Count)
                    {
                        wifiIndex++;
                        SetMessage($"{label} didn't answer ({why}) — trying the next address…");
                        After(0.3, () => { if (wantConnected && link == l) ConnectSaved(); });
                    }
                    else if (wantConnected)
                    {
                        if (wasWifi && neverReady) wifiIndex = 0;
                        double wait = retryDelay;
                        retryDelay = Math.Min(15, retryDelay * 2);
                        SetMessage($"Lost connection ({why})\nRetrying in {(int)wait} s — is sharing on in the phone app?");
                        After(wait, () => { if (wantConnected && link == l) ConnectSaved(); });
                    }
                    else SetMessage("Not connected\nCtrl+K to connect");
                    break;
            }
            needRender = true;
            UpdateTitle();
        });
        l.OnPacket = (t, p) => Packet(l, t, p);
        var (pid, pkey) = PairIdentity();
        l.Start(new Login(pin, pid, pkey, UseQr: Settings.Bool("qrPaired") && !qrRejected));
    }

    void Disconnect()
    {
        wantConnected = false;
        link?.Close();
        UsbBridge.Shared.Stop();
    }

    void SendSettings()
    {
        int maxSize = Settings.Int("resolution", 0);
        if (maxSize == 0 && Sdl.SDL_GetDisplayBounds(Math.Max(0, Sdl.SDL_GetWindowDisplayIndex(win)), out var b) == 0) maxSize = Math.Max(b.w, b.h);
        maxSize = Math.Min(maxSize, 65535);
        link?.Send(CT.Settings, new[] { (byte)(maxSize >> 8), (byte)maxSize, (byte)Bitrate });
    }

    void Ping()
    {
        if (stateText != "Connected") return;
        double now = Now;
        if (lastPong == 0) lastPong = now;
        // the main loop was stuck (a dialog was open, window dragged): answers from the phone waited
        // in the queue, so this says nothing about the phone
        if (lastPingAt > 0 && now - lastPingAt > 2) lastPong = now;
        lastPingAt = now;
        if (now - lastPong > 6) { lastPong = 0; link?.Close("the phone stopped answering"); return; }
        // A still screen sends no video at all, so silence later on proves nothing. Only if not a single
        // datagram arrived since UDP was switched on is it blocked (firewall, network).
        if (udpActive && udp != null && udp.LastPacketAt < udpOnAt && now - udpOnAt > 2) { Log("udp: no video datagrams at all, back to TCP"); udp.Stop(); udp = null; }
        if (udpActive && udp != null && udp.RecentLossCount() >= 8) { Log("udp: 8+ frames lost in 5 s, back to TCP"); udp.Stop(); udp = null; }
        long t = Stopwatch.GetTimestamp();
        var b = new byte[8];
        for (int i = 0; i < 8; i++) b[i] = (byte)(t >> (56 - 8 * i));
        link?.Send(CT.Ping, b);
    }

    // runs on the link's reader thread
    void Packet(Link l, byte type, byte[] p)
    {
        switch (type)
        {
            case PT.Frame:
                {
                    double now = Now;
                    if (lastFrameAt > 0 && now - lastFrameAt > 0.15) LogLag((now - lastFrameAt) * 1000);
                    if (lastFrameAt > 0 && now - lastFrameAt > 0.07 && fps >= 20) lock (stutters) stutters.Add(now);
                    lastFrameAt = now;
                    videoQ.Enqueue((type, p, l)); Wake();
                    break;
                }
            case PT.Config: case PT.Format: videoQ.Enqueue((type, p, l)); Wake(); break;
            case PT.Audio: audio.Push(p); break;
            case PT.UdpToken:
                {
                    if (p.Length < 6 || l.Remote == null) return;
                    uint token = (uint)(p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]);
                    int port = p[4] << 8 | p[5];
                    Post(() =>
                    {
                        if (link != l) return;
                        udp?.Stop();
                        try
                        {
                            var u = new UdpVideoIn(l.Remote, port, token);
                            u.OnFrame = payload => Packet(l, PT.Frame, payload);
                            u.OnNeedKeyframe = () => l.Send(CT.Keyframe);
                            udp = u; u.Start();
                        }
                        catch (Exception e) { Log("udp: no socket: " + e.Message); }
                    });
                    break;
                }
            case PT.UdpOn: Post(() => { udpActive = true; udpOnAt = Now; Log("udp: video now over UDP"); UpdateTitle(); }); break;
            case PT.UdpOff: Post(() => { udpActive = false; UpdateTitle(); }); break;
            case PT.Pong:
                {
                    if (p.Length != 8) return;
                    long sent = 0;
                    for (int i = 0; i < 8; i++) sent = sent << 8 | p[i];
                    double rtt = (Stopwatch.GetTimestamp() - sent) * 1000.0 / Stopwatch.Frequency;
                    Post(() => { lastPong = Now; rttMs = rttMs == 0 ? rtt : rttMs * 0.7 + rtt * 0.3; });
                    break;
                }
            case PT.Stats:
                {
                    if (p.Length < 4) break;
                    int n = p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
                    Health h = null;
                    if (p.Length >= 12)
                    {
                        short t = (short)(p[4] << 8 | p[5]), w = (short)(p[8] << 8 | p[9]);
                        h = new Health { TempC = t / 10.0, Battery = p[6], Plugged = p[7] != 0, Watts = w / 10.0, Thermal = p[10], Headroom = p[11] };
                        if (p.Length >= 16)
                        {
                            short c = (short)(p[12] << 8 | p[13]), g = (short)(p[14] << 8 | p[15]);
                            if (c != short.MinValue) h.CpuC = c / 10.0;
                            if (g != short.MinValue) h.GpuC = g / 10.0;
                        }
                    }
                    Post(() => { resyncs = n; if (h != null) health = h; });
                    break;
                }
            case PT.ResResult:
                {
                    byte r = p.Length > 0 ? p[0] : (byte)2;
                    Post(() => ResolutionResult(r));
                    break;
                }
            case PT.HelloOK: case PT.Control:
                {
                    bool on = p.Length > 0 && p[0] == 1;
                    Post(() => { controlAvailable = on; UpdateTitle(); });
                    break;
                }
        }
    }

    void ResolutionResult(byte r)
    {
        if (r == 0) return;
        if (r == 1)
            MessageBox.Show(Owner, "Turn on USB debugging once and run:\n\nadb shell pm grant de.finn.phonecast android.permission.WRITE_SECURE_SETTINGS\n\nIt stays granted after you turn USB debugging off again.", "The phone needs one permission first");
        else
            MessageBox.Show(Owner, "Android refused the change. You can still set it with adb: adb shell wm size", "The phone couldn't change its screen shape");
    }

    // =====================================================================
    // dialogs

    void ShowConnect()
    {
        if (mode == Mode.Game) SetMode(Mode.Normal);
        using var d = new ConnectDialog(mdns.Current().Select(f => f.Name).ToList());
        if (d.ShowDialog(Owner) != DialogResult.OK) return;
        Settings.Set("pin", d.Pin);
        Settings.Set("tailnetHost", d.Tailnet);
        wifiIndex = 0;
        if (d.Service != null) { Settings.Set("service", d.Service); Settings.Remove("host"); }
        else { Settings.Set("host", d.Host); Settings.Remove("service"); }
        ConnectSaved();
    }

    void ShowShortcuts()
    {
        if (mode == Mode.Game) SetMode(Mode.Normal);
        MessageBox.Show(Owner,
            "F11 / Ctrl+F   Full screen on / off\n" +
            "Ctrl+1  Fit (whole picture)   Ctrl+2  Fill (no bars)   Ctrl+3  Stretch\n" +
            "Ctrl+0  Window size = phone\n\n" +
            "Ctrl+B  Back    Ctrl+H  Home    Ctrl+R  Recent apps\n" +
            "Ctrl+N  Notifications    Ctrl+M  Mute sound    Ctrl+O  Stats overlay\n\n" +
            "Ctrl+E  Edit key map  (Esc when done; drag markers to move them)\n" +
            "Ctrl+G  Mouse aiming  (Esc to leave; needs a LOOK area)\n" +
            "Ctrl+T  Keys type text instead of pressing buttons\n" +
            "Ctrl+= / Ctrl+-   Mouse aiming faster / slower\n" +
            "Ctrl+J  Show/hide key markers\n\n" +
            "Ctrl+K  Connect    Ctrl+Shift+D  Disconnect    Ctrl+I  This list\n\n" +
            "Mouse: click = tap · drag = swipe · wheel / touchpad = scroll\n" +
            "Right-click or Esc = Back · middle-click = Home · side buttons can be mapped",
            "PhoneCast shortcuts");
    }

    // =====================================================================
    // menu bar (Win32 menu on the SDL window; WM_COMMAND arrives as an SDL system event)

    enum M
    {
        Connect = 1, Disconnect, Back, Home, Recents, Notifications, Quit,
        EditMap = 20, Game, Typing, Markers, SensUp, SensDown, ClearMap,
        Full = 40, Fit, ScaleFit, ScaleFill, ScaleStretch, Mute, Stats,
        Res0 = 60, Rate0 = 70,
        ShapeWhole = 80, Shape169, ShapeNormal, Sharp0 = 90, Sharp2560, Sharp3200,
        InstallUsbDk = 100, Help = 110, Pair = 111,
        DecCpu = 130, DecGpu,
        QuickSettings = 120, LockPhone, Screenshot, VolUp, VolDown, MutePhone, PowerMenu,
    }

    void BuildMenu()
    {
        menuBar = Win32.CreateMenu();
        IntPtr Sub(string title, params (M id, string text)[] items)
        {
            var m = Win32.CreatePopupMenu();
            foreach (var (id, text) in items)
                if (text == "-") Win32.AppendMenuW(m, Win32.MF_SEPARATOR, 0, null);
                else if (text.StartsWith("#")) Win32.AppendMenuW(m, Win32.MF_STRING | Win32.MF_GRAYED, 0, text[1..]);
                else Win32.AppendMenuW(m, Win32.MF_STRING, (nint)id, text);
            Win32.AppendMenuW(menuBar, Win32.MF_POPUP, m, title);
            return m;
        }
        Sub("&Device",
            (M.Connect, "Connect…\tCtrl+K"), (M.Pair, "Pair with QR code…\tCtrl+P"), (M.Disconnect, "Disconnect\tCtrl+Shift+D"), (0, "-"),
            (M.Back, "Back\tCtrl+B"), (M.Home, "Home\tCtrl+H"), (M.Recents, "Recent apps\tCtrl+R"), (M.Notifications, "Notifications\tCtrl+N"), (M.QuickSettings, "Quick settings"), (0, "-"),
            (M.VolUp, "Volume up\tCtrl+Up"), (M.VolDown, "Volume down\tCtrl+Down"), (M.MutePhone, "Mute the phone"),
            (M.Screenshot, "Screenshot on the phone"), (M.LockPhone, "Lock the phone"), (M.PowerMenu, "Power menu"), (0, "-"),
            (M.Quit, "Quit\tAlt+F4"));
        Sub("&Game",
            (M.EditMap, "Edit key map\tCtrl+E"), (M.Game, "Mouse aiming (game mode)\tCtrl+G"), (M.Typing, "Keys type text (instead of buttons)\tCtrl+T"),
            (M.Markers, "Show key markers in game mode\tCtrl+J"), (0, "-"), (M.SensUp, "Mouse-look faster\tCtrl+="), (M.SensDown, "Mouse-look slower\tCtrl+-"),
            (0, "-"), (M.ClearMap, "Clear key map"));
        Sub("&View",
            (M.Full, "Full screen\tF11"), (M.Fit, "Fit window to phone\tCtrl+0"), (0, "-"),
            (M.ScaleFit, "Fit — whole picture, black bars\tCtrl+1"), (M.ScaleFill, "Fill — no bars, crops the edges\tCtrl+2"), (M.ScaleStretch, "Stretch — no bars, distorts\tCtrl+3"),
            (0, "-"), (M.Mute, "Mute phone audio\tCtrl+M"), (M.Stats, "Show stats overlay (FPS, delay, phone heat)\tCtrl+O"));
        var q = new List<(M, string)> { (0, "#Resolution") };
        for (int i = 0; i < resolutions.Length; i++) q.Add((M.Res0 + i, resolutions[i].Item1));
        q.Add((0, "-")); q.Add((0, "#Bitrate"));
        for (int i = 0; i < bitrates.Length; i++) q.Add((M.Rate0 + i, $"{bitrates[i]} Mbit/s" + (bitrates[i] == 24 ? " (default)" : "")));
        q.Add((0, "-")); q.Add((0, "#Decoding"));
        q.Add((M.DecCpu, "Processor (default)")); q.Add((M.DecGpu, "Graphics card"));
        q.Add((0, "-")); q.Add((0, "#Phone screen shape"));
        q.Add((M.ShapeWhole, "Fit this screen — whole display")); q.Add((M.Shape169, "16:9")); q.Add((M.ShapeNormal, "Phone's normal shape"));
        q.Add((0, "#Sharpness (for the shapes above)"));
        q.Add((M.Sharp0, "Phone's own pixels (coolest)")); q.Add((M.Sharp2560, "Sharp — 2560 px wide")); q.Add((M.Sharp3200, "Sharpest — 3200 px wide (hotter)"));
        shapeMenu = Sub("&Quality", q.ToArray());
        Sub("&Help", (M.Help, "Keyboard shortcuts\tCtrl+I"));
        Win32.SetMenu(hwnd, menuBar);
        RefreshMenu();
    }

    void Check(M id, bool on) => Win32.CheckMenuItem(menuBar, (uint)id, on ? Win32.MF_CHECKED : Win32.MF_UNCHECKED);

    void RefreshMenu()
    {
        if (menuBar == IntPtr.Zero) return;
        Check(M.Game, mode == Mode.Game); Check(M.EditMap, mode == Mode.Edit); Check(M.Markers, showMarkers);
        Check(M.Typing, typing); Check(M.Mute, audio.Muted); Check(M.Stats, showStats); Check(M.Full, fullscreen);
        Check(M.ScaleFit, scale == Scale.Fit); Check(M.ScaleFill, scale == Scale.Fill); Check(M.ScaleStretch, scale == Scale.Stretch);
        int res = Settings.Int("resolution", 0);
        for (int i = 0; i < resolutions.Length; i++) Check(M.Res0 + i, resolutions[i].Item2 == res);
        for (int i = 0; i < bitrates.Length; i++) Check(M.Rate0 + i, bitrates[i] == Bitrate);
        Check(M.DecCpu, !dec.Hardware); Check(M.DecGpu, dec.Hardware);
        int sl = Settings.Int("shapeLong", 0);
        Check(M.Sharp0, sl == 0); Check(M.Sharp2560, sl == 2560); Check(M.Sharp3200, sl == 3200);
    }

    void MenuCommand(int id)
    {
        var m = (M)id;
        switch (m)
        {
            case M.Connect: ShowConnect(); break;
            case M.Pair: ShowPairing(); break;
            case M.Disconnect: Disconnect(); break;
            case M.Back: link?.Send(CT.Global, new[] { GlobalA.Back }); break;
            case M.Home: link?.Send(CT.Global, new[] { GlobalA.Home }); break;
            case M.Recents: link?.Send(CT.Global, new[] { GlobalA.Recents }); break;
            case M.Notifications: link?.Send(CT.Global, new[] { GlobalA.Notifications }); break;
            case M.QuickSettings: link?.Send(CT.Global, new[] { GlobalA.QuickSettings }); break;
            case M.VolUp: link?.Send(CT.Global, new[] { GlobalA.VolUp }); break;
            case M.VolDown: link?.Send(CT.Global, new[] { GlobalA.VolDown }); break;
            case M.MutePhone: link?.Send(CT.Global, new[] { GlobalA.Mute }); break;
            case M.Screenshot: link?.Send(CT.Global, new[] { GlobalA.Screenshot }); break;
            case M.LockPhone: link?.Send(CT.Global, new[] { GlobalA.Lock }); break;
            case M.PowerMenu: link?.Send(CT.Global, new[] { GlobalA.Power }); break;
            case M.DecCpu: case M.DecGpu:
                Settings.Set("hwDecode", m == M.DecGpu);
                dec.UseHardware(m == M.DecGpu);
                Log($"decoder: {(dec.Hardware ? "D3D11 hardware" : "software")} (menu)");
                RefreshMenu(); break;
            case M.Quit: var q = new Sdl.Event { type = Sdl.QUIT }; Sdl.SDL_PushEvent(ref q); break;
            case M.EditMap: SetMode(mode == Mode.Edit ? Mode.Normal : Mode.Edit); break;
            case M.Game: ToggleGame(); break;
            case M.Typing: typing = !typing; if (typing) ReleaseAll(); RefreshMenu(); UpdateTitle(); break;
            case M.Markers: showMarkers = !showMarkers; overlayDirty = true; RefreshMenu(); break;
            case M.SensUp: SensUp(); break;
            case M.SensDown: SensDown(); break;
            case M.ClearMap: map = new KeyMap(); map.Save(); overlayDirty = true; SetMode(Mode.Normal); break;
            case M.Full: ToggleFullScreen(); break;
            case M.Fit: FitWindow(); break;
            case M.ScaleFit: SetScale(Scale.Fit); break;
            case M.ScaleFill: SetScale(Scale.Fill); break;
            case M.ScaleStretch: SetScale(Scale.Stretch); break;
            case M.Mute: audio.Muted = !audio.Muted; if (audio.Muted) audio.Stop(); RefreshMenu(); break;
            case M.Stats: ToggleStats(); break;
            case M.InstallUsbDk: InstallUsbDk(ask: false); break;
            case M.Help: ShowShortcuts(); break;
            case >= M.Res0 and < M.Res0 + 4: Settings.Set("resolution", resolutions[id - (int)M.Res0].Item2); RefreshMenu(); SendSettings(); break;
            case >= M.Rate0 and < M.Rate0 + 4: Settings.Set("bitrate", bitrates[id - (int)M.Rate0]); RefreshMenu(); SendSettings(); break;
            case M.ShapeWhole:
                {
                    Sdl.SDL_GetDisplayBounds(Math.Max(0, Sdl.SDL_GetWindowDisplayIndex(win)), out var b);
                    SetShape(b.w, b.h); break;
                }
            case M.Shape169: SetShape(16, 9); break;
            case M.ShapeNormal: SetShape(0, 0); break;
            case M.Sharp0: case M.Sharp2560: case M.Sharp3200:
                {
                    Settings.Set("shapeLong", m == M.Sharp0 ? 0 : m == M.Sharp2560 ? 2560 : 3200);
                    RefreshMenu();
                    int last = Settings.Int("lastShapeTag", 0);
                    if (last != 0) SendShape(last >> 16, last & 0xffff);
                    break;
                }
        }
    }

    void SetShape(int w, int h) { Settings.Set("lastShapeTag", w << 16 | h); SendShape(w, h); }

    void SendShape(int w, int h)
    {
        int l = w == 0 ? 0 : Settings.Int("shapeLong", 0);
        link?.Send(CT.Resolution, new[] { (byte)(w >> 8), (byte)w, (byte)(h >> 8), (byte)h, (byte)(l >> 8), (byte)l });
    }
}
