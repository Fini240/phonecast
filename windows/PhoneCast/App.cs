using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Net;
using System.Text;
using FFmpeg.AutoGen;

namespace PhoneCast;

enum Mode { Normal, Game, Edit }
enum Scale { Fit = 0, Fill = 1, Stretch = 2 }

sealed unsafe partial class App
{
    // ---------- window / rendering ----------
    IntPtr win, ren, hwnd, menuBar, shapeMenu;
    IntPtr videoTex, overlayTex;
    uint videoFmt; int texW, texH;
    int outW, outH;
    Bitmap overlayBmp;
    bool overlayDirty = true, hasOverlay, needRender = true, fullscreen;
    uint wakeEvent;
    int wakePending;

    // ---------- media / connection ----------
    readonly H264Decoder dec;
    readonly AudioSink audio = new();
    readonly MdnsBrowser mdns = new();
    Link link;
    UdpVideoIn udp;
    bool udpActive;
    double udpOnAt;
    readonly ConcurrentQueue<(byte type, byte[] p, Link from)> videoQ = new();
    readonly ConcurrentQueue<Action> mainQ = new();

    int videoW = 1080, videoH = 2340;
    bool sizedOnce;
    bool controlAvailable;
    string stateText = "Not connected", deviceLabel = "", message = "Not connected\nCtrl+K to connect";
    bool wantConnected, viaUSB, usbBusy, linkWasReady;
    double usbRetryAt, retryDelay = 2, lastPong, rttMs, lastFrameAt;
    int wifiIndex, fps, lastFrames, resyncs;
    readonly List<double> stutters = new();
    Health health;
    sealed class Health { public double TempC, Watts; public int Battery, Thermal, Headroom; public bool Plugged; public double? CpuC, GpuC; }

    // ---------- input ----------
    Mode mode = Mode.Normal;
    Scale scale = (Scale)Settings.Int("scale", 0);
    bool typing, showMarkers = true, showStats = Settings.Bool("statsOverlay", false);
    KeyMap map = KeyMap.Load("").map;
    bool leftDown, scrolling;
    NPoint scrollPos = new(0, 0);
    double scrollLastAt;
    readonly Dictionary<string, byte> held = new();
    readonly List<byte> freeIds = new() { 2, 3, 4, 5, 6, 7, 8 };
    readonly HashSet<int> joyKeys = new();
    bool joyDown, lookDown;
    NPoint lookPos = new(0, 0), joyTarget, pending, hover;
    double lookHoldUntil;
    bool lookFlushPending;
    readonly Dictionary<string, double> pressedAt = new();
    string dragging;
    double suppressTextUntil;
    const byte JoyId = 1, LookId = 9, MouseId = 0, ScrollId = 8;
    const double MinPress = 0.06;
    static readonly Dictionary<int, (double, double)> Wasd = new() { [26] = (0, -1), [4] = (-1, 0), [22] = (0, 1), [7] = (1, 0) };
    static readonly int[] WasdKeys = { 26, 4, 22, 7 };
    static readonly Dictionary<int, int> Canonical = new() { [229] = 225, [228] = 224, [230] = 226 };

    // ---------- timers ----------
    readonly List<(double due, Action a)> timers = new();
    static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;
    void After(double s, Action a) => timers.Add((Now + s, a));

    static readonly string LogPath = Path.Combine(Settings.LogDir, "phonecast.log");
    static readonly string LagLog = Path.Combine(Settings.LogDir, "lag.log");
    public static void Log(string s)
    {
        try { File.AppendAllText(LogPath, $"{DateTime.Now:HH:mm:ss.fff} {s}\n"); } catch { }
    }

    static readonly bool NoUsb = Environment.GetEnvironmentVariable("PHONECAST_NO_USB") != null;
    static readonly string TestHost = Environment.GetEnvironmentVariable("PHONECAST_TEST_HOST");

