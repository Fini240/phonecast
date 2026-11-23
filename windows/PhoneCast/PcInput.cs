using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace PhoneCast;

/// The phone controlling this PC (the phone's Mac tab, aimed at this PC): its touches, trackpad and keys become
/// Windows mouse and keyboard input (SendInput), like the Mac's MacScreen.input. Packets: see HubProto.IN_* on the
/// phone. Key codes arrive as Mac key codes; ⌘ becomes Ctrl, ⌥ Alt, ⌃ the Windows key, ⇧ Shift.
static class PcInput
{
    static bool leftDown;
    static Point lastPos;
    static double wheelRestX, wheelRestY;

    public static void Handle(byte[] b)
    {
        if (b.Length == 0) return;
        try
        {
            switch (b[0])
            {
                case 0: // move (absolute, 0..65535 of the main screen)
                    if (b.Length >= 5) MoveAbs(U16(b, 1), U16(b, 3));
                    break;
                case 1: case 2: // button down / up at a position
                    if (b.Length >= 6)
                    {
                        MoveAbs(U16(b, 2), U16(b, 4));
                        Button(b[1] == 1, b[0] == 1);
                    }
                    break;
                case 3: // scroll (pixels)
                    if (b.Length >= 5) Scroll(S16(b, 1), S16(b, 3));
                    break;
                case 4: // text (u8 mods, utf8)
                    if (b.Length >= 2)
                    {
                        var text = System.Text.Encoding.UTF8.GetString(b, 2, b.Length - 2);
                        if (b[1] != 0 && text.Length == 1) CharWithMods(text[0], b[1]);
                        else TypeText(text);
                    }
                    break;
                case 5: // key (u16 Mac key code, u8 mods)
                    if (b.Length >= 4) MacKey(U16(b, 1), b[3]);
                    break;
                case 6: // trackpad: move by dx, dy points from where the cursor is
                    if (b.Length >= 5) MoveRel(S16(b, 1), S16(b, 3));
                    break;
                case 7: // trackpad: button at the cursor (u8 button, u8 down)
                    if (b.Length >= 3) Button(b[1] == 1, b[2] == 1);
                    break;
            }
        }
        catch (Exception e) { App.Log("pcinput: " + e.Message); }
    }

    static int U16(byte[] b, int o) => b[o] << 8 | b[o + 1];
    static int S16(byte[] b, int o) => (short)(b[o] << 8 | b[o + 1]);

    // ---------- mouse ----------

    static void MoveAbs(int x, int y)
    {
        // without VIRTUALDESK, 0..65535 covers the primary screen
        Send(Mouse(x, y, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE));
        int sw = Gdi.GetSystemMetrics(0), sh = Gdi.GetSystemMetrics(1);
        lastPos = new Point(x * (sw - 1) / 65535, y * (sh - 1) / 65535);
    }

    static void MoveRel(int dx, int dy)
    {
        // Mac points -> pixels at this screen's scale; SetCursorPos keeps it exact (no Windows acceleration twice)
        double scale = Gdi.GetDpiForSystem() / 96.0;
        Gdi.GetCursorPos(out var p);
        int x = p.x + (int)Math.Round(dx * scale), y = p.y + (int)Math.Round(dy * scale);
        int vx = Gdi.GetSystemMetrics(76), vy = Gdi.GetSystemMetrics(77), vw = Gdi.GetSystemMetrics(78), vh = Gdi.GetSystemMetrics(79);
        x = Math.Clamp(x, vx, vx + vw - 1); y = Math.Clamp(y, vy, vy + vh - 1);
        Gdi.SetCursorPos(x, y);
        lastPos = new Point(x, y);
        Send(Mouse(0, 0, MOUSEEVENTF_MOVE));   // so apps that watch raw input see the move too
    }

    static void Button(bool right, bool down)
    {
        if (!right) leftDown = down;
        uint f = right ? (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP) : (down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP);
        Send(Mouse(0, 0, f));
    }

    static void Scroll(int dx, int dy)
    {
        // pixels -> wheel units (120 = one notch ≈ 3 lines ≈ 60 px); the phone sends the Mac's direction
        wheelRestY += dy * 2.0; wheelRestX += -dx * 2.0;
        int wy = (int)wheelRestY, wx = (int)wheelRestX;
        wheelRestY -= wy; wheelRestX -= wx;
        if (wy != 0) Send(Mouse(0, 0, MOUSEEVENTF_WHEEL, wy));
        if (wx != 0) Send(Mouse(0, 0, MOUSEEVENTF_HWHEEL, wx));
    }

    // ---------- keyboard ----------

