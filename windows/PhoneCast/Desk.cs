using System.Collections.Concurrent;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace PhoneCast;

/// "Shared keyboard & mouse" with the linked Mac (the Windows half of the Mac's Desk.swift; Tether built in).
/// Push the pointer over the desktop edge that faces the Mac and this PC's keyboard and mouse drive the Mac; the
/// Mac's come over here the same way. The PC dials the Mac directly on TCP 27196 (the Mac's addresses and a shared
/// secret come from the phone's STATUS, "desk"); both prove the secret, then every event is AES-GCM encrypted.
///
/// Capture: low-level hooks swallow input while the pointer is on the Mac; Raw Input supplies the mouse's own
/// movement, because hook positions are clamped at the desktop edge (Tether's lesson). Injection: SendInput with
/// scan codes, marked in dwExtraInfo so our own hooks let it through.
sealed class Desk
{
    public static readonly Desk Shared = new();
    const int Port = 27196;

    public enum St { Off, Waiting, Local, Sending, Receiving }
    public volatile St State = St.Off;
    public string MacName = "Mac";
    public bool Enabled { get => Settings.Bool("deskEnabled", true); set { Settings.Set("deskEnabled", value); Changed(); } }
    public string Summary => State switch
    {
        St.Off => tr("Off"),
        St.Waiting => tr("Looking for the Mac…"),
        St.Local => tr("Connected to {0}", MacName),
        St.Sending => tr("Keyboard and mouse are on {0}", MacName),
        _ => tr("{0}'s keyboard and mouse are on this PC", MacName),
    };

    byte[] key;
    string[] macAddrs = Array.Empty<string>();
    TcpClient tcp;
    NetworkStream ns;
    AesGcm aes;
    long sendCounter, recvCounter;
    readonly object sendLock = new();
    bool pcIsRightOfMac = true, swap = true;
    Thread loop;

    // ---------- setup ----------

    /// The phone's STATUS (UI thread).
    public void Update(JsonObject phone)
    {
        // PHONECAST_DESK_TEST=<base64 key>|<Mac address> (tests without the phone handing out the secret)
        if (Environment.GetEnvironmentVariable("PHONECAST_DESK_TEST") is string test && test.Contains('|'))
        {
            var p = test.Split('|');
            key = Convert.FromBase64String(p[0]); macAddrs = new[] { p[1] };
            Start(); return;
        }
        if (phone["desk"] is not JsonObject d) return;
        try { key = Convert.FromBase64String((string)d["key"] ?? ""); } catch { key = null; }
        macAddrs = (d["peers"] as JsonArray)?.OfType<JsonObject>().Where(p => (string)p["os"] == "mac")
            .SelectMany(p => (p["lan"] as JsonArray)?.Select(x => (string)x) ?? Enumerable.Empty<string>()).Where(x => x != null).ToArray() ?? Array.Empty<string>();
        if ((string)(d["peers"] as JsonArray)?.OfType<JsonObject>().FirstOrDefault(p => (string)p["os"] == "mac")?["name"] is string n) MacName = n;
        Start();
    }

    void Start()
    {
        if (loop != null) return;
        loop = new Thread(Loop) { IsBackground = true, Name = "desk" };
        loop.Start();
    }

    void Changed() => Ui.Post(() => Store.Shared.Fire("pc"));

    void Loop()
    {
        while (true)
        {
            if (!Enabled || key == null || macAddrs.Length == 0)
            {
                if (State != St.Off) { State = St.Off; Changed(); }
                Thread.Sleep(2000); continue;
            }
            if (State == St.Off) { State = St.Waiting; Changed(); }
            foreach (var a in macAddrs.OrderBy(x => x.StartsWith("100.") ? 1 : 0))   // the home network before Tailscale
            {
                if (!Enabled) break;
                try { Session(a); } catch (Exception e) { App.Log($"desk: {a}: {e.Message}"); }
                Cleanup();
            }
            Thread.Sleep(5000);
        }
    }

