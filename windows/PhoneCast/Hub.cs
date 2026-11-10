using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json.Nodes;

namespace PhoneCast;

/// The phone's "link" (HubService, TLS on port 27185), next to the mirror: notifications, clipboard,
/// files, now playing, ring, links. Same packets as the Mac: [u8 type][u32 len][payload] both ways.
/// Login: QR pairing (proofs bound to the phone's certificate) or the PIN; the certificate is pinned.
sealed class HubLink
{
    public const int Port = 27185;
    public const byte Hello = 1, HelloOK = 2, HelloBad = 3, Ping = 4, Pong = 5, Status = 6, Nonce = 7,
        Notif = 10, NotifGone = 11, NotifAction = 12,
        FileBegin = 20, FileData = 21, FileEnd = 22, FileCancel = 23,
        Clip = 30, CastReady = 40, CastStopped = 41, CastRequest = 42,
        Req = 70, Resp = 71, Event = 72;
    public const int ClipImageReq = 9002;

    readonly string host;
    TcpClient tcp;
    SslStream ssl;
    readonly object sendLock = new();
    volatile bool closed;
    string seenFp;

    /// Called on the hub's reader thread.
    public Action<byte, byte[]> OnPacket;
    /// ok, reason ("qr" = phone doesn't know our QR code, "locked", "pin", "key" = a different phone, or an error)
    public Action<bool, string> OnLogin;
    public Action<string> OnClosed;
    public bool UsedQr { get; private set; }
    public string PhoneName { get; private set; } = "phone";

    public HubLink(string host) { this.host = host; }

    public static string Fingerprint(X509Certificate c) => Convert.ToHexString(SHA256.HashData(c.GetRawCertData()));

    public void Start(Login login) => new Thread(() => Run(login)) { IsBackground = true, Name = "hub" }.Start();

    void Run(Login login)
    {
        try
        {
            tcp = new TcpClient(AddressFamily.InterNetworkV6) { NoDelay = true };
            tcp.Client.DualMode = true;
            var t = tcp.ConnectAsync(host, Port);
            if (!t.Wait(5000) || t.IsFaulted) { Finish("unreachable"); return; }
            string pinned = Settings.Str("phoneKey");
            ssl = new SslStream(tcp.GetStream(), false, (_, cert, _, _) =>
            {
                if (cert == null) return false;
                seenFp = Fingerprint(cert);
                // after the first pairing only that phone's key is accepted
                return pinned == null || pinned == seenFp;
            });
            // the OS picks the newest TLS; the phone itself only accepts TLS 1.3
            ssl.AuthenticateAsClient(new SslClientAuthenticationOptions { TargetHost = "PhoneCast" });
            tcp.ReceiveTimeout = 1500;
            byte[] nonce = null;
            var (pt, pp) = Read();
            if (pt == Nonce) nonce = pp;
            tcp.ReceiveTimeout = 15000; // the phone pings back; we ping every second

            var hello = new JsonObject { ["name"] = Environment.MachineName, ["os"] = "windows" };
            if (login.UseQr && nonce != null && login.PairKey != null)
            {
                UsedQr = true;
                hello["qr"] = login.PairId;
                hello["proof"] = Hex(Hmac(login.PairKey, nonce, A("phonecast-hub"), A(seenFp)));
                if (pinned != null && !string.IsNullOrEmpty(login.Pin)) hello["pin"] = login.Pin;
            }
            else hello["pin"] = login.Pin ?? "";
            Send(Hello, Encoding.UTF8.GetBytes(hello.ToJsonString()));

            while (!closed)
            {
                var (type, p) = Read();
                if (type == HelloBad)
                {
                    var why = Encoding.UTF8.GetString(p);
                    OnLogin?.Invoke(false, why == "" ? "pin" : why);
                    Finish("refused"); return;
                }
                if (type == HelloOK)
                {
                    var o = JsonNode.Parse(Encoding.UTF8.GetString(p)) as JsonObject ?? new JsonObject();
                    PhoneName = (string)o["name"] ?? "phone";
                    if (UsedQr && o["proof"] is not null)
                    {
                        var want = Hex(Hmac(login.PairKey, nonce, A("phonecast-hub-phone"), A(seenFp)));
                        if (!CryptographicOperations.FixedTimeEquals(A(((string)o["proof"]).ToLowerInvariant()), A(want)))
                        { OnLogin?.Invoke(false, "key"); Finish("not the paired phone"); return; }
                    }
                    else if (UsedQr && o["pin"] is null && hello["pin"] is null)
                    { OnLogin?.Invoke(false, "key"); Finish("the phone didn't prove itself"); return; }
                    if (pinned == null && seenFp != null) Settings.Set("phoneKey", seenFp); // first pairing: remember this phone
                    OnLogin?.Invoke(true, "");
                    new Thread(PingLoop) { IsBackground = true, Name = "hub-ping" }.Start();
                    continue;
                }
                if (type == Ping) { Send(Pong, p); continue; }
                OnPacket?.Invoke(type, p);
            }
        }
        catch (Exception e) { Finish(closed ? "closed" : e.InnerException != null ? e.Message + " / " + e.InnerException.Message + " " + e.InnerException.HResult.ToString("X") : e.Message); }
    }

    void PingLoop()
    {
        while (!closed)
        {
            Send(Ping, BitConverter.GetBytes(Environment.TickCount64));
            Thread.Sleep(1000);
        }
    }

    (byte, byte[]) Read()
    {
        var h = new byte[5];
        ReadFull(h);
        int len = h[1] << 24 | h[2] << 16 | h[3] << 8 | h[4];
        if (len < 0 || len > 64 << 20) throw new IOException("bad length");
        var b = new byte[len];
        ReadFull(b);
        return (h[0], b);
    }

    void ReadFull(byte[] b)
    {
        int off = 0;
        while (off < b.Length) { int n = ssl.Read(b, off, b.Length - off); if (n <= 0) throw new IOException("closed"); off += n; }
    }

    public void Send(byte type, byte[] p)
    {
        if (closed || ssl == null) return;
        var f = new byte[5 + p.Length];
        f[0] = type; f[1] = (byte)(p.Length >> 24); f[2] = (byte)(p.Length >> 16); f[3] = (byte)(p.Length >> 8); f[4] = (byte)p.Length;
        Buffer.BlockCopy(p, 0, f, 5, p.Length);
        try { lock (sendLock) { ssl.Write(f); ssl.Flush(); } } catch { Finish("write error"); }
    }

    public void SendJson(byte type, JsonObject o) => Send(type, Encoding.UTF8.GetBytes(o.ToJsonString()));

    public void Close() => Finish("closed");

    void Finish(string why)
    {
        if (closed) return;
        closed = true;
        try { ssl?.Dispose(); } catch { }
        try { tcp?.Close(); } catch { }
        OnClosed?.Invoke(why);
    }

    static byte[] A(string s) => Encoding.ASCII.GetBytes(s ?? "");
    static string Hex(byte[] b) => Convert.ToHexString(b).ToLowerInvariant();
    static byte[] Hmac(byte[] key, params byte[][] parts) { using var h = new HMACSHA256(key); return h.ComputeHash(parts.SelectMany(x => x).ToArray()); }
}