    readonly (string, int)[] resolutions = { ("Match this screen (sharpest)", 0), ("1440p", 1440), ("1080p", 1080), ("720p (fastest)", 720) };
    readonly int[] bitrates = { 8, 16, 24, 40 };
    int Bitrate { get { int b = Settings.Int("bitrate", 0); return b == 0 ? 24 : b; } }

    public App()
    {
        try { if (new FileInfo(LogPath).Length > 4 << 20) File.Delete(LogPath); } catch { }
        Log("---- PhoneCast for Windows starting");
        ffmpeg.RootPath = AppContext.BaseDirectory;
        dec = new H264Decoder();
        dec.OnNeedKeyframe = () => link?.Send(CT.Keyframe);
        Log($"decoder: {(dec.Hardware ? "D3D11 hardware" : "software")}");
    }

    // =====================================================================
    public void Run()
    {
        Win32.timeBeginPeriod(1);
        Sdl.Hint("SDL_WINDOWS_DPI_AWARENESS", "permonitorv2");
        Sdl.Hint("SDL_RENDER_DRIVER", "direct3d11");
        Sdl.Hint("SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS", "0");
        Sdl.Hint("SDL_MOUSE_FOCUS_CLICKTHROUGH", "1");
        Sdl.Hint("SDL_MOUSE_RELATIVE_MODE_CENTER", "1");
        Sdl.Hint("SDL_WINDOWS_NO_CLOSE_ON_ALT_F4", "1");
        if (Sdl.SDL_Init(Sdl.INIT_VIDEO | Sdl.INIT_AUDIO | Sdl.INIT_EVENTS) != 0) { System.Windows.Forms.MessageBox.Show("SDL failed: " + Sdl.Error); return; }
        int w = Settings.Int("winW", 420), h = Settings.Int("winH", 860);
        int x = Settings.Has("winX") ? Settings.Int("winX") : Sdl.WINDOWPOS_CENTERED, y = Settings.Has("winY") ? Settings.Int("winY") : Sdl.WINDOWPOS_CENTERED;
        win = Sdl.CreateWindow("PhoneCast", x, y, w, h, Sdl.WINDOW_RESIZABLE | Sdl.WINDOW_HIDDEN);
        hwnd = Sdl.Hwnd(win);
        Sdl.SDL_SetWindowMinimumSize(win, 200, 200);
        BuildMenu();
        WindowIcon(false);
        Sdl.SDL_ShowWindow(win);
        After(5, () => Updater.Check(new HwndOwner(hwnd), quiet: true));   // once at start, only speaks up if there is an update
        ren = Sdl.SDL_CreateRenderer(win, -1, Sdl.RENDERER_ACCELERATED);
        Sdl.SDL_RenderSetVSync(ren, 0);
        Sdl.SDL_EventState(Sdl.SYSWMEVENT, 1);
        wakeEvent = Sdl.SDL_RegisterEvents(1);
        Sdl.SDL_StartTextInput();
        Log($"window {w}x{h}, hwnd {hwnd}, renderer {(ren != IntPtr.Zero ? "ok" : Sdl.Error)}");

        mdns.Start();
        double nextFps = Now + 1, nextPing = Now + 0.5, nextCable = Now + 3, nextLog = Now + 5, nextHub = Now + 2;
        UpdateTray();
        double autoExit = double.TryParse(Environment.GetEnvironmentVariable("PHONECAST_AUTOEXIT"), out var ae) ? Now + ae : 0;
        if (Settings.Str("pin") != null && WifiCandidates().Count > 0) After(1.2, ConnectSaved);
        else After(1.2, () => ShowConnect());
        bool quit = false;
        while (!quit)
        {
            double now = Now;
            double nextDue = timers.Count > 0 ? timers.Min(t => t.due) : now + 0.01;
            int wait = (int)Math.Clamp((nextDue - now) * 1000, 0, 10);
            if (Sdl.SDL_WaitEventTimeout(out var e, wait) == 1)
            {
                do { if (!HandleEvent(ref e)) quit = true; } while (Sdl.SDL_PollEvent(out e) == 1);
            }
            Interlocked.Exchange(ref wakePending, 0);
            while (mainQ.TryDequeue(out var a)) { try { a(); } catch (Exception ex) { Log("main: " + ex); } }
            DrainVideo();
            now = Now;
            if (timers.Count > 0)
            {
                var due = timers.Where(t => t.due <= now).ToList();
                timers.RemoveAll(t => t.due <= now);
                foreach (var t in due) { try { t.a(); } catch (Exception ex) { Log("timer: " + ex); } }
            }
            if (scrolling && now - scrollLastAt > 0.06) { Send(TouchA.Up, ScrollId, scrollPos); scrolling = false; }
            if (now >= nextFps) { nextFps = now + 1; TickFps(); }
            if (now >= nextPing) { nextPing = now + 0.5; Ping(); }
            if (now >= nextCable) { nextCable = now + 3; WatchCable(); }
            if (now >= nextHub) { nextHub = now + 3; HubTick(); }
            if (now >= nextLog) { nextLog = now + 5; if (stateText == "Connected") Log($"stats: {videoW}x{videoH} {fps} fps {Transport} rtt {rttMs:0} ms decode {dec.DecodeMs:0.0} ms ({(dec.Hardware ? "hw" : "sw")}) skipped {resyncs} audio {audio.BufferedMs} ms" + (udp != null && udpActive ? $" udp lost {udp.Lost} repaired {udp.Repaired} resent {udp.ResentFrames}" : "")); }
            if (autoExit > 0 && now > autoExit) quit = true;
            if (overlayDirty) { RedrawOverlay(); needRender = true; }
            if (needRender) Render();
        }
        HubShutdown();
        SaveWindow();
        link?.Close();
        UsbBridge.Shared.Stop();
        audio.Stop();
        mdns.Stop();
        Sdl.SDL_Quit();
    }