    void Session(string addr)
    {
        var c = new TcpClient { NoDelay = true };
        var t = c.ConnectAsync(addr, Port);
        if (!t.Wait(2500) || !c.Connected) { c.Dispose(); throw new Exception("no answer"); }
        tcp = c; ns = c.GetStream();
        ns.ReadTimeout = 10000;
        var nP = RandomNumberGenerator.GetBytes(16);
        ns.Write(Encoding.ASCII.GetBytes("PCDK").Concat(new byte[] { 1 }).Concat(nP).ToArray());
        var r = ReadN(16 + 32);
        var nM = r[..16];
        if (!CryptographicOperations.FixedTimeEquals(r[16..], Mac("mac", nP, nM))) throw new Exception("the Mac didn't prove the secret");
        var name = new byte[64];
        var nb = Encoding.UTF8.GetBytes(Environment.MachineName); Array.Copy(nb, name, Math.Min(64, nb.Length));
        ns.Write(Mac("pc", nP, nM).Concat(name).ToArray());
        aes = new AesGcm(Mac("session", nP, nM), 16);
        sendCounter = recvCounter = 0;
        ns.ReadTimeout = Timeout.Infinite;
        App.Log($"desk: connected to {MacName} at {addr}");
        State = St.Local; Changed();
        Capture.Start();
        while (true)
        {
            var h = ReadN(2);
            var body = ReadN(h[0] << 8 | h[1]);
            var nonce = new byte[12]; nonce[0] = 1; BitConverter.GetBytes(recvCounter++).Reverse().ToArray().CopyTo(nonce, 4);
            var plain = new byte[body.Length - 16];
            aes.Decrypt(nonce, body[..^16], body[^16..], plain);
            Handle(plain);
        }
    }

    byte[] Mac(string label, byte[] a, byte[] b) => HMACSHA256.HashData(key, Encoding.ASCII.GetBytes(label).Concat(a).Concat(b).ToArray());

    byte[] ReadN(int n)
    {
        var b = new byte[n];
        for (int o = 0; o < n;) { int r = ns.Read(b, o, n - o); if (r <= 0) throw new IOException("closed"); o += r; }
        return b;
    }

    void Cleanup()
    {
        var was = State;
        try { tcp?.Close(); } catch { }
        tcp = null; ns = null; aes?.Dispose(); aes = null;
        if (was == St.Sending || was == St.Receiving) ReleaseAll();
        if (State != St.Off) State = Enabled ? St.Waiting : St.Off;
        if (was != St.Waiting && was != St.Off) { App.Log("desk: disconnected"); Changed(); }
    }

    /// Any thread.
    void Send(params byte[] msg)
    {
        lock (sendLock)
        {
            if (ns == null || aes == null) return;
            var nonce = new byte[12]; nonce[0] = 2; BitConverter.GetBytes(sendCounter++).Reverse().ToArray().CopyTo(nonce, 4);
            var ct = new byte[msg.Length]; var tag = new byte[16];
            aes.Encrypt(nonce, msg, ct, tag);
            var f = new byte[2 + ct.Length + 16];
            f[0] = (byte)((ct.Length + 16) >> 8); f[1] = (byte)(ct.Length + 16);
            ct.CopyTo(f, 2); tag.CopyTo(f, 2 + ct.Length);
            try { ns.Write(f); } catch { }
        }
    }

    // message types (same as Desk.swift)
    const byte Hello = 0, Enter = 1, Leave = 2, Move = 3, Button = 4, Wheel = 5, Key = 6, ReleaseAllMsg = 7;

    static byte[] F32(double v) { var b = BitConverter.GetBytes((float)v); Array.Reverse(b); return b; }
    static double ReadF32(byte[] m, int o) { var b = m[o..(o + 4)]; Array.Reverse(b); return BitConverter.ToSingle(b); }
    static byte[] I16(int v) { short s = (short)Math.Clamp(v, short.MinValue, short.MaxValue); return new[] { (byte)(s >> 8), (byte)s }; }
    static int ReadI16(byte[] m, int o) => (short)(m[o] << 8 | m[o + 1]);

