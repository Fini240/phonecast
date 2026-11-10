using System.Diagnostics;
using System.Net;
using System.Net.Sockets;

namespace PhoneCast;

/// Receives Wi-Fi video over UDP (see UdpVideo.kt on the phone): frames are rebuilt from datagrams,
/// repaired with the XOR pieces, missing pieces asked for again ("PCR1"), and delivered in order.
/// After 120 ms a frame is given up and a keyframe requested.
sealed class UdpVideoIn
{
    public Action<byte[]> OnFrame;
    public Action OnNeedKeyframe;
    public int Lost, Repaired, ResentFrames;
    public double LastPacketAt;

    const int Shard = 1200, Header = 16;
    static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    readonly Socket sock;
    readonly uint token;
    volatile bool running;
    System.Threading.Timer helloTimer;

    sealed class Frame
    {
        public readonly int N, P, Len;
        public readonly byte[][] Data, Repair;
        public int HaveData;
        public double LastAt = Now;
        public Frame(int n, int p, int len) { N = n; P = p; Len = len; Data = new byte[n][]; Repair = new byte[p][]; }
    }
    readonly Dictionary<uint, Frame> frames = new();
    readonly Dictionary<uint, byte[]> ready = new();
    uint? next;
    uint maxSeen;
    double stuckSince, lastAsk, lastKeyRequest;
    int asks;
    readonly List<double> recentLosses = new();

    public int RecentLossCount()
    {
        lock (recentLosses) { var n = Now; recentLosses.RemoveAll(t => n - t > 5); return recentLosses.Count; }
    }

    public UdpVideoIn(IPAddress host, int port, uint token)
    {
        this.token = token;
        sock = new Socket(host.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
        sock.ReceiveBufferSize = 7 << 20;
        try { sock.IOControl(-1744830452 /* SIO_UDP_CONNRESET */, new byte[] { 0 }, null); } catch { }
        sock.Connect(new IPEndPoint(host, port));
    }

    public void Start()
    {
        running = true;
        helloTimer = new System.Threading.Timer(_ => Hello(), null, 0, 500);
        new Thread(ReceiveLoop) { IsBackground = true, Name = "udp", Priority = ThreadPriority.Highest }.Start();
    }

    public void Stop()
    {
        running = false;
        helloTimer?.Dispose();
        try { sock.Close(); } catch { }
    }

    void Hello()
    {
        if (!running) return;
        var b = new byte[8];
        "PCU1"u8.CopyTo(b);
        Be32(b, 4, token);
        try { sock.Send(b); } catch { }
    }

    static void Be32(byte[] b, int i, uint v) { b[i] = (byte)(v >> 24); b[i + 1] = (byte)(v >> 16); b[i + 2] = (byte)(v >> 8); b[i + 3] = (byte)v; }
    static int U16(byte[] b, int i) => b[i] << 8 | b[i + 1];
    static uint U32(byte[] b, int i) => (uint)(b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3]);
    static bool Newer(uint a, uint b) => (int)(a - b) > 0;

    void AskResend(uint id, List<(int, int)> ranges)
    {
        var b = new List<byte>(12 + ranges.Count * 4);
        b.AddRange("PCR1"u8.ToArray());
        var t = new byte[4]; Be32(t, 0, token); b.AddRange(t); Be32(t, 0, id); b.AddRange(t);
        foreach (var (s, c) in ranges.Take(300))
        {
            int cc = Math.Min(c, 0xFFFF);
            b.Add((byte)(s >> 8)); b.Add((byte)s); b.Add((byte)(cc >> 8)); b.Add((byte)cc);
        }
        try { sock.Send(b.ToArray()); } catch { }
    }

    void ReceiveLoop()
    {
        var buf = new byte[2048];
        while (running)
        {
            try
            {
                if (sock.Poll(5000, SelectMode.SelectRead))
                {
                    int n = sock.Receive(buf);
                    if (n >= Header && buf[0] == 0xC5) { LastPacketAt = Now; Handle(buf, n); }
                }
            }
            catch (ObjectDisposedException) { break; }
            catch (SocketException) { if (!running) break; Thread.Sleep(50); }
            Pump();
            Chase();
        }
    }