    void Wake()
    {
        if (Interlocked.Exchange(ref wakePending, 1) == 1) return;
        var e = new Sdl.Event { type = wakeEvent };
        Sdl.SDL_PushEvent(ref e);
    }

    void Post(Action a) { mainQ.Enqueue(a); Wake(); }

    void SaveWindow()
    {
        if (fullscreen) return;
        Sdl.SDL_GetWindowSize(win, out int w, out int h);
        Sdl.SDL_GetWindowPosition(win, out int x, out int y);
        Settings.Set("winW", w); Settings.Set("winH", h); Settings.Set("winX", x); Settings.Set("winY", y);
    }

    // =====================================================================
    // video

    void DrainVideo()
    {
        bool shown = false;
        // Only what is queued now (frames keep arriving while we decode). If the decoder fell far behind
        // (window dragged, menu open, slow PC), skip to the next keyframe instead of lagging forever.
        int n = videoQ.Count;
        if (n > 24)
        {
            int frames = videoQ.Count(i => i.type == PT.Frame);
            if (frames > 20)
            {
                Log($"video: {frames} frames behind, skipping to the next keyframe");
                var keep = new List<(byte, byte[], Link)>();
                while (videoQ.TryDequeue(out var it)) if (it.type != PT.Frame) keep.Add(it);
                foreach (var it in keep) videoQ.Enqueue(it);
                dec.SkipToKeyframe();
                n = videoQ.Count;
            }
        }
        while (n-- > 0 && videoQ.TryDequeue(out var item))
        {
            if (item.from != link) continue;
            switch (item.type)
            {
                case PT.Format:
                    if (item.p.Length < 8) break;
                    int w = item.p[0] << 24 | item.p[1] << 16 | item.p[2] << 8 | item.p[3];
                    int h = item.p[4] << 24 | item.p[5] << 16 | item.p[6] << 8 | item.p[7];
                    dec.Reset();
                    bool rotated = sizedOnce && Math.Abs((double)w / h - (double)videoW / videoH) > 0.01;
                    videoW = w; videoH = h;
                    SwitchKeyLayout(w, h);
                    if (!sizedOnce || rotated) { FitWindow(); sizedOnce = true; }
                    overlayDirty = true;
                    UpdateTitle();
                    break;
                case PT.Config: dec.Config(item.p); break;
                case PT.Frame:
                    dec.Decode(item.p, f => { Upload((AVFrame*)f); shown = true; });
                    break;
            }
        }
        if (shown) needRender = true;
    }

