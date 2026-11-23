using System.Collections.Concurrent;
using System.Diagnostics;
using FFmpeg.AutoGen;

namespace PhoneCast;

/// Records the mirror to an .mp4 in Videos\PhoneCast (the Windows twin of the Mac's Recorder). The phone's H.264
/// frames are written as they arrive (no re-encoding, so recording costs no CPU and adds no lag); the phone's sound
/// is encoded to AAC. Starts on the next key frame; stops by itself if the picture changes size (rotation).
sealed unsafe class Recorder
{
    public static readonly Recorder Shared = new();

    public static string Folder
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "PhoneCast");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    volatile bool recording;
    public bool Recording => recording;

    readonly object gate = new();
    readonly BlockingCollection<Action> work = new();
    byte[] config = Array.Empty<byte>();
    int w, h;

    // writer state (only on the worker thread)
    AVFormatContext* fmt;
    AVStream* vs, aus;
    AVCodecContext* aac;
    AVFrame* af;
    AVPacket* pkt;
    string path;
    long t0;
    long audioSamples = -1;
    readonly List<float> aBufL = new(), aBufR = new();
    long lastVideoPts = -1;
    bool opened;

    Recorder()
    {
        new Thread(() => { foreach (var a in work.GetConsumingEnumerable()) { try { a(); } catch (Exception e) { App.Log("recorder: " + e.Message); } } })
            { IsBackground = true, Name = "recorder" }.Start();
    }

    static double Seconds(long ticks) => ticks / (double)Stopwatch.Frequency;

    // ---------- from the mirror (any thread) ----------

    public void Format(int width, int height)
    {
        bool changed;
        lock (gate) { changed = (w != 0 && (w != width || h != height)); w = width; h = height; }
        if (changed && recording) Stop(tr("The phone's picture changed size, so the recording was saved."));
    }

    public void Config(byte[] annexB) { lock (gate) config = annexB; }

    public void Start(int width, int height)
    {
        lock (gate) { if (width > 0) { w = width; h = height; } }
        if (recording) return;
        recording = true;
        work.Add(() => { opened = false; audioSamples = -1; lastVideoPts = -1; aBufL.Clear(); aBufR.Clear(); });
        Ui.Post(() => { Store.Shared.Fire("recording"); Banners.Info(tr("Recording the mirror"), tr("It starts with the next full picture. Ctrl+Shift+R stops it.")); });
    }

    public void Stop(string reason = null)
    {
        if (!recording) return;
        recording = false;
        work.Add(() => Finish(reason));
    }

    /// One FRAME payload: u8 keyframe, then Annex B.
    public void Video(byte[] payload)
    {
        if (!recording || payload.Length < 2) return;
        long now = Stopwatch.GetTimestamp();
        work.Add(() => WriteVideo(payload, now));
    }

    /// PCM s16le, 48 kHz, stereo.
    public void Audio(byte[] pcm)
    {
        if (!recording || pcm.Length < 4) return;
        long now = Stopwatch.GetTimestamp();
        work.Add(() => WriteAudio(pcm, now));
    }

    // ---------- writer (worker thread) ----------

    bool Open(long now)
    {
        byte[] cfg; int vw, vh;
        lock (gate) { cfg = config; vw = w; vh = h; }
        if (cfg.Length == 0 || vw == 0) return false;
        path = Path.Combine(Folder, $"PhoneCast {DateTime.Now:yyyy-MM-dd 'at' HH.mm.ss}.mp4");
        AVFormatContext* f = null;
        if (ffmpeg.avformat_alloc_output_context2(&f, null, "mp4", path) < 0 || f == null) throw new Exception("no mp4 muxer");
        fmt = f;
        vs = ffmpeg.avformat_new_stream(fmt, null);
        vs->time_base = new AVRational { num = 1, den = 90000 };
        var vp = vs->codecpar;
        vp->codec_type = AVMediaType.AVMEDIA_TYPE_VIDEO;
        vp->codec_id = AVCodecID.AV_CODEC_ID_H264;
        vp->width = vw; vp->height = vh;
        vp->extradata = (byte*)ffmpeg.av_mallocz((ulong)(cfg.Length + ffmpeg.AV_INPUT_BUFFER_PADDING_SIZE));
        fixed (byte* c = cfg) Buffer.MemoryCopy(c, vp->extradata, cfg.Length, cfg.Length);
        vp->extradata_size = cfg.Length;

        var codec = ffmpeg.avcodec_find_encoder(AVCodecID.AV_CODEC_ID_AAC);
        if (codec != null)
        {
            aac = ffmpeg.avcodec_alloc_context3(codec);
            aac->sample_rate = 48000;
            aac->sample_fmt = AVSampleFormat.AV_SAMPLE_FMT_FLTP;
            ffmpeg.av_channel_layout_default(&aac->ch_layout, 2);
            aac->bit_rate = 160_000;
            aac->time_base = new AVRational { num = 1, den = 48000 };
            if ((fmt->oformat->flags & ffmpeg.AVFMT_GLOBALHEADER) != 0) aac->flags |= ffmpeg.AV_CODEC_FLAG_GLOBAL_HEADER;
            if (ffmpeg.avcodec_open2(aac, codec, null) >= 0)
            {
                aus = ffmpeg.avformat_new_stream(fmt, null);
                aus->time_base = new AVRational { num = 1, den = 48000 };
                ffmpeg.avcodec_parameters_from_context(aus->codecpar, aac);
                af = ffmpeg.av_frame_alloc();
                af->nb_samples = aac->frame_size > 0 ? aac->frame_size : 1024;
                af->format = (int)AVSampleFormat.AV_SAMPLE_FMT_FLTP;
                af->sample_rate = 48000;
                ffmpeg.av_channel_layout_default(&af->ch_layout, 2);
                ffmpeg.av_frame_get_buffer(af, 0);
            }
            else { var a = aac; ffmpeg.avcodec_free_context(&a); aac = null; }
        }
        if (ffmpeg.avio_open(&fmt->pb, path, ffmpeg.AVIO_FLAG_WRITE) < 0) throw new Exception("can't write " + path);
        if (ffmpeg.avformat_write_header(fmt, null) < 0) throw new Exception("mp4 header");
        pkt = ffmpeg.av_packet_alloc();
        t0 = now;
        opened = true;
        App.Log($"recorder: {path} {vw}x{vh}");
        return true;
    }

    void WriteVideo(byte[] payload, long now)
    {
        if (!recording && !opened) return;
        bool key = payload[0] == 1;
        if (!opened) { if (!key || !Open(now)) return; }
        long pts = (long)(Seconds(now - t0) * 90000);
        if (pts <= lastVideoPts) pts = lastVideoPts + 1;
        lastVideoPts = pts;
        fixed (byte* d = &payload[1])
        {
            ffmpeg.av_new_packet(pkt, payload.Length - 1);
            Buffer.MemoryCopy(d, pkt->data, payload.Length - 1, payload.Length - 1);
        }
        pkt->stream_index = vs->index;
        pkt->pts = pkt->dts = ffmpeg.av_rescale_q(pts, new AVRational { num = 1, den = 90000 }, vs->time_base);
        if (key) pkt->flags |= ffmpeg.AV_PKT_FLAG_KEY;
        ffmpeg.av_interleaved_write_frame(fmt, pkt);
        ffmpeg.av_packet_unref(pkt);
    }

    void WriteAudio(byte[] pcm, long now)
    {
        if (!opened || aac == null) return;
        // the first sound (or sound after a pause) is placed where it arrived; after that the samples run on
        long at = (long)(Seconds(now - t0) * 48000);
        long expected = audioSamples < 0 ? -1 : audioSamples + aBufL.Count;
        if (audioSamples < 0 || Math.Abs(at - expected) > 48000 / 5)
        {
            FlushAudio(final: false, drop: true);
            audioSamples = Math.Max(at, audioSamples < 0 ? 0 : audioSamples);
        }
        int n = pcm.Length / 4;
        for (int i = 0; i < n; i++)
        {
            aBufL.Add(BitConverter.ToInt16(pcm, i * 4) / 32768f);
            aBufR.Add(BitConverter.ToInt16(pcm, i * 4 + 2) / 32768f);
        }
        FlushAudio(final: false, drop: false);
    }

    void FlushAudio(bool final, bool drop)
    {
        if (aac == null) return;
        if (drop) { aBufL.Clear(); aBufR.Clear(); return; }
        int fs = af->nb_samples;
        while (aBufL.Count >= fs)
        {
            ffmpeg.av_frame_make_writable(af);
            var l = (float*)af->data[0]; var r = (float*)af->data[1];
            for (int i = 0; i < fs; i++) { l[i] = aBufL[i]; r[i] = aBufR[i]; }
            aBufL.RemoveRange(0, fs); aBufR.RemoveRange(0, fs);
            af->pts = audioSamples;
            audioSamples += fs;
            Encode(af);
        }
        if (final) Encode(null);
    }

    void Encode(AVFrame* frame)
    {
        if (ffmpeg.avcodec_send_frame(aac, frame) < 0) return;
        while (ffmpeg.avcodec_receive_packet(aac, pkt) >= 0)
        {
            pkt->stream_index = aus->index;
            ffmpeg.av_packet_rescale_ts(pkt, aac->time_base, aus->time_base);
            ffmpeg.av_interleaved_write_frame(fmt, pkt);
            ffmpeg.av_packet_unref(pkt);
        }
    }

    void Finish(string reason)
    {
        if (!opened)
        {
            Ui.Post(() => { Store.Shared.Fire("recording"); if (reason != null) Banners.Info(tr("Recording stopped"), reason); });
            return;
        }
        FlushAudio(final: true, drop: false);
        ffmpeg.av_write_trailer(fmt);
        ffmpeg.avio_closep(&fmt->pb);
        var f = fmt; ffmpeg.avformat_free_context(f); fmt = null;
        if (aac != null) { var a = aac; ffmpeg.avcodec_free_context(&a); aac = null; }
        if (af != null) { var x = af; ffmpeg.av_frame_free(&x); af = null; }
        if (pkt != null) { var p = pkt; ffmpeg.av_packet_free(&p); pkt = null; }
        opened = false;
        var saved = path;
        App.Log("recorder: saved " + saved);
        Ui.Post(() =>
        {
            Store.Shared.Fire("recording");
            Banners.Info(reason ?? tr("Recording saved"), Path.GetFileName(saved), () => { try { System.Diagnostics.Process.Start("explorer.exe", "/select,\"" + saved + "\""); } catch { } });
        });
    }
}