    // ---------- the Mac's messages (desk thread) ----------

    void Handle(byte[] m)
    {
        if (m.Length == 0) return;
        switch (m[0])
        {
            case Hello when m.Length >= 3:
                pcIsRightOfMac = m[1] == 1; swap = m[2] == 1;
                break;
            case Enter:   // the Mac's pointer came over: this PC is driven by the Mac now
                {
                    App.Log("desk: the Mac's pointer came over");
                    if (State == St.Sending) Capture.Release(null);
                    State = St.Receiving;
                    var d = Desktop();
                    int x = pcIsRightOfMac ? d.Left + 1 : d.Right - 2;
                    Inject.MoveTo(x, d.Top + (int)(ReadF32(m, 1) * (d.Height - 1)));
                    Changed();
                    break;
                }
            case Leave:   // our pointer came back from the Mac
                {
                    if (State != St.Sending) break;
                    App.Log("desk: pointer back from the Mac");
                    State = St.Local;
                    var d = Desktop();
                    Capture.Release(new System.Drawing.Point(pcIsRightOfMac ? d.Left + 2 : d.Right - 3, d.Top + (int)(ReadF32(m, 1) * (d.Height - 1))));
                    Changed();
                    break;
                }
            case Move when State == St.Receiving && m.Length >= 5: InjectMove(ReadI16(m, 1), ReadI16(m, 3)); break;
            case Button when State == St.Receiving && m.Length >= 3: Inject.Button(m[1], m[2] == 1); break;
            case Wheel when State == St.Receiving && m.Length >= 5: Inject.Wheel(ReadI16(m, 1), ReadI16(m, 3)); break;
            case Key when State == St.Receiving && m.Length >= 4:
                {
                    int hid = m[1] << 8 | m[2];
                    if (swap) hid = hid switch { 0xE0 => 0xE3, 0xE3 => 0xE0, 0xE4 => 0xE7, 0xE7 => 0xE4, _ => hid };
                    Inject.Key(hid, m[3] == 1);
                    break;
                }
            case ReleaseAllMsg: ReleaseAll(); break;
        }
    }

    static System.Drawing.Rectangle Desktop() => SystemInformation.VirtualScreen;

    /// Mac points -> pixels here (a little faster, the PC's desktop is wider).
    void InjectMove(int dx, int dy)
    {
        double gain = 1.5;
        Inject.GetCursorPos(out var p);
        var d = Desktop();
        int x = p.X + (int)Math.Round(dx * gain), y = Math.Clamp(p.Y + (int)Math.Round(dy * gain), d.Top, d.Bottom - 1);
        // over the edge that faces the Mac: back to the Mac
        if (pcIsRightOfMac ? x < d.Left : x > d.Right - 1)
        {
            App.Log("desk: the Mac's pointer went back");
            State = St.Local;
            ReleaseAll();
            Send(new byte[] { Leave }.Concat(F32((double)(y - d.Top) / Math.Max(1, d.Height - 1))).ToArray());
            Changed();
            return;
        }
        Inject.MoveTo(Math.Clamp(x, d.Left, d.Right - 1), y);
    }

    void ReleaseAll() => Inject.ReleaseAll();

    // ---------- capture (hook thread): this PC's keyboard and mouse to the Mac ----------

    /// Called by Capture on the hook thread.
    bool AtMacEdge(int dx)
    {
        if (State != St.Local || ns == null) return false;
        Inject.GetCursorPos(out var p);
        var d = Desktop();
        return pcIsRightOfMac ? p.X <= d.Left && dx < 0 : p.X >= d.Right - 1 && dx > 0;
    }

    void BeginSending()
    {
        Inject.GetCursorPos(out var p);
        var d = Desktop();
        State = St.Sending;
        App.Log("desk: pointer -> the Mac");
        Send(new byte[] { Enter }.Concat(F32((double)(p.Y - d.Top) / Math.Max(1, d.Height - 1))).ToArray());
        Changed();
    }