    void Handle(byte[] b, int count)
    {
        bool isRepair = (b[1] & 1) != 0;
        uint id = U32(b, 2); int index = U16(b, 6), n = U16(b, 8), p = U16(b, 10);
        int len = (int)U32(b, 12);
        if (n <= 0 || p <= 0 || len <= 0 || len > n * Shard) return;
        if (next.HasValue && Newer(next.Value, id)) return;
        if (ready.ContainsKey(id)) return;
        if (maxSeen == 0 || Newer(id, maxSeen)) maxSeen = id;
        if (!frames.TryGetValue(id, out var f)) { f = new Frame(n, p, len); frames[id] = f; }
        if (f.N != n || f.P != p) return;
        f.LastAt = Now;
        var body = new byte[count - Header];
        Buffer.BlockCopy(b, Header, body, 0, body.Length);
        if (isRepair) { if (index < p && f.Repair[index] == null) f.Repair[index] = body; }
        else if (index < n && f.Data[index] == null) { f.Data[index] = body; f.HaveData++; }
        if (f.HaveData == f.N) Complete(id, f);
        else if (f.HaveData + f.Repair.Count(r => r != null) >= f.N && Rebuild(f)) { Repaired++; Complete(id, f); }
    }

    void Complete(uint id, Frame f)
    {
        frames.Remove(id);
        var payload = new byte[f.Len];
        int off = 0;
        foreach (var d in f.Data)
        {
            if (d == null) continue;
            int c = Math.Min(d.Length, f.Len - off);
            if (c <= 0) break;
            Buffer.BlockCopy(d, 0, payload, off, c); off += c;
        }
        if (off == f.Len) ready[id] = payload;
    }

    bool Rebuild(Frame f)
    {
        var missing = Enumerable.Range(0, f.N).Where(i => f.Data[i] == null).ToList();
        if (missing.Count == 0) return true;
        var groups = new Dictionary<int, int>();
        foreach (var i in missing) groups[i % f.P] = groups.GetValueOrDefault(i % f.P) + 1;
        if (!groups.All(g => g.Value == 1 && f.Repair[g.Key] != null)) return false;
        foreach (var i in missing)
        {
            int g = i % f.P;
            var x = new byte[Math.Max(Shard, f.Repair[g].Length)];
            Buffer.BlockCopy(f.Repair[g], 0, x, 0, f.Repair[g].Length);
            for (int j = g; j < f.N; j += f.P)
            {
                if (j == i || f.Data[j] == null) continue;
                var d = f.Data[j];
                for (int k = 0; k < d.Length; k++) x[k] ^= d[k];
            }
            int size = i == f.N - 1 ? f.Len - i * Shard : Shard;
            var piece = new byte[Math.Max(0, size)];
            Buffer.BlockCopy(x, 0, piece, 0, piece.Length);
            f.Data[i] = piece; f.HaveData++;
        }
        return true;
    }

    void Pump()
    {
        if (!next.HasValue)
        {
            uint? k = null;
            foreach (var kv in ready)
                if (kv.Value.Length > 0 && kv.Value[0] == 1 && (k == null || Newer(k.Value, kv.Key))) k = kv.Key;
            if (k == null)
            {
                if (ready.Count > 0 || frames.Count > 0) AskKey();
                if (ready.Count > 200) ready.Clear();
                if (frames.Count > 200) frames.Clear();
                return;
            }
            foreach (var old in ready.Keys.Where(id => Newer(k.Value, id)).ToList()) ready.Remove(old);
            foreach (var old in frames.Keys.Where(id => !Newer(id, k.Value)).ToList()) frames.Remove(old);
            next = k;
        }
        while (next.HasValue && ready.Remove(next.Value, out var payload))
        {
            OnFrame?.Invoke(payload);
            next = next.Value + 1;
            stuckSince = 0; asks = 0;
        }
    }

    void Chase()
    {
        if (!next.HasValue || ready.ContainsKey(next.Value)) return;
        uint id = next.Value;
        double now = Now;
        frames.TryGetValue(id, out var f);
        bool newerArrived = Newer(maxSeen, id);
        if (!(newerArrived || (f != null && now - f.LastAt > 0.02))) return;
        if (stuckSince == 0) stuckSince = now;
        if (now - stuckSince > 0.12) { GiveUp(id); return; }
        if (asks != 0 && now - lastAsk <= 0.03) return;
        if (asks == 0) ResentFrames++;
        asks++; lastAsk = now;
        var ranges = new List<(int, int)>();
        if (f != null)
        {
            int i = 0;
            while (i < f.N)
            {
                if (f.Data[i] == null) { int s = i; while (i < f.N && f.Data[i] == null) i++; ranges.Add((s, i - s)); }
                else i++;
            }
        }
        else ranges.Add((0, 0xFFFF));
        AskResend(id, ranges);
    }

    void GiveUp(uint id)
    {
        frames.Remove(id);
        next = null;
        stuckSince = 0; asks = 0;
        Lost++;
        lock (recentLosses) { var n = Now; recentLosses.RemoveAll(t => n - t > 5); recentLosses.Add(n); }
        AskKey();
    }

    void AskKey()
    {
        double now = Now;
        if (now - lastKeyRequest > 0.5) { lastKeyRequest = now; OnNeedKeyframe?.Invoke(); }
    }
}
