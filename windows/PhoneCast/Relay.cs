using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;

namespace PhoneCast;

/// Internet relay, the same as the Mac's Relay.swift: reaches the phone from any network without
/// Tailscale. Phone and PC both dial out to the PhoneCast relay (relay/ in the repo), which pipes bytes.
/// The relay shows up as a local port on 127.0.0.1 (like the USB cable), so Link and HubLink work
/// unchanged. Every tunnel is encrypted end to end (AES-256-GCM, key from the mirror key the phone hands
/// over when linking), on top of the link's TLS. The room comes from that key too, so the PC has to link
/// once on the same Wi-Fi first.
static class Relay
{
    public const string Label = "internet relay";
    public const string DefaultBase = "wss://phonecast-relay.fini240.workers.dev";
    const int Window = 2 << 20, AckEvery = 256 << 10;

    public static string Base => Settings.Str("relayURL") is string s && s != "" ? s : DefaultBase;
    public static bool Enabled => Settings.Bool("relayOn", true);
    static string MirrorKey => Settings.Str("mirrorKey") is string k && k != "" ? k : null;

    public static string Room => MirrorKey is string k
        ? Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("phonecast-relay:" + k))).ToLowerInvariant() : null;

    /// The relay said the phone isn't there (skip it for 30 s) or refused this phone (10 min).
    static DateTime skipUntil = DateTime.MinValue;
    static readonly Dictionary<int, int> localPorts = new();
    static readonly object gate = new();

    /// The local port that tunnels to the phone's port (27183 mirror, 27185 link), or null.
    public static int? LocalPort(int phonePort)
    {
        if (!Enabled || Room == null || DateTime.UtcNow < skipUntil) return null;
        lock (gate)
        {
            if (localPorts.TryGetValue(phonePort, out var p)) return p;
            try
            {
                var l = new TcpListener(IPAddress.Loopback, 0);
                l.Start();
                p = ((IPEndPoint)l.LocalEndpoint).Port;
                localPorts[phonePort] = p;
                new Thread(() => Accept(l, phonePort)) { IsBackground = true, Name = "relay-listen" }.Start();
                return p;
            }
            catch { return null; }
        }
    }

    static void Accept(TcpListener l, int phonePort)
    {
        while (true)
        {
            TcpClient c;
            try { c = l.AcceptTcpClient(); } catch { return; }
            _ = Task.Run(() => Pipe(c, phonePort));
        }
    }

    static async Task Pipe(TcpClient local, int phonePort)
    {
        local.NoDelay = true;
        using var ws = new ClientWebSocket();
        using var cts = new CancellationTokenSource();
        var salt = RandomNumberGenerator.GetBytes(16);
        var crypto = new RelayCrypto(MirrorKey ?? "", salt);
        bool heard = false;
        try
        {
            try { await ws.ConnectAsync(new Uri($"{Base}/v1/{Room}/mac?port={phonePort}"), cts.Token); }
            catch (WebSocketException e)
            {
                // the relay refuses the upgrade: 404 = the phone isn't connected to it, 403 = not on its list
                var code = (int)(ws.HttpStatusCode);
                if (code == 404 || code == 403) skipUntil = DateTime.UtcNow.AddSeconds(code == 403 ? 600 : 30);
                App.Log($"relay: {(code > 0 ? "HTTP " + code : e.Message)}");
                return;
            }
            await ws.SendAsync(Encoding.ASCII.GetBytes("s:" + Convert.ToHexString(salt).ToLowerInvariant()), WebSocketMessageType.Text, true, cts.Token);
            var stream = local.GetStream();
            var sendLock = new SemaphoreSlim(1, 1);
            long unacked = 0;
            var ackSignal = new SemaphoreSlim(0);
            _ = Task.Delay(15000).ContinueWith(_ => { if (!heard) cts.Cancel(); });

            async Task SendWs(byte[] b, WebSocketMessageType t)
            {
                await sendLock.WaitAsync(cts.Token);
                try { await ws.SendAsync(b, t, true, cts.Token); } finally { sendLock.Release(); }
            }

            // PC -> phone
            var up = Task.Run(async () =>
            {
                var buf = new byte[64 * 1024];
                while (true)
                {
                    int n = await stream.ReadAsync(buf, cts.Token);
                    if (n <= 0) break;
                    while (Interlocked.Read(ref unacked) > Window) await ackSignal.WaitAsync(1000, cts.Token);
                    Interlocked.Add(ref unacked, n);
                    await SendWs(crypto.Seal(buf.AsSpan(0, n)), WebSocketMessageType.Binary);
                }
            });
            // phone -> PC
            var down = Task.Run(async () =>
            {
                var buf = new byte[1 << 20];
                int consumed = 0;
                while (true)
                {
                    int len = 0;
                    ValueWebSocketReceiveResult r;
                    while (true)
                    {
                        if (len == buf.Length) Array.Resize(ref buf, buf.Length * 2);
                        r = await ws.ReceiveAsync(buf.AsMemory(len), cts.Token);
                        if (r.MessageType == WebSocketMessageType.Close) return;
                        len += r.Count;
                        if (r.EndOfMessage) break;
                    }
                    if (r.MessageType == WebSocketMessageType.Text)
                    {
                        var s = Encoding.ASCII.GetString(buf, 0, len);
                        if (s.StartsWith("a:") && int.TryParse(s.AsSpan(2), out var a)) { Interlocked.Add(ref unacked, -a); ackSignal.Release(); }
                        continue;
                    }
                    var plain = crypto.Open(buf.AsSpan(0, len));
                    if (plain == null) { App.Log("relay: a message failed the end-to-end check, closing"); return; }
                    heard = true;
                    await stream.WriteAsync(plain, cts.Token);
                    consumed += plain.Length;
                    if (consumed >= AckEvery) { await SendWs(Encoding.ASCII.GetBytes("a:" + consumed), WebSocketMessageType.Text); consumed = 0; }
                }
            });
            await Task.WhenAny(up, down);
        }
        catch { }
        finally
        {
            try { cts.Cancel(); } catch { }
            try { local.Close(); } catch { }
            try { ws.Abort(); } catch { }
        }
    }
}