    static class Capture
    {
        static Thread thread;
        static IntPtr mouseHook, keyHook;
        static HookProc mouseProc, keyProc;   // kept alive: the hooks call into them
        static RawWindow raw;
        static readonly HashSet<int> held = new();
        static double restX, restY;

        public static void Start()
        {
            if (thread != null) return;
            thread = new Thread(() =>
            {
                mouseProc = MouseHook; keyProc = KeyHook;
                var mod = GetModuleHandle(null);
                mouseHook = SetWindowsHookEx(14 /* WH_MOUSE_LL */, mouseProc, mod, 0);
                keyHook = SetWindowsHookEx(13 /* WH_KEYBOARD_LL */, keyProc, mod, 0);
                App.Log($"desk: hooks {(mouseHook != IntPtr.Zero && keyHook != IntPtr.Zero ? "on" : "FAILED")}");
                Application.Run();
            }) { IsBackground = true, Name = "desk-hooks" };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        /// Give the pointer back to this PC (optionally placing it).
        public static void Release(System.Drawing.Point? at)
        {
            armed = false;
            if (at is { } p) Inject.MoveTo(p.X, p.Y);
            lock (held) held.Clear();
            Shared.Send(ReleaseAllMsg);
        }

        static bool Ours(IntPtr extra) => extra == Inject.Mark;

        static IntPtr MouseHook(int code, IntPtr w, IntPtr l)
        {
            if (code >= 0)
            {
                var m = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(l);
                int msg = (int)w;
                if (!Ours(m.dwExtraInfo) && Shared.State == St.Local && msg == 0x0200) EdgeCheck(m.x, m.y);
                if (!Ours(m.dwExtraInfo) && Shared.State == St.Sending)
                {
                    switch (msg)
                    {
                        case 0x0200:   // the would-be position minus where the pointer is parked = the movement
                            {
                                int dx = m.x - parked.X, dy = m.y - parked.Y;
                                // a position from before the pointer was parked: not a movement
                                if (Math.Abs(dx) > 400 || Math.Abs(dy) > 400) break;
                                if (dx != 0 || dy != 0) Shared.Send(new byte[] { Move }.Concat(I16(dx)).Concat(I16(dy)).ToArray());
                                break;
                            }
                        case 0x0201: case 0x0202: Shared.Send(Button, 0, (byte)(msg == 0x0201 ? 1 : 0)); break;
                        case 0x0204: case 0x0205: Shared.Send(Button, 1, (byte)(msg == 0x0204 ? 1 : 0)); break;
                        case 0x0207: case 0x0208: Shared.Send(Button, 2, (byte)(msg == 0x0207 ? 1 : 0)); break;
                        case 0x020B: case 0x020C:
                            Shared.Send(Button, (byte)((m.mouseData >> 16) == 1 ? 3 : 4), (byte)(msg == 0x020B ? 1 : 0)); break;
                        case 0x020A: Shared.Send(new byte[] { Wheel }.Concat(I16(0)).Concat(I16((short)(m.mouseData >> 16))).ToArray()); break;
                        case 0x020E: Shared.Send(new byte[] { Wheel }.Concat(I16(-(short)(m.mouseData >> 16))).Concat(I16(0)).ToArray()); break;
                    }
                    return (IntPtr)1;   // swallowed: the pointer is on the Mac
                }
            }
            return CallNextHookEx(IntPtr.Zero, code, w, l);
        }

        static IntPtr KeyHook(int code, IntPtr w, IntPtr l)
        {
            if (code >= 0)
            {
                var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(l);
                if (!Ours(k.dwExtraInfo) && Shared.State == St.Sending)
                {
                    bool down = (int)w == 0x0100 || (int)w == 0x0104;
                    int sc = (int)k.scanCode | ((k.flags & 1) != 0 ? 0xE000 : 0);
                    if (k.vkCode == 0x5B) sc = 0xE05B; else if (k.vkCode == 0x5C) sc = 0xE05C;
                    if (DeskKeys.Hid(sc) is int hid)
                    {
                        lock (held) { if (down) held.Add(hid); else held.Remove(hid); }
                        Shared.Send(Key, (byte)(hid >> 8), (byte)hid, (byte)(down ? 1 : 0));
                    }
                    return (IntPtr)1;
                }
            }
            return CallNextHookEx(IntPtr.Zero, code, w, l);
        }

        static int lastX = int.MinValue, lastY, edgeHits;
        public static bool armed = true;
        static System.Drawing.Point parked;

        /// The pointer pressed against the edge that faces the Mac: Windows keeps reporting the same edge pixel while
        /// the mouse keeps moving (outward); sliding along the edge changes y and doesn't count.
        static void EdgeCheck(int x, int y)
        {
            var d = Desktop();
            bool atEdge = Shared.pcIsRightOfMac ? x <= d.Left : x >= d.Right - 1;
            // just came back over this edge: only cross again once the pointer has been away from it
            if (!armed) { if (Shared.pcIsRightOfMac ? x > d.Left + 20 : x < d.Right - 21) armed = true; lastX = x; lastY = y; return; }
            if (atEdge && x == lastX && Math.Abs(y - lastY) <= 2) edgeHits++; else edgeHits = 0;
            lastX = x; lastY = y;
            if (edgeHits >= 2 && Shared.ns != null)
            {
                edgeHits = 0;
                Shared.BeginSending();
                // park the pointer in the middle of the main screen: half a screen of room in every direction
                var b = Screen.PrimaryScreen.Bounds;
                parked = new System.Drawing.Point(b.Left + b.Width / 2, b.Top + b.Height / 2);
                Inject.MoveTo(parked.X, parked.Y);
            }
        }

        /// Raw mouse movement (hook thread).
        static int rawCount;
        public static void RawMove(int dx, int dy)
        {
            if (rawCount++ % 200 == 0) { Inject.GetCursorPos(out var cp); App.Log($"desk: raw #{rawCount} dx {dx} at {cp.X},{cp.Y} state {Shared.State}"); }
            if (Shared.State == St.Sending)
            {
                // device counts, no Windows acceleration: add a gentle one so big moves cross the Mac's screen
                double v = Math.Sqrt(dx * dx + dy * dy), gain = 1 + Math.Min(v, 40) / 25;
                restX += dx * gain; restY += dy * gain;
                int x = (int)restX, y = (int)restY; restX -= x; restY -= y;
                if (x != 0 || y != 0) Shared.Send(new byte[] { Move }.Concat(I16(x)).Concat(I16(y)).ToArray());
            }
            else if (dx != 0 && Shared.AtMacEdge(dx)) Shared.BeginSending();
        }

        static int wmInput;
        sealed class RawWindow : NativeWindow
        {
            public RawWindow()
            {
                CreateHandle(new CreateParams());
                var rid = new RAWINPUTDEVICE { usUsagePage = 1, usUsage = 2, dwFlags = 0x100 /* RIDEV_INPUTSINK */, hwndTarget = Handle };
                bool ok = RegisterRawInputDevices(new[] { rid }, 1, (uint)Marshal.SizeOf<RAWINPUTDEVICE>());
                App.Log($"desk: raw input {(ok ? "on" : "FAILED " + Marshal.GetLastWin32Error())}");
            }

            protected override void WndProc(ref Message m)
            {
                if (m.Msg == 0x00FF /* WM_INPUT */)
                {
                    if (wmInput++ % 200 == 0) App.Log($"desk: WM_INPUT #{wmInput}");
                    uint size = 0;
                    int hdr = Marshal.SizeOf<RAWINPUTHEADER>();
                    GetRawInputData(m.LParam, 0x10000003, IntPtr.Zero, ref size, (uint)hdr);
                    var buf = Marshal.AllocHGlobal((int)size);
                    try
                    {
                        if (GetRawInputData(m.LParam, 0x10000003, buf, ref size, (uint)hdr) == size)
                        {
                            var h = Marshal.PtrToStructure<RAWINPUTHEADER>(buf);
                            if (wmInput < 3) { var mm = Marshal.PtrToStructure<RAWMOUSE>(buf + hdr); App.Log($"desk: raw type {h.dwType} flags {mm.usFlags} dx {mm.lLastX} extra {mm.ulExtraInformation:X}"); }
                            if (h.dwType == 0)   // mouse
                            {
                                var mouse = Marshal.PtrToStructure<RAWMOUSE>(buf + hdr);
                                // relative movement from a real mouse (not our own SendInput, not absolute tablets)
                                if ((mouse.usFlags & 1) == 0 && mouse.ulExtraInformation != (uint)Inject.Mark) RawMove(mouse.lLastX, mouse.lLastY);
                            }
                        }
                    }
                    finally { Marshal.FreeHGlobal(buf); }
                }
                base.WndProc(ref m);
            }
        }

        delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
        [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public int x, y, mouseData, flags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort usUsagePage, usUsage; public uint dwFlags; public IntPtr hwndTarget; }
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUTHEADER { public uint dwType, dwSize; public IntPtr hDevice, wParam; }
        [StructLayout(LayoutKind.Sequential)] struct RAWMOUSE { public ushort usFlags; public ushort pad; public ushort usButtonFlags, usButtonData; public uint ulRawButtons; public int lLastX, lLastY; public uint ulExtraInformation; }
        [DllImport("user32", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint thread);
        [DllImport("user32")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
        [DllImport("kernel32")] static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint size);
        [DllImport("user32")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint hdr);
    }

    // ---------- injection: the Mac drives this PC ----------

    static class Inject
    {
        public static readonly IntPtr Mark = (IntPtr)0x50434453;   // "PCDS": our own SendInput, so our hooks let it pass
        static readonly HashSet<int> keys = new();
        static readonly HashSet<int> buttons = new();

        public static void MoveTo(int x, int y)
        {
            var d = SystemInformation.VirtualScreen;
            // 0..65535 over the virtual desktop; the -1 keeps the far edge reachable
            int ax = (int)((x - d.Left) * 65535L / Math.Max(1, d.Width - 1)), ay = (int)((y - d.Top) * 65535L / Math.Max(1, d.Height - 1));
            Send(MouseIn(ax, ay, 0x0001 | 0x8000 | 0x4000 /* MOVE | ABSOLUTE | VIRTUALDESK */));
        }

        public static void Button(int b, bool down)
        {
            if (down) buttons.Add(b); else buttons.Remove(b);
            uint f; int data = 0;
            switch (b)
            {
                case 0: f = down ? 0x0002u : 0x0004u; break;
                case 1: f = down ? 0x0008u : 0x0010u; break;
                case 2: f = down ? 0x0020u : 0x0040u; break;
                default: f = down ? 0x0080u : 0x0100u; data = b == 3 ? 1 : 2; break;   // XBUTTON1 back, XBUTTON2 forward
            }
            Send(MouseIn(0, 0, f, data));
        }

        public static void Wheel(int dx, int dy)
        {
            if (dy != 0) Send(MouseIn(0, 0, 0x0800, dy));
            if (dx != 0) Send(MouseIn(0, 0, 0x1000, -dx));
        }

        public static void Key(int hid, bool down)
        {
            if (DeskKeys.Scan(hid) is not int sc) return;
            if (down) keys.Add(hid); else keys.Remove(hid);
            uint f = 0x0008 /* SCANCODE */ | (down ? 0u : 0x0002u) | ((sc & 0xE000) != 0 ? 0x0001u : 0u);
            Send(new INPUT { type = 1, u = new InputUnion { ki = new KEYBDINPUT { wScan = (ushort)(sc & 0xFF), dwFlags = f, dwExtraInfo = Mark } } });
        }

        public static void ReleaseAll()
        {
            foreach (var k in keys.ToList()) Key(k, false);
            foreach (var b in buttons.ToList()) Button(b, false);
        }

        static INPUT MouseIn(int x, int y, uint f, int data = 0) =>
            new() { type = 0, u = new InputUnion { mi = new MOUSEINPUT { dx = x, dy = y, dwFlags = f, mouseData = data, dwExtraInfo = Mark } } };

        static void Send(INPUT i) => SendInput(1, new[] { i }, Marshal.SizeOf<INPUT>());

        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
        [DllImport("user32")] public static extern bool GetCursorPos(out POINT p);
        [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public int mouseData; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }
        [DllImport("user32", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    }
}

/// USB HID usage <-> PS/2 set-1 scan code (from Tether; 0xE0xx = extended), plus the ISO <> key.
static class DeskKeys
{
    static readonly Dictionary<int, int> toScan = new()
    {
        [0x04] = 0x1E, [0x05] = 0x30, [0x06] = 0x2E, [0x07] = 0x20, [0x08] = 0x12, [0x09] = 0x21, [0x0A] = 0x22, [0x0B] = 0x23, [0x0C] = 0x17, [0x0D] = 0x24,
        [0x0E] = 0x25, [0x0F] = 0x26, [0x10] = 0x32, [0x11] = 0x31, [0x12] = 0x18, [0x13] = 0x19, [0x14] = 0x10, [0x15] = 0x13, [0x16] = 0x1F, [0x17] = 0x14,
        [0x18] = 0x16, [0x19] = 0x2F, [0x1A] = 0x11, [0x1B] = 0x2D, [0x1C] = 0x15, [0x1D] = 0x2C, [0x1E] = 0x2, [0x1F] = 0x3, [0x20] = 0x4, [0x21] = 0x5,
        [0x22] = 0x6, [0x23] = 0x7, [0x24] = 0x8, [0x25] = 0x9, [0x26] = 0xA, [0x27] = 0xB, [0x28] = 0x1C, [0x29] = 0x1, [0x2A] = 0xE, [0x2B] = 0xF,
        [0x2C] = 0x39, [0x2D] = 0xC, [0x2E] = 0xD, [0x2F] = 0x1A, [0x30] = 0x1B, [0x31] = 0x2B, [0x33] = 0x27, [0x34] = 0x28, [0x35] = 0x29, [0x36] = 0x33,
        [0x37] = 0x34, [0x38] = 0x35, [0x39] = 0x3A, [0x3A] = 0x3B, [0x3B] = 0x3C, [0x3C] = 0x3D, [0x3D] = 0x3E, [0x3E] = 0x3F, [0x3F] = 0x40, [0x40] = 0x41,
        [0x41] = 0x42, [0x42] = 0x43, [0x43] = 0x44, [0x44] = 0x57, [0x45] = 0x58, [0x46] = 0xE037, [0x47] = 0x46, [0x49] = 0xE052, [0x4A] = 0xE047,
        [0x4B] = 0xE049, [0x4C] = 0xE053, [0x4D] = 0xE04F, [0x4E] = 0xE051, [0x4F] = 0xE04D, [0x50] = 0xE04B, [0x51] = 0xE050, [0x52] = 0xE048, [0x64] = 0x56,
        [0xE0] = 0x1D, [0xE1] = 0x2A, [0xE2] = 0x38, [0xE3] = 0xE05B, [0xE4] = 0xE01D, [0xE5] = 0x36, [0xE6] = 0xE038, [0xE7] = 0xE05C,
    };
    static readonly Dictionary<int, int> toHid = toScan.ToDictionary(kv => kv.Value, kv => kv.Key);
    public static int? Scan(int hid) => toScan.TryGetValue(hid, out var s) ? s : null;
    public static int? Hid(int scan) => toHid.TryGetValue(scan, out var h) ? h : null;
}