    void Upload(AVFrame* f)
    {
        uint fmt = f->format == (int)AVPixelFormat.AV_PIX_FMT_NV12 ? Sdl.PIXELFORMAT_NV12
                 : (f->format == (int)AVPixelFormat.AV_PIX_FMT_YUV420P || f->format == (int)AVPixelFormat.AV_PIX_FMT_YUVJ420P) ? Sdl.PIXELFORMAT_IYUV : 0;
        if (fmt == 0) return;
        if (videoTex == IntPtr.Zero || texW != f->width || texH != f->height || videoFmt != fmt)
        {
            if (videoTex != IntPtr.Zero) Sdl.SDL_DestroyTexture(videoTex);
            videoTex = Sdl.SDL_CreateTexture(ren, fmt, Sdl.TEXTUREACCESS_STREAMING, f->width, f->height);
            texW = f->width; texH = f->height; videoFmt = fmt;
            Log($"video texture {texW}x{texH} {(fmt == Sdl.PIXELFORMAT_NV12 ? "NV12" : "IYUV")}");
        }
        if (fmt == Sdl.PIXELFORMAT_NV12)
            Sdl.SDL_UpdateNVTexture(videoTex, null, f->data[0], f->linesize[0], f->data[1], f->linesize[1]);
        else
            Sdl.SDL_UpdateYUVTexture(videoTex, null, f->data[0], f->linesize[0], f->data[1], f->linesize[1], f->data[2], f->linesize[2]);
    }

    void Render()
    {
        needRender = false;
        if (ren == IntPtr.Zero) return;
        Sdl.SDL_GetRendererOutputSize(ren, out int w, out int h);
        if (w != outW || h != outH) { outW = w; outH = h; overlayDirty = true; RedrawOverlay(); }
        Sdl.SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        Sdl.SDL_RenderClear(ren);
        if (videoTex != IntPtr.Zero && stateText == "Connected")
        {
            var r = VideoRectPx();
            var dst = new Sdl.Rect { x = (int)Math.Round(r.X), y = (int)Math.Round(r.Y), w = (int)Math.Round(r.Width), h = (int)Math.Round(r.Height) };
            Sdl.SDL_RenderCopy(ren, videoTex, null, &dst);
        }
        if (hasOverlay && overlayTex != IntPtr.Zero) Sdl.SDL_RenderCopy(ren, overlayTex, null, null);
        Sdl.SDL_RenderPresent(ren);
    }

    /// Where the phone picture sits, in renderer pixels (may reach past the edges in Fill mode).
    RectangleF VideoRectPx()
    {
        double bw = Math.Max(outW, 1), bh = Math.Max(outH, 1), vw = Math.Max(videoW, 1), vh = Math.Max(videoH, 1);
        switch (scale)
        {
            case Scale.Stretch: return new RectangleF(0, 0, (float)bw, (float)bh);
            case Scale.Fill:
                {
                    double k = Math.Max(bw / vw, bh / vh);
                    return new RectangleF((float)((bw - vw * k) / 2), (float)((bh - vh * k) / 2), (float)(vw * k), (float)(vh * k));
                }
            default:
                {
                    double k = Math.Min(bw / vw, bh / vh);
                    return new RectangleF((float)((bw - vw * k) / 2), (float)((bh - vh * k) / 2), (float)(vw * k), (float)(vh * k));
                }
        }
    }

    /// Window (mouse) coordinates -> renderer pixels.
    (double, double) ToPx(int x, int y)
    {
        Sdl.SDL_GetWindowSize(win, out int ww, out int wh);
        return (x * (double)outW / Math.Max(ww, 1), y * (double)outH / Math.Max(wh, 1));
    }