    /// Mac virtual key code -> Windows virtual key.
    static readonly Dictionary<int, ushort> MacToVk = new()
    {
        [0] = 0x41, [11] = 0x42, [8] = 0x43, [2] = 0x44, [14] = 0x45, [3] = 0x46, [5] = 0x47, [4] = 0x48, [34] = 0x49, [38] = 0x4A,
        [40] = 0x4B, [37] = 0x4C, [46] = 0x4D, [45] = 0x4E, [31] = 0x4F, [35] = 0x50, [12] = 0x51, [15] = 0x52, [1] = 0x53, [17] = 0x54,
        [32] = 0x55, [9] = 0x56, [13] = 0x57, [7] = 0x58, [16] = 0x59, [6] = 0x5A,
        [29] = 0x30, [18] = 0x31, [19] = 0x32, [20] = 0x33, [21] = 0x34, [23] = 0x35, [22] = 0x36, [26] = 0x37, [28] = 0x38, [25] = 0x39,
        [36] = 0x0D, [76] = 0x0D, [48] = 0x09, [49] = 0x20, [51] = 0x08, [53] = 0x1B, [117] = 0x2E,
        [123] = 0x25, [124] = 0x27, [125] = 0x28, [126] = 0x26, [115] = 0x24, [119] = 0x23, [116] = 0x21, [121] = 0x22,
        [122] = 0x70, [120] = 0x71, [99] = 0x72, [118] = 0x73, [96] = 0x74, [97] = 0x75, [98] = 0x76, [100] = 0x77,
        [101] = 0x78, [109] = 0x79, [103] = 0x7A, [111] = 0x7B,
        [27] = 0xBD, [24] = 0xBB, [33] = 0xDB, [30] = 0xDD, [42] = 0xDC, [41] = 0xBA, [39] = 0xDE, [43] = 0xBC, [47] = 0xBE, [44] = 0xBF, [50] = 0xC0,
    };

    const ushort VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B;

    static List<ushort> Mods(byte m)
    {
        var l = new List<ushort>();
        if ((m & 1) != 0) l.Add(VK_CONTROL);   // ⌘
        if ((m & 2) != 0) l.Add(VK_MENU);      // ⌥
        if ((m & 4) != 0) l.Add(VK_LWIN);      // ⌃
        if ((m & 8) != 0) l.Add(VK_SHIFT);     // ⇧
        return l;
    }

    static void MacKey(int mac, byte mods)
    {
        if (!MacToVk.TryGetValue(mac, out var vk)) return;
        // Mac habits that mean something else on Windows
        if ((mods & 1) != 0 && vk == 0x09) { Chord(new() { VK_MENU }, 0x09); return; }            // ⌘Tab -> Alt+Tab
        if ((mods & 1) != 0 && vk == 0x51) { Chord(new() { VK_MENU }, 0x73); return; }            // ⌘Q -> Alt+F4
        if ((mods & 1) != 0 && vk == 0x20) { Chord(new(), VK_LWIN); return; }                     // ⌘Space -> Start search
        if ((mods & 1) != 0 && (vk == 0x25 || vk == 0x27)) { Chord(Mods((byte)(mods & ~1)), (ushort)(vk == 0x25 ? 0x24 : 0x23)); return; } // ⌘←/→ -> Home/End
        if ((mods & 2) != 0 && vk == 0x08) { Chord(new() { VK_CONTROL }, 0x08); return; }         // ⌥⌫ -> Ctrl+Backspace (word)
        Chord(Mods(mods), vk);
    }

    static void CharWithMods(char c, byte mods)
    {
        short r = Gdi.VkKeyScanW(char.ToLowerInvariant(c));
        if (r == -1) { TypeText(c.ToString()); return; }
        var vk = (ushort)(r & 0xff);
        var m = Mods(mods);
        if ((r & 0x100) != 0 && !m.Contains(VK_SHIFT)) m.Add(VK_SHIFT);
        if ((mods & 1) != 0 && vk == 0x51) { Chord(new() { VK_MENU }, 0x73); return; }   // ⌘Q -> Alt+F4
        Chord(m, vk);
    }

    static void Chord(List<ushort> mods, ushort vk)
    {
        var l = new List<INPUT>();
        foreach (var m in mods) l.Add(Key(m, false));
        l.Add(Key(vk, false)); l.Add(Key(vk, true));
        for (int i = mods.Count - 1; i >= 0; i--) l.Add(Key(mods[i], true));
        Send(l.ToArray());
    }

    static void TypeText(string s)
    {
        var l = new List<INPUT>();
        foreach (var ch in s)
        {
            if (ch == '\n' || ch == '\r') { l.Add(Key(0x0D, false)); l.Add(Key(0x0D, true)); continue; }
            l.Add(Unicode(ch, false)); l.Add(Unicode(ch, true));
        }
        if (l.Count > 0) Send(l.ToArray());
    }

