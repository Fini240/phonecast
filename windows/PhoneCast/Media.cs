using System.Diagnostics;
using FFmpeg.AutoGen;

namespace PhoneCast;

/// H.264 Annex B -> FFmpeg (D3D11 hardware decode, software fallback). Frames come out the moment they
/// are decoded (LOW_DELAY, no frame threads), as NV12 or YUV420P in system memory for SDL.
sealed unsafe class H264Decoder : IDisposable
{
    AVCodecContext* ctx;
    AVFrame* frame, sw;
    AVPacket* pkt;
    AVBufferRef* hwDevice;
    readonly AVCodecContext_get_format_func getFormat;
    readonly AVCodecContext_get_format getFormatDelegate;
    byte[] config = Array.Empty<byte>();
    bool waitingForKey = true;
    public bool Hardware { get; private set; }
    public double DecodeMs;
    public int Frames;
    public Action OnNeedKeyframe;

    public H264Decoder()
    {
        getFormatDelegate = GetFormat;
        getFormat = new AVCodecContext_get_format_func { Pointer = System.Runtime.InteropServices.Marshal.GetFunctionPointerForDelegate(getFormatDelegate) };
        // Software (slice threads) is faster here: copying hardware-decoded frames back costs ~7 ms.
        Open(Environment.GetEnvironmentVariable("PHONECAST_HW_DECODE") != null || Settings.Bool("hwDecode"));
    }

    AVPixelFormat GetFormat(AVCodecContext* s, AVPixelFormat* fmts)
    {
        for (var p = fmts; *p != AVPixelFormat.AV_PIX_FMT_NONE; p++)
            if (*p == AVPixelFormat.AV_PIX_FMT_D3D11) return *p;
        Hardware = false;
        return ffmpeg.avcodec_default_get_format(s, fmts);
    }

    /// Switch decoder (CPU <-> graphics card) between frames; the next keyframe restarts the picture.
    public void UseHardware(bool hw) { Open(hw); OnNeedKeyframe?.Invoke(); }

    void Open(bool tryHardware)
    {
        Close();
        var codec = ffmpeg.avcodec_find_decoder(AVCodecID.AV_CODEC_ID_H264);
        ctx = ffmpeg.avcodec_alloc_context3(codec);
        ctx->flags |= ffmpeg.AV_CODEC_FLAG_LOW_DELAY;
        Hardware = false;
        if (tryHardware)
        {
            AVBufferRef* dev = null;
            if (ffmpeg.av_hwdevice_ctx_create(&dev, AVHWDeviceType.AV_HWDEVICE_TYPE_D3D11VA, null, null, 0) == 0)
            {
                hwDevice = dev;
                ctx->hw_device_ctx = ffmpeg.av_buffer_ref(dev);
                ctx->get_format = getFormat;
                Hardware = true;
            }
        }
        // software: slice threads only (frame threads would hold frames back)
        ctx->thread_type = ffmpeg.FF_THREAD_SLICE;
        ctx->thread_count = Hardware ? 1 : 0;
        if (ffmpeg.avcodec_open2(ctx, codec, null) < 0 && Hardware) { Open(false); return; }
        frame = ffmpeg.av_frame_alloc();
        sw = ffmpeg.av_frame_alloc();
        pkt = ffmpeg.av_packet_alloc();
        waitingForKey = true;
    }

    void Close()
    {
        if (ctx != null) { var c = ctx; ffmpeg.avcodec_free_context(&c); ctx = null; }
        if (frame != null) { var f = frame; ffmpeg.av_frame_free(&f); frame = null; }
        if (sw != null) { var f = sw; ffmpeg.av_frame_free(&f); sw = null; }
        if (pkt != null) { var p = pkt; ffmpeg.av_packet_free(&p); pkt = null; }
        if (hwDevice != null) { var d = hwDevice; ffmpeg.av_buffer_unref(&d); hwDevice = null; }
    }

    public void Dispose() => Close();

    public void Reset()
    {
        if (ctx != null) ffmpeg.avcodec_flush_buffers(ctx);
        waitingForKey = true;
    }

    public void Config(byte[] annexB) => config = annexB;