    NPoint Norm(int x, int y)
    {
        var (px, py) = ToPx(x, y);
        var r = VideoRectPx();
        return new NPoint(Math.Clamp((px - r.X) / r.Width, 0, 1), Math.Clamp((py - r.Y) / r.Height, 0, 1));
    }

    PointF ViewPoint(NPoint n)
    {
        var r = VideoRectPx();
        return new PointF((float)(r.X + n.x * r.Width), (float)(r.Y + n.y * r.Height));
    }

    float Dpi => hwnd == IntPtr.Zero ? 1f : Math.Max(1f, Win32.GetDpiForWindow(hwnd) / 96f);

    void FitWindow()
    {
        if (fullscreen) return;
        int d = Sdl.SDL_GetWindowDisplayIndex(win);
        if (Sdl.SDL_GetDisplayUsableBounds(d, out var u) != 0) return;
        double maxH = u.h * 0.88, maxW = u.w * 0.9;
        double k = Math.Min(maxH / videoH, maxW / videoW);
        int w = (int)Math.Round(videoW * k), h = (int)Math.Round(videoH * k);
        Sdl.SDL_GetWindowPosition(win, out int x, out int y);
        Sdl.SDL_GetWindowSize(win, out int ow, out _);
        int nx = Math.Clamp(x + ow / 2 - w / 2, u.x, Math.Max(u.x, u.x + u.w - w));
        int ny = Math.Clamp(y, u.y + 30, Math.Max(u.y + 30, u.y + u.h - h - 10));
        Sdl.SDL_SetWindowSize(win, w, h);
        Sdl.SDL_SetWindowPosition(win, nx, ny);
        needRender = true;
    }

    void ToggleFullScreen()
    {
        fullscreen = !fullscreen;
        if (fullscreen) { SaveWindow(); Win32.SetMenu(hwnd, IntPtr.Zero); Sdl.SDL_SetWindowFullscreen(win, Sdl.WINDOW_FULLSCREEN_DESKTOP); }
        else { Sdl.SDL_SetWindowFullscreen(win, 0); Win32.SetMenu(hwnd, menuBar); Win32.DrawMenuBar(hwnd); }
        overlayDirty = true;
        RefreshMenu();
        WindowIcon(iconConnected);   // SDL may reset it when switching full screen
    }

    // ---- window/taskbar icon: phone screen lit while connected, dark when not ----
    bool iconConnected;
    readonly Dictionary<string, IntPtr> icons = new();
    IntPtr Icon(string file, int size)
    {
        var key = file + size;
        if (!icons.TryGetValue(key, out var h))
            icons[key] = h = Win32.LoadImageW(IntPtr.Zero, Path.Combine(AppContext.BaseDirectory, file), 1 /*IMAGE_ICON*/, size, size, 0x10 /*LR_LOADFROMFILE*/);
        return h;
    }
    void WindowIcon(bool connected)
    {
        iconConnected = connected;
        if (hwnd == IntPtr.Zero) return;
        var file = connected ? "phonecast_on.ico" : "phonecast_off.ico";
        var small = Icon(file, Win32.GetSystemMetrics(49 /*SM_CXSMICON*/));
        var big = Icon(file, Win32.GetSystemMetrics(11 /*SM_CXICON*/));
        if (small != IntPtr.Zero) Win32.SendMessageW(hwnd, 0x0080 /*WM_SETICON*/, (IntPtr)0 /*ICON_SMALL*/, small);
        if (big != IntPtr.Zero) Win32.SendMessageW(hwnd, 0x0080, (IntPtr)1 /*ICON_BIG*/, big);
    }

    // =====================================================================
    // overlay (stats, messages, key markers) drawn with GDI+ into a transparent texture

