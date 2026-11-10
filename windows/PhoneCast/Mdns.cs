using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace PhoneCast;

/// Finds phones sharing on this network (Bonjour "_phonecast._tcp") with one-shot mDNS queries: sent
/// from an ordinary port, so responders answer us directly and Windows' own mDNS service is untouched.
sealed class MdnsBrowser
{
    public sealed record Found(string Name, IPAddress Address, int Port, DateTime Seen);
    readonly Dictionary<string, Found> found = new();
    volatile bool running;

    public List<Found> Current()
    {
        lock (found)
        {
            foreach (var k in found.Where(kv => DateTime.UtcNow - kv.Value.Seen > TimeSpan.FromSeconds(20)).Select(kv => kv.Key).ToList()) found.Remove(k);
            return found.Values.OrderBy(f => f.Name).ToList();
        }
    }

    public void Start()
    {
        running = true;
        new Thread(Loop) { IsBackground = true, Name = "mdns" }.Start();
    }

    public void Stop() => running = false;

    static readonly byte[] Query = BuildQuery();

    static byte[] BuildQuery()
    {
        var b = new List<byte> { 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
        foreach (var l in new[] { "_phonecast", "_tcp", "local" }) { b.Add((byte)l.Length); b.AddRange(Encoding.ASCII.GetBytes(l)); }
        b.Add(0);
        b.AddRange(new byte[] { 0, 12, 0x80, 1 }); // PTR, IN with "unicast response" bit
        return b.ToArray();
    }

    void Loop()
    {
        while (running)
        {
            var sockets = new List<Socket>();
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        try
                        {
                            var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                            s.Bind(new IPEndPoint(ua.Address, 0));
                            s.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, ua.Address.GetAddressBytes());
                            s.SendTo(Query, new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353));
                            sockets.Add(s);
                        }
                        catch { }
                    }
                }
                var until = DateTime.UtcNow.AddSeconds(1.5);
                var buf = new byte[9000];
                while (DateTime.UtcNow < until && sockets.Count > 0)
                {
                    var ready = sockets.ToList();
                    Socket.Select(ready, null, null, 200_000);
                    foreach (var s in ready)
                    {
                        EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                        try { int n = s.ReceiveFrom(buf, ref from); Parse(buf, n, ((IPEndPoint)from).Address); } catch { }
                    }
                }
            }
            catch { }
            foreach (var s in sockets) try { s.Close(); } catch { }
            for (int i = 0; i < 30 && running; i++) Thread.Sleep(100);
        }
    }

    static string ReadName(byte[] b, ref int i, int n)
    {
        var labels = new List<string>();
        int jumps = 0, pos = i;
        bool jumped = false;
        while (pos < n && jumps < 20)
        {
            int len = b[pos];
            if (len == 0) { pos++; break; }
            if ((len & 0xC0) == 0xC0)
            {
                if (pos + 1 >= n) break;
                int ptr = (len & 0x3F) << 8 | b[pos + 1];
                if (!jumped) i = pos + 2;
                jumped = true; jumps++; pos = ptr; continue;
            }
            pos++;
            if (pos + len > n) break;
            labels.Add(Encoding.UTF8.GetString(b, pos, len));
            pos += len;
        }
        if (!jumped) i = pos;
        return string.Join(".", labels);
    }

    void Parse(byte[] b, int n, IPAddress from)
    {
        if (n < 12) return;
        int qd = b[4] << 8 | b[5], an = b[6] << 8 | b[7], ns = b[8] << 8 | b[9], ar = b[10] << 8 | b[11];
        int i = 12;
        for (int q = 0; q < qd; q++) { ReadName(b, ref i, n); i += 4; }
        var ptrs = new List<string>();
        var srv = new Dictionary<string, (int port, string target)>();
        var a = new Dictionary<string, IPAddress>();
        for (int r = 0; r < an + ns + ar && i + 10 <= n; r++)
        {
            string name = ReadName(b, ref i, n);
            if (i + 10 > n) break;
            int type = b[i] << 8 | b[i + 1];
            int rdlen = b[i + 8] << 8 | b[i + 9];
            int rd = i + 10;
            if (rd + rdlen > n) break;
            if (type == 12) { int j = rd; ptrs.Add(ReadName(b, ref j, n)); }
            else if (type == 33 && rdlen >= 7) { int j = rd + 6; srv[name] = (b[rd + 4] << 8 | b[rd + 5], ReadName(b, ref j, n)); }
            else if (type == 1 && rdlen == 4) a[name] = new IPAddress(new[] { b[rd], b[rd + 1], b[rd + 2], b[rd + 3] });
            i = rd + rdlen;
        }
        foreach (var full in ptrs.Concat(srv.Keys).Distinct())
        {
            if (!full.EndsWith("._phonecast._tcp.local", StringComparison.OrdinalIgnoreCase)) continue;
            string label = full[..^"._phonecast._tcp.local".Length];
            int port = 27183;
            var ip = from;
            if (srv.TryGetValue(full, out var s)) { port = s.port; if (a.TryGetValue(s.target, out var ia)) ip = ia; }
            lock (found) found[label] = new Found(label, ip, port, DateTime.UtcNow);
        }
    }
}