    // ---------- buttons on the phone's Mac tab (MAC_ACTION) ----------

    /// [sendFile] sends a file to the phone (the screenshot).
    public static void Action(string a, Action<string> sendFile, Action<string> openOnPhone = null)
    {
        App.Log("pc action: " + a);
        switch (a)
        {
            case "volup": Chord(new(), 0xAF); return;
            case "voldown": Chord(new(), 0xAE); return;
            case "mute": Chord(new(), 0xAD); return;
            case "play": Chord(new(), 0xB3); return;
            case "next": Chord(new(), 0xB0); return;
            case "prev": Chord(new(), 0xB1); return;
            case "lock": Gdi.LockWorkStation(); return;
            case "displaysleep": Gdi.PostMessageW((IntPtr)0xffff, 0x0112, (IntPtr)0xF170, (IntPtr)2); return;
            case "screenshot":
                {
                    var path = Screenshot();
                    if (path != null) sendFile(path);
                    return;
                }
            case "tab":
                {
                    var url = BrowserTab.Current();
                    if (url == null) Banners.Info(tr("No browser tab found"), tr("Open the page in Chrome, Edge, Brave, Firefox or Opera on the PC first."));
                    else openOnPhone?.Invoke(url);
                    return;
                }
        }
        if (a.StartsWith("lidawake:")) { KeepAwake.Shared.Action(a[9..]); return; }
        App.Log("pc action: unknown " + a);
    }

    /// The whole desktop (all screens) to Pictures\Screenshots, like Win+PrtScn.
    public static string Screenshot()
    {
        try
        {
            var b = SystemInformation.VirtualScreen;
            using var bmp = new Bitmap(b.Width, b.Height);
            using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(b.Left, b.Top, 0, 0, bmp.Size);
            var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Screenshots");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, $"Screenshot {DateTime.Now:yyyy-MM-dd 'at' HH.mm.ss}.png");
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            return path;
        }
        catch (Exception e) { App.Log("screenshot: " + e.Message); return null; }
    }

    // ---------- SendInput ----------

    const uint MOUSEEVENTF_MOVE = 1, MOUSEEVENTF_LEFTDOWN = 2, MOUSEEVENTF_LEFTUP = 4, MOUSEEVENTF_RIGHTDOWN = 8, MOUSEEVENTF_RIGHTUP = 0x10,
        MOUSEEVENTF_WHEEL = 0x800, MOUSEEVENTF_HWHEEL = 0x1000, MOUSEEVENTF_ABSOLUTE = 0x8000;
    const uint KEYEVENTF_EXTENDEDKEY = 1, KEYEVENTF_KEYUP = 2, KEYEVENTF_UNICODE = 4;

    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public int mouseData; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion u; }

    static INPUT Mouse(int x, int y, uint flags, int data = 0) =>
        new() { type = 0, u = new InputUnion { mi = new MOUSEINPUT { dx = x, dy = y, dwFlags = flags, mouseData = data } } };

    static readonly HashSet<ushort> Extended = new() { 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x5B, 0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB3 };

    static INPUT Key(ushort vk, bool up) =>
        new() { type = 1, u = new InputUnion { ki = new KEYBDINPUT { wVk = vk, wScan = (ushort)Gdi.MapVirtualKeyW(vk, 0),
            dwFlags = (up ? KEYEVENTF_KEYUP : 0) | (Extended.Contains(vk) ? KEYEVENTF_EXTENDEDKEY : 0) } } };

    static INPUT Unicode(char c, bool up) =>
        new() { type = 1, u = new InputUnion { ki = new KEYBDINPUT { wScan = c, dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0) } } };

    static void Send(params INPUT[] i) => SendInput((uint)i.Length, i, Marshal.SizeOf<INPUT>());
    [DllImport("user32", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
}

/// Win32 bits for PcScreen and PcInput.
static class Gdi
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public POINT ptScreenPos; }
    [StructLayout(LayoutKind.Sequential)] public struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFO { public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }

    [DllImport("user32")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32")] public static extern uint GetDpiForSystem();
    [DllImport("user32")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32")] public static extern bool GetIconInfo(IntPtr icon, out ICONINFO ii);
    [DllImport("user32")] public static extern bool DrawIconEx(IntPtr dc, int x, int y, IntPtr icon, int w, int h, int step, IntPtr brush, int flags);
    [DllImport("user32")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("user32")] public static extern short VkKeyScanW(char c);
    [DllImport("user32")] public static extern uint MapVirtualKeyW(uint code, uint type);
    [DllImport("user32")] public static extern bool LockWorkStation();
    [DllImport("user32")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("gdi32")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32")] public static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32")] public static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);
    [DllImport("gdi32")] public static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFO bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
}