    void RedrawOverlay()
    {
        overlayDirty = false;
        if (outW <= 0 || outH <= 0 || ren == IntPtr.Zero) return;
        if (overlayBmp == null || overlayBmp.Width != outW || overlayBmp.Height != outH)
        {
            overlayBmp?.Dispose();
            overlayBmp = new Bitmap(outW, outH, PixelFormat.Format32bppArgb);
            if (overlayTex != IntPtr.Zero) Sdl.SDL_DestroyTexture(overlayTex);
            overlayTex = Sdl.SDL_CreateTexture(ren, Sdl.PIXELFORMAT_ARGB8888, Sdl.TEXTUREACCESS_STREAMING, outW, outH);
            Sdl.SDL_SetTextureBlendMode(overlayTex, Sdl.BLENDMODE_BLEND);
        }
        bool drew = false;
        using (var g = Graphics.FromImage(overlayBmp))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            float s = Dpi;
            drew |= DrawMarkers(g, s);
            drew |= DrawStats(g, s);
            if (!string.IsNullOrEmpty(message))
            {
                using var f = new Font("Segoe UI", 12.5f * s, FontStyle.Regular, GraphicsUnit.Pixel);
                using var big = new Font("Segoe UI", 15f * s, FontStyle.Regular, GraphicsUnit.Pixel);
                var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                var box = new RectangleF(20 * s, outH / 2f - 80 * s, outW - 40 * s, 160 * s);
                g.DrawString(message, big, new SolidBrush(Color.FromArgb(220, 210, 210, 215)), box, fmt);
                drew = true;
            }
        }
        hasOverlay = drew;
        if (!drew || overlayTex == IntPtr.Zero) return;
        var data = overlayBmp.LockBits(new Rectangle(0, 0, outW, outH), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        Sdl.SDL_UpdateTexture(overlayTex, null, (void*)data.Scan0, data.Stride);
        overlayBmp.UnlockBits(data);
    }

    static readonly string[] ThermalNames = { "cool", "light", "moderate", "hot — slowing down", "very hot — slowing down", "emergency", "shutting down" };

    bool DrawStats(Graphics g, float s)
    {
        if (!showStats || stateText != "Connected") return false;
        var lines = new List<List<(string, Color)>> { new() };
        Color white = Color.White, warn = Color.FromArgb(255, 255, 159, 10), bad = Color.FromArgb(255, 255, 69, 58);
        void Add(string t, Color? c = null) => lines[^1].Add((t, c ?? white));
        void Line() => lines.Add(new());
        Add($"{fps} fps", fps < 20 ? warn : white);
        Add($" · {Transport} {(int)rttMs} ms", rttMs > 40 ? warn : white);
        Add($" · decode {dec.DecodeMs:0.0} ms{(dec.Hardware ? "" : " (software)")} · skipped {resyncs}");
        if (!audio.Muted) Add($" · audio {audio.BufferedMs} ms", audio.BufferedMs > 70 ? warn : white);
        int st = StuttersLast10s();
        Add($" · stutters {st}/10 s", st > 2 ? warn : white);
        if (udpActive && udp != null) Add($" · repaired {udp.Repaired} · resent {udp.ResentFrames} · lost {udp.Lost}", udp.Lost > 0 ? warn : white);
        if (health != null)
        {
            var h = health;
            Line(); Add("Battery "); Add($"{h.TempC:0.0} °C", h.TempC >= 45 ? bad : h.TempC >= 40 ? warn : white);
            Add($" · {h.Battery}%");
            if (Math.Abs(h.Watts) >= 0.1) Add(h.Watts > 0 ? $" · charging {h.Watts:0.0} W" : $" · using {-h.Watts:0.0} W");
            else if (h.Plugged) Add(" · plugged in");
            if (h.CpuC != null || h.GpuC != null)
            {
                Line();
                if (h.CpuC is double c) Add($"CPU {c:0} °C", c >= 85 ? bad : c >= 70 ? warn : white);
                if (h.GpuC is double gg) { if (h.CpuC != null) Add(" · "); Add($"GPU {gg:0} °C", gg >= 85 ? bad : gg >= 70 ? warn : white); }
            }
            Line(); Add("Heat "); Add(ThermalNames[Math.Clamp(h.Thermal, 0, 6)], h.Thermal >= 3 ? bad : h.Thermal >= 2 ? warn : white);
            if (h.Headroom != 255) Add($" · {h.Headroom}% to throttling", h.Headroom >= 100 ? bad : h.Headroom >= 85 ? warn : white);
        }
        using var font = new Font("Consolas", 11.5f * s, FontStyle.Regular, GraphicsUnit.Pixel);
        var fmt = StringFormat.GenericTypographic;
        fmt.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;
        float lineH = font.GetHeight(g) + 1, maxW = 0;
        foreach (var l in lines) maxW = Math.Max(maxW, l.Sum(p => g.MeasureString(p.Item1, font, 10000, fmt).Width));
        float x0 = 8 * s, y0 = 8 * s, pad = 7 * s;
        using (var bg = new SolidBrush(Color.FromArgb(150, 0, 0, 0)))
            g.FillRectangle(bg, x0, y0, maxW + pad * 2, lines.Count * lineH + pad * 1.4f);
        float y = y0 + pad * 0.7f;
        foreach (var l in lines)
        {
            float x = x0 + pad;
            foreach (var (t, c) in l)
            {
                using var b = new SolidBrush(c);
                g.DrawString(t, font, b, x, y, fmt);
                x += g.MeasureString(t, font, 10000, fmt).Width;
            }
            y += lineH;
        }
        return true;
    }