    /// Drop everything until the next keyframe (the decoder fell behind).
    public void SkipToKeyframe() { if (ctx != null) ffmpeg.avcodec_flush_buffers(ctx); waitingForKey = true; OnNeedKeyframe?.Invoke(); }

    /// Decodes one FRAME payload (u8 keyframe, then Annex B). Calls [show] with each decoded picture.
    public void Decode(byte[] payload, Action<IntPtr> show)
    {
        if (payload.Length < 2 || ctx == null) return;
        bool key = payload[0] == 1;
        if (waitingForKey && !key) return;
        byte[] data;
        if (key && config.Length > 0)
        {
            data = new byte[config.Length + payload.Length - 1];
            Buffer.BlockCopy(config, 0, data, 0, config.Length);
            Buffer.BlockCopy(payload, 1, data, config.Length, payload.Length - 1);
        }
        else
        {
            data = new byte[payload.Length - 1];
            Buffer.BlockCopy(payload, 1, data, 0, data.Length);
        }
        long t0 = Stopwatch.GetTimestamp();
        int r;
        fixed (byte* p = data)
        {
            pkt->data = p; pkt->size = data.Length;
            pkt->flags = key ? ffmpeg.AV_PKT_FLAG_KEY : 0;
            r = ffmpeg.avcodec_send_packet(ctx, pkt);
            pkt->data = null; pkt->size = 0;
        }
        if (r < 0 && r != ffmpeg.AVERROR(ffmpeg.EAGAIN))
        {
            ffmpeg.avcodec_flush_buffers(ctx);
            waitingForKey = true;
            OnNeedKeyframe?.Invoke();
            return;
        }
        waitingForKey = false;
        while (ffmpeg.avcodec_receive_frame(ctx, frame) == 0)
        {
            AVFrame* outF = frame;
            if (frame->format == (int)AVPixelFormat.AV_PIX_FMT_D3D11)
            {
                ffmpeg.av_frame_unref(sw);
                if (ffmpeg.av_hwframe_transfer_data(sw, frame, 0) < 0) { ffmpeg.av_frame_unref(frame); continue; }
                outF = sw;
            }
            DecodeMs = DecodeMs * 0.9 + (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency * 0.1;
            Frames++;
            show((IntPtr)outF);
            ffmpeg.av_frame_unref(frame);
            t0 = Stopwatch.GetTimestamp();
        }
    }
}

/// PCM s16le 48 kHz stereo -> SDL audio queue, with a cap on buffered audio so it stays in sync.
sealed unsafe class AudioSink
{
    uint dev;
    bool started, trimming;
    double behindSince;
    const int Target = 48000 * 4 / 100, High = 48000 * 6 / 100; // 40 ms, 60 ms (in frames)
    public bool Muted;
    static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    int Queued => dev == 0 ? 0 : (int)(Sdl.SDL_GetQueuedAudioSize(dev) / 4);
    public int BufferedMs => Queued * 1000 / 48000;

    public void Push(byte[] d)
    {
        if (Muted || d.Length < 4) return;
        if (dev == 0)
        {
            var want = new Sdl.AudioSpec { freq = 48000, format = 0x8010, channels = 2, samples = 256 };
            dev = Sdl.SDL_OpenAudioDevice(IntPtr.Zero, 0, ref want, out _, 0);
            if (dev == 0) return;
        }
        int q = Queued;
        double now = Now;
        if (q > High) { if (behindSince == 0) behindSince = now; } else behindSince = 0;
        if (q > 48000 * 12 / 100 || (behindSince > 0 && now - behindSince > 0.5)) trimming = true;
        if (trimming)
        {
            if (q > Target) return;
            trimming = false; behindSince = 0;
        }
        fixed (byte* p = d) Sdl.SDL_QueueAudio(dev, p, (uint)(d.Length & ~3));
        if (!started && Queued >= Target) { Sdl.SDL_PauseAudioDevice(dev, 0); started = true; }
    }

    public void Stop()
    {
        if (dev != 0) { Sdl.SDL_CloseAudioDevice(dev); dev = 0; }
        started = false; trimming = false; behindSince = 0;
    }
}
