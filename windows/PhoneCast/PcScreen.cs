using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using FFmpeg.AutoGen;

namespace PhoneCast;

/// Shows this PC's main screen on the phone (the phone's Mac tab → "Open the PC's screen"): GDI capture,
/// low-latency H.264 from the graphics card (NVENC, AMF, Quick Sync, else Media Foundation), sent over the hub as
/// SCREEN_FORMAT / SCREEN_CONFIG (SPS+PPS, Annex B) / SCREEN_FRAME (u8 keyframe + Annex B), like the Mac's MacScreen.
sealed unsafe class PcScreen
{
    readonly Action<byte, byte[]> send;
    readonly Func<byte, byte[], int, bool> sendVideo;
    volatile bool running, forceKey;
    Thread thread;
    int generation;

    public PcScreen(Action<byte, byte[]> send, Func<byte, byte[], int, bool> sendVideo) { this.send = send; this.sendVideo = sendVideo; }

    public bool Active => running;

    public void Start(int longSide, int mbps)
    {
        Stop();
        running = true; forceKey = true;
        int gen = ++generation;
        thread = new Thread(() =>
        {
            try { Run(gen, Math.Max(640, longSide), Math.Clamp(mbps, 2, 60)); }
            catch (Exception e)
            {
                App.Log("pcscreen: " + e);
                if (gen == generation) Deny(tr("Couldn't show the PC's screen: {0}", e.Message));
            }
        }) { IsBackground = true, Name = "pcscreen", Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }

    public void Stop()
    {
        generation++;
        running = false;
        thread?.Join(1500);
        thread = null;
    }

    public void ForceKeyframe() => forceKey = true;

    void Deny(string why) { running = false; send(HubLink.ScreenDenied, System.Text.Encoding.UTF8.GetBytes(why)); }

    // ---------- capture + encode (own thread) ----------

    static readonly (string name, Action<IntPtr> opts)[] Encoders =
    {
        ("h264_nvenc", c => { Set(c, "preset", "p1"); Set(c, "tune", "ull"); Set(c, "zerolatency", "1"); Set(c, "rc", "cbr"); Set(c, "delay", "0"); }),
        ("h264_amf", c => { Set(c, "usage", "ultralowlatency"); Set(c, "quality", "speed"); Set(c, "rc", "cbr"); }),
        ("h264_qsv", c => { Set(c, "preset", "veryfast"); Set(c, "async_depth", "1"); Set(c, "look_ahead", "0"); }),
        ("h264_mf", c => { Set(c, "rate_control", "cbr"); Set(c, "scenario", "display_remoting"); Set(c, "hw_encoding", "1"); }),
        ("h264_mf", c => { Set(c, "rate_control", "cbr"); Set(c, "scenario", "display_remoting"); }),
    };

    static void Set(IntPtr ctx, string k, string v) => ffmpeg.av_opt_set(((AVCodecContext*)ctx)->priv_data, k, v, 0);

    void Run(int gen, int longSide, int mbps)
    {
        // the primary screen, in real pixels (the process is per-monitor DPI aware)
        int sw = Gdi.GetSystemMetrics(0), sh = Gdi.GetSystemMetrics(1);
        double s = Math.Min(1.0, (double)longSide / Math.Max(sw, sh));
        int w = (int)(sw * s) & ~1, h = (int)(sh * s) & ~1;

        AVCodecContext* enc = null;
        string used = null;
        foreach (var (name, opts) in Encoders)
        {
            var codec = ffmpeg.avcodec_find_encoder_by_name(name);
            if (codec == null) continue;
            var c = ffmpeg.avcodec_alloc_context3(codec);
            c->width = w; c->height = h;
            c->pix_fmt = AVPixelFormat.AV_PIX_FMT_NV12;
            c->time_base = new AVRational { num = 1, den = 1000 };
            c->framerate = new AVRational { num = 60, den = 1 };
            c->bit_rate = mbps * 1_000_000L;
            c->rc_max_rate = c->bit_rate;
            c->rc_buffer_size = (int)(c->bit_rate / 20);   // ~50 ms of video: low delay
            c->gop_size = 600;
            c->max_b_frames = 0;
            c->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
            c->profile = ffmpeg.AV_PROFILE_H264_HIGH;
            opts((IntPtr)c);
            if (ffmpeg.avcodec_open2(c, codec, null) >= 0) { enc = c; used = name; break; }
            ffmpeg.avcodec_free_context(&c);
        }
        if (enc == null) { Deny(tr("This PC has no H.264 video encoder PhoneCast can use.")); return; }
        App.Log($"pcscreen: {sw}x{sh} -> {w}x{h} at {mbps} Mbit/s with {used}");

        var sws = ffmpeg.sws_getContext(sw, sh, AVPixelFormat.AV_PIX_FMT_BGRA, w, h, AVPixelFormat.AV_PIX_FMT_NV12,
            (int)SwsFlags.SWS_FAST_BILINEAR, null, null, null);
        var frame = ffmpeg.av_frame_alloc();
        frame->format = (int)AVPixelFormat.AV_PIX_FMT_NV12; frame->width = w; frame->height = h;
        ffmpeg.av_frame_get_buffer(frame, 32);
        var pkt = ffmpeg.av_packet_alloc();

        var fmt = new byte[8];
        fmt[0] = (byte)(w >> 24); fmt[1] = (byte)(w >> 16); fmt[2] = (byte)(w >> 8); fmt[3] = (byte)w;
        fmt[4] = (byte)(h >> 24); fmt[5] = (byte)(h >> 16); fmt[6] = (byte)(h >> 8); fmt[7] = (byte)h;
        send(HubLink.ScreenFormat, fmt);

        // GDI capture into a DIB section we can read directly
        IntPtr screenDc = Gdi.GetDC(IntPtr.Zero), memDc = Gdi.CreateCompatibleDC(screenDc);
        var bmi = new Gdi.BITMAPINFO { biSize = 40, biWidth = sw, biHeight = -sh, biPlanes = 1, biBitCount = 32 };
        IntPtr bits;
        IntPtr dib = Gdi.CreateDIBSection(screenDc, ref bmi, 0, out bits, IntPtr.Zero, 0);
        IntPtr old = Gdi.SelectObject(memDc, dib);
        byte[] lastConfig = null;
        var sw0 = System.Diagnostics.Stopwatch.StartNew();
        long frameNo = 0;
        try
        {
            while (running && gen == generation)
            {
                long due = frameNo * 1000 / 60;
                long now = sw0.ElapsedMilliseconds;
                if (now < due) { Thread.Sleep((int)Math.Min(16, due - now)); continue; }
                if (now - due > 100) frameNo = now * 60 / 1000;   // fell behind: don't try to catch up
                frameNo++;

                Gdi.BitBlt(memDc, 0, 0, sw, sh, screenDc, 0, 0, 0x00CC0020 /* SRCCOPY */);
                DrawCursor(memDc);

                byte*[] src = { (byte*)bits, null, null, null };
                int[] srcStride = { sw * 4, 0, 0, 0 };
                ffmpeg.av_frame_make_writable(frame);
                ffmpeg.sws_scale(sws, src, srcStride, 0, sh, frame->data.ToArray(), frame->linesize.ToArray());
                frame->pts = now;
                if (forceKey) { frame->pict_type = AVPictureType.AV_PICTURE_TYPE_I; frame->flags |= ffmpeg.AV_FRAME_FLAG_KEY; forceKey = false; }
                else { frame->pict_type = AVPictureType.AV_PICTURE_TYPE_NONE; frame->flags &= ~ffmpeg.AV_FRAME_FLAG_KEY; }
                if (ffmpeg.avcodec_send_frame(enc, frame) < 0) continue;
                while (ffmpeg.avcodec_receive_packet(enc, pkt) >= 0)
                {
                    var data = new ReadOnlySpan<byte>(pkt->data, pkt->size);
                    var (config, body, key) = Split(data);
                    key |= (pkt->flags & ffmpeg.AV_PKT_FLAG_KEY) != 0;
                    if (config.Length > 0 && (lastConfig == null || !config.AsSpan().SequenceEqual(lastConfig)))
                    {
                        lastConfig = config;
                        send(HubLink.ScreenConfig, config);
                    }
                    ffmpeg.av_packet_unref(pkt);
                    if (body.Length == 0) continue;
                    var outp = new byte[body.Length + 1];
                    outp[0] = (byte)(key ? 1 : 0);
                    body.CopyTo(outp, 1);
                    // network behind: skip this frame, and restart cleanly from a keyframe
                    if (!sendVideo(HubLink.ScreenFrame, outp, key ? 6 : 3)) forceKey = true;
                }
            }
        }
        finally
        {
            Gdi.SelectObject(memDc, old);
            Gdi.DeleteObject(dib);
            Gdi.DeleteDC(memDc);
            Gdi.ReleaseDC(IntPtr.Zero, screenDc);
            ffmpeg.av_packet_free(&pkt);
            ffmpeg.av_frame_free(&frame);
            ffmpeg.sws_freeContext(sws);
            ffmpeg.avcodec_free_context(&enc);
            App.Log("pcscreen: stopped");
        }
    }

    /// Annex B packet -> (SPS+PPS with start codes, the other NAL units, has an IDR slice).
    static (byte[] config, byte[] body, bool key) Split(ReadOnlySpan<byte> d)
    {
        var cfg = new List<byte>(); var body = new List<byte>(d.Length); bool key = false;
        int i = 0, start = -1;
        void Flush(ReadOnlySpan<byte> all, int from, int to)
        {
            if (from < 0 || to <= from) return;
            int type = all[from] & 0x1f;
            var nal = all[from..to];
            var target = type == 7 || type == 8 ? cfg : body;
            if (type == 5) key = true;
            if (type == 9) return;   // access unit delimiter: not needed
            target.AddRange(new byte[] { 0, 0, 0, 1 });
            foreach (var b in nal) target.Add(b);
        }
        while (i + 3 <= d.Length)
        {
            int sc = d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 ? 3 : (i + 4 <= d.Length && d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 0 && d[i + 3] == 1 ? 4 : 0);
            if (sc > 0)
            {
                Flush(d, start, i);
                i += sc; start = i;
            }
            else i++;
        }
        Flush(d, start, d.Length);
        return (cfg.ToArray(), body.ToArray(), key);
    }

    static void DrawCursor(IntPtr dc)
    {
        var ci = new Gdi.CURSORINFO { cbSize = Marshal.SizeOf<Gdi.CURSORINFO>() };
        if (!Gdi.GetCursorInfo(ref ci) || (ci.flags & 1) == 0) return;
        if (!Gdi.GetIconInfo(ci.hCursor, out var ii)) return;
        Gdi.DrawIconEx(dc, ci.ptScreenPos.x - ii.xHotspot, ci.ptScreenPos.y - ii.yHotspot, ci.hCursor, 0, 0, 0, IntPtr.Zero, 3);
        if (ii.hbmMask != IntPtr.Zero) Gdi.DeleteObject(ii.hbmMask);
        if (ii.hbmColor != IntPtr.Zero) Gdi.DeleteObject(ii.hbmColor);
    }
}