    bool DrawMarkers(Graphics g, float s)
    {
        if (mode == Mode.Normal || !(mode == Mode.Edit || showMarkers) || stateText != "Connected") return false;
        bool editing = mode == Mode.Edit;
        int alpha = editing ? 230 : 90;
        var r = VideoRectPx();
        if (editing) using (var dim = new SolidBrush(Color.FromArgb(64, 0, 0, 0))) g.FillRectangle(dim, r);
        using var font = new Font("Segoe UI", 11f * s, FontStyle.Bold, GraphicsUnit.Pixel);
        var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        void Marker(NPoint n, string label, Color c, float rad = 16)
        {
            rad *= s;
            var p = ViewPoint(n);
            using var fill = new SolidBrush(Color.FromArgb((int)(alpha * 0.55), c));
            using var pen = new Pen(Color.FromArgb(alpha, Color.White), 1.5f * s);
            g.FillEllipse(fill, p.X - rad, p.Y - rad, rad * 2, rad * 2);
            g.DrawEllipse(pen, p.X - rad, p.Y - rad, rad * 2, rad * 2);
            using var tb = new SolidBrush(Color.FromArgb(alpha, Color.White));
            g.DrawString(label, font, tb, new RectangleF(p.X - 40 * s, p.Y - 10 * s, 80 * s, 20 * s), center);
        }
        foreach (var b in map.binds.Values) Marker(new NPoint(b.x, b.y), b.label, Color.FromArgb(10, 132, 255));
        float minSide = Math.Min(r.Width, r.Height);
        if (map.joy != null)
        {
            var c = ViewPoint(map.joy); float rad = (float)map.joyR * minSide;
            using var pen = new Pen(Color.FromArgb((int)(alpha * 0.8), Color.White), 1.5f * s);
            g.DrawEllipse(pen, c.X - rad, c.Y - rad, rad * 2, rad * 2);
            Marker(map.joy, "WASD", Color.FromArgb(48, 209, 88), 22);
        }
        if (map.look != null)
        {
            var c = ViewPoint(map.look); float rad = (float)map.lookR * minSide;
            using var pen = new Pen(Color.FromArgb((int)(alpha * 0.8), Color.White), 1.5f * s) { DashPattern = new[] { 5f, 4f } };
            g.DrawEllipse(pen, c.X - rad, c.Y - rad, rad * 2, rad * 2);
            Marker(map.look, "LOOK", Color.FromArgb(255, 159, 10), 22);
        }
        if (pending != null)
        {
            var c = ViewPoint(pending);
            using var pen = new Pen(Color.Gold, 2 * s);
            g.DrawLine(pen, c.X - 14 * s, c.Y, c.X + 14 * s, c.Y);
            g.DrawLine(pen, c.X, c.Y - 14 * s, c.X, c.Y + 14 * s);
        }
        if (editing)
        {
            if (recording != null)
                foreach (var (rp, ri) in recording.Select((rp, ri) => (rp, ri)))
                {
                    var c = ViewPoint(rp);
                    using var rb = new SolidBrush(Color.FromArgb(200, 230, 60, 140));
                    g.FillEllipse(rb, c.X - 12 * s, c.Y - 12 * s, 24 * s, 24 * s);
                    g.DrawString((ri + 1).ToString(), new Font("Segoe UI", 11f * s, FontStyle.Bold, GraphicsUnit.Pixel), Brushes.White, new RectangleF(c.X - 12 * s, c.Y - 9 * s, 24 * s, 20 * s), center);
                }
            string help = recording != null
                ? $"MACRO — click the spots in the order they should be tapped ({recording.Count} so far), then press the key that runs them.  Esc: cancel"
                : pending == null
                ? "KEY MAP — click a button on the phone screen, then press the key or mouse button for it.\nMovement: click the middle of the joystick, then press W (scroll to resize) · Alt-click: joystick · Ctrl-click: mouse-look area · drag a marker to move it · Shift+T over a marker: turbo · Shift+M: record a macro · Backspace over a marker: delete · Esc: done"
                : "Now press a key, or click a mouse button, to bind this spot.  Esc: cancel";
            using var hf = new Font("Segoe UI", 12f * s, FontStyle.Regular, GraphicsUnit.Pixel);
            var box = new RectangleF(12 * s, 12 * s, outW - 24 * s, 54 * s);
            using (var bg = new SolidBrush(Color.FromArgb(180, 0, 0, 0))) g.FillRectangle(bg, box);
            g.DrawString(help, hf, Brushes.White, RectangleF.Inflate(box, -8 * s, -4 * s), center);
        }
        return true;
    }