/// End-to-end encryption of one tunnel, the same as in Relay.swift / Relay.kt:
/// base = HMAC-SHA256(mirrorKey, "phonecast-relay-e2e"); up = HMAC(base, salt‖"up") (computer→phone),
/// down = HMAC(base, salt‖"down"); AES-256-GCM, ciphertext‖tag, nonce = 4 zero bytes ‖ 64-bit counter.
sealed class RelayCrypto
{
    readonly AesGcm up, down;
    ulong sent, received;

    public RelayCrypto(string mirrorKey, byte[] salt)
    {
        var b = HMACSHA256.HashData(Encoding.UTF8.GetBytes(mirrorKey), Encoding.ASCII.GetBytes("phonecast-relay-e2e"));
        up = new AesGcm(HMACSHA256.HashData(b, salt.Concat("up"u8.ToArray()).ToArray()), 16);
        down = new AesGcm(HMACSHA256.HashData(b, salt.Concat("down"u8.ToArray()).ToArray()), 16);
    }

    static byte[] Nonce(ulong n) { var b = new byte[12]; for (int i = 0; i < 8; i++) b[4 + i] = (byte)(n >> (56 - 8 * i)); return b; }

    public byte[] Seal(ReadOnlySpan<byte> plain)
    {
        var o = new byte[plain.Length + 16];
        up.Encrypt(Nonce(sent++), plain, o.AsSpan(0, plain.Length), o.AsSpan(plain.Length));
        return o;
    }

    public byte[] Open(ReadOnlySpan<byte> sealedMsg)
    {
        if (sealedMsg.Length < 16) return null;
        var o = new byte[sealedMsg.Length - 16];
        try { down.Decrypt(Nonce(received), sealedMsg[..^16], sealedMsg[^16..], o); received++; return o; }
        catch (CryptographicException) { return null; }
    }
}
