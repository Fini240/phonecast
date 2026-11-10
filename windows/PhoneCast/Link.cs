using System.Net;
using System.Net.Sockets;
using System.Text;

namespace PhoneCast;

static class PT
{
    public const byte Format = 0, Config = 1, Frame = 2, Audio = 3, HelloOK = 4, HelloBad = 5, Control = 6, Pong = 7, ResResult = 8,
        Stats = 14, Stopped = 19, UdpToken = 20, UdpOn = 21, UdpOff = 22, Nonce = 23;
}

static class CT
{
    public const byte Hello = 9, Touch = 10, Global = 11, Text = 12, Key = 13, Keyframe = 15, Ping = 16, Settings = 17, Resolution = 18;
}

static class TouchA { public const byte Down = 0, Move = 1, Up = 2, CancelAll = 3; }
static class GlobalA { public const byte Back = 1, Home = 2, Recents = 3, Notifications = 4, QuickSettings = 5, Power = 6, Lock = 7, Screenshot = 8, Split = 9, VolUp = 10, VolDown = 11, Mute = 12, Torch = 13; }

enum LinkState { Connecting, Ready, BadPin, Closed }

/// How this computer logs in: QR pairing (Q1, proven in both directions) and/or the PIN.
sealed record Login(string Pin, string PairId, byte[] PairKey, bool UseQr);

/// One TCP connection to the phone. In: [u8 type][u32 len][payload]. Out: [u8 type][u16 len][payload].
sealed class Link
{
    readonly string host;
    readonly int port;
    TcpClient tcp;
    NetworkStream stream;
    readonly object sendLock = new();
    volatile bool closed;

    /// Called on the reader thread.
    public Action<byte, byte[]> OnPacket;
    public Action<LinkState, string> OnState;
    public IPAddress Remote { get; private set; }

    public Link(string host, int port) { this.host = host; this.port = port; }

    /// The login actually used: true = QR pairing (the phone proved itself too).
    public bool UsedQr { get; private set; }

    public void Start(Login login)
    {
        OnState?.Invoke(LinkState.Connecting, "");
        new Thread(() => Run(login)) { IsBackground = true, Name = "link" }.Start();
    }

    static byte[] Hmac(byte[] key, params byte[][] parts)
    {
        using var h = new System.Security.Cryptography.HMACSHA256(key);
        var all = parts.SelectMany(x => x).ToArray();
        return h.ComputeHash(all);
    }
    static string Hex(byte[] b) => Convert.ToHexString(b).ToLowerInvariant();

    void Run(Login login)
    {
        try
        {
            tcp = new TcpClient(AddressFamily.InterNetworkV6) { NoDelay = true, ReceiveBufferSize = 4 << 20 };
            tcp.Client.DualMode = true;
            var task = tcp.ConnectAsync(host, port);
            if (!task.Wait(6000)) { Finish("unreachable: timed out"); return; }
            if (task.IsFaulted) { Finish("unreachable: " + (task.Exception?.InnerException?.Message ?? "error")); return; }
            var ep = tcp.Client.RemoteEndPoint as IPEndPoint;
            Remote = ep?.Address.IsIPv4MappedToIPv6 == true ? ep.Address.MapToIPv4() : ep?.Address;
            stream = tcp.GetStream();
            var head = new byte[5];

            // Newer phones send a NONCE first; older ones wait for HELLO. Give it 1.5 s.
            byte[] nonce = null;
            tcp.Client.ReceiveTimeout = 1500;
            try
            {
                if (ReadFull(head, 5) && head[0] == PT.Nonce)
                {
                    int nl = head[1] << 24 | head[2] << 16 | head[3] << 8 | head[4];
                    nonce = new byte[nl];
                    if (nl > 64 || !ReadFull(nonce, nl)) { Finish("bad packet"); return; }
                }
                else if (head[0] != 0 || head[1] != 0) { Finish("unexpected first packet"); return; }
            }
            catch (IOException) { /* old phone: no nonce */ }
            tcp.Client.ReceiveTimeout = 0;

            byte[] proofWant = null;
            if (login.UseQr && nonce != null && login.PairKey != null)
            {
                UsedQr = true;
                Send(CT.Hello, Encoding.UTF8.GetBytes($"Q1:{login.PairId}:{Hex(Hmac(login.PairKey, nonce, Encoding.ASCII.GetBytes("phonecast-mirror")))}"));
                proofWant = Hmac(login.PairKey, nonce, Encoding.ASCII.GetBytes("phonecast-phone"));
            }
            else Send(CT.Hello, Encoding.UTF8.GetBytes(login.Pin ?? ""));

            while (!closed)
            {
                if (!ReadFull(head, 5)) { Finish("phone closed the connection"); return; }
                int len = head[1] << 24 | head[2] << 16 | head[3] << 8 | head[4];
                if (len < 0 || len > 64 << 20) { Finish("bad packet"); return; }
                var body = new byte[len];
                if (len > 0 && !ReadFull(body, len)) { Finish("read error"); return; }
                if (head[0] == PT.HelloOK && proofWant != null)
                {
                    // the phone has to prove it knows the secret too (no fake phone on the network)
                    if (body.Length < 33 || !System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(body.AsSpan(1, 32), proofWant))
                    { Finish("this isn't the phone you paired (its proof didn't match)"); return; }
                }
                Deliver(head[0], body);
            }
        }
        catch (Exception e) { Finish(closed ? "disconnected" : "failed: " + e.Message); }
    }

    bool ReadFull(byte[] b, int n)
    {
        int off = 0;
        while (off < n)
        {
            int r = stream.Read(b, off, n - off);
            if (r <= 0) return false;
            off += r;
        }
        return true;
    }

    void Deliver(byte type, byte[] p)
    {
        switch (type)
        {
            case PT.HelloOK: OnState?.Invoke(LinkState.Ready, ""); OnPacket?.Invoke(type, p); break;
            case PT.HelloBad: OnState?.Invoke(LinkState.BadPin, ""); Finish("wrong PIN"); break;
            case PT.Stopped:
                Finish(p.Length > 0 && p[0] == 1
                    ? "the phone locked, and Android ends screen sharing then. Unlock it and allow sharing again"
                    : "sharing was stopped on the phone");
                break;
            default: OnPacket?.Invoke(type, p); break;
        }
    }

    void Finish(string why)
    {
        if (closed) return;
        closed = true;
        try { tcp?.Close(); } catch { }
        OnState?.Invoke(LinkState.Closed, why);
    }

    public void Close(string why = "disconnected") => Finish(why);

    public void Send(byte type, byte[] payload = null)
    {
        if (closed || stream == null) return;
        payload ??= Array.Empty<byte>();
        var d = new byte[3 + payload.Length];
        d[0] = type; d[1] = (byte)(payload.Length >> 8); d[2] = (byte)payload.Length;
        Buffer.BlockCopy(payload, 0, d, 3, payload.Length);
        try { lock (sendLock) stream.Write(d, 0, d.Length); }
        catch { Finish("write error"); }
    }

    public void Touch(byte action, byte id, double x, double y)
    {
        ushort ux = (ushort)(Math.Clamp(x, 0, 1) * 65535), uy = (ushort)(Math.Clamp(y, 0, 1) * 65535);
        Send(CT.Touch, new[] { action, id, (byte)(ux >> 8), (byte)ux, (byte)(uy >> 8), (byte)uy });
    }
}