    void SetMessage(string m) { message = m; overlayDirty = true; }

    // =====================================================================
    // stats / title

    int StuttersLast10s() { lock (stutters) { var n = Now; stutters.RemoveAll(t => n - t > 10); return stutters.Count; } }
    string Transport => viaUSB || deviceLabel == TetherLabel ? (udpActive ? "USB UDP" : "USB") : udpActive ? "Wi-Fi UDP" : "Wi-Fi";

    void TickFps()
    {
        int f = dec.Frames;
        fps = f - lastFrames; lastFrames = f;
        UpdateTitle();
        if (showStats) overlayDirty = true;
    }

    void UpdateTitle()
    {
        var parts = new List<string> { "PhoneCast" };
        if (deviceLabel != "") parts.Add(deviceLabel);
        if (stateText == "Connected")
        {
            parts.Add($"{videoW}×{videoH} · {fps} fps · {Transport} {(int)rttMs} ms · decode {dec.DecodeMs:0.0} ms · skipped {resyncs}");
            if (!controlAvailable) parts.Add("view only — turn on mouse & keyboard in the phone app");
        }
        else parts.Add(stateText);
        switch (mode)
        {
            case Mode.Game: parts.Add($"MOUSE AIMING (Esc to exit) · speed {map.sens:0.0}×"); break;
            case Mode.Edit: parts.Add("EDITING KEY MAP"); break;
            default: if (typing) parts.Add("TYPING (Ctrl+T for buttons)"); break;
        }
        Sdl.SetTitle(win, string.Join(" — ", parts));
    }

    void LogLag(double gapMs)
    {
        try { File.AppendAllText(LagLog, $"{DateTime.Now:O} gap={(int)gapMs}ms rtt={(int)rttMs}ms decode={dec.DecodeMs:0.0}ms resyncs={resyncs}\n"); } catch { }
    }
}
