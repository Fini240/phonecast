using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;

namespace PhoneCast;

/// "Phone in File Explorer": the phone's storage as a drive letter. The phone runs a WebDAV server on request
/// (webdav.start, WebDav.kt: plain HTTP with Basic sign-in). Windows' WebDAV client refuses Basic sign-in over plain
/// HTTP unless an admin changes the registry, so PhoneCast runs a tiny relay on 127.0.0.1 that adds the sign-in to
/// every request, and maps \\localhost@port\DavWWWRoot to a free drive letter. The phone stops its server after
/// 30 minutes without use; opening it again starts it again.
static class PhoneDrive
{
    static TcpListener listener;
    static int localPort;
    static volatile string target;   // host:port of the phone's server
    static volatile string auth;     // "Basic …"

    /// Any thread; banners and Explorer on the UI thread.
    public static void Open()
    {
        var s = Store.Shared;
        if (!s.Connected) { Banners.Info(tr("Phone not connected"), ""); return; }
        s.Link.Request("webdav.start", new JsonObject(), r =>
        {
            if (!r.Ok)
            {
                Banners.Info(tr("Couldn't open the phone in File Explorer"),
                    r.Permission ? tr("On the phone: PhoneCast → Settings → Allow browsing phone files.") : r.Error);
                return;
            }
            var d = r.Data as JsonObject;
            int port = (int?)d?["port"] ?? 0;
            string user = (string)d?["user"], pass = (string)d?["pass"], host = (string)d?["host"];
            if (string.IsNullOrEmpty(host)) host = Settings.Str("host");
            if (port == 0 || user == null || pass == null || string.IsNullOrEmpty(host)) { Banners.Info(tr("Couldn't open the phone in File Explorer"), tr("The phone gave no address.")); return; }
            target = (host.Contains(':') ? $"[{host}]" : host) + ":" + port;
            auth = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(user + ":" + pass));
            Task.Run(() =>
            {
                try
                {
                    EnsureRelay();
                    var letter = Mount();
                    Ui.Post(() =>
                    {
                        if (letter != null) Ui.Shell(letter + "\\");
                        else Banners.Info(tr("Couldn't map the phone as a drive"), tr("Windows' WebDAV client (the WebClient service) didn't answer."));
                    });
                }
                catch (Exception e) { App.Log("phone drive: " + e); Ui.Post(() => Banners.Info(tr("Couldn't open the phone in File Explorer"), e.Message)); }
            });
        }, 20);
    }

    static string Unc => $@"\\localhost@{localPort}\DavWWWRoot";

    /// The drive letter that already shows the phone, else maps a free one.
    static string Mount()
    {
        var (_, list) = Run("net.exe", "use");
        foreach (var line in list.Split('\n'))
            if (line.Contains($"localhost@{localPort}", StringComparison.OrdinalIgnoreCase) && line.Contains(':'))
            {
                var i = line.IndexOf(':');
                if (i >= 1 && char.IsLetter(line[i - 1])) return line[i - 1] + ":";
            }
        // WebClient is a trigger-start service: touching the path wakes it up
        try { Directory.Exists(Unc); } catch { }
        var used = DriveInfo.GetDrives().Select(x => char.ToUpperInvariant(x.Name[0])).ToHashSet();
        foreach (var c in "PQRSTUVWXYZ")
        {
            if (used.Contains(c)) continue;
            var (ok, outp) = Run("net.exe", $"use {c}: \"{Unc}\" /persistent:no");
            App.Log($"phone drive: net use {c}: -> {ok} {outp.Trim()}");
            if (ok) { Label(c); return c + ":"; }
            break;
        }
        // mapping failed: Explorer can still open the share path itself
        return Directory.Exists(Unc) ? Unc : null;
    }

    /// Explorer shows the drive as "Phone (Finn's Z Fold7)" instead of "DavWWWRoot".
    static void Label(char letter)
    {
        try
        {
            var key = $@"Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##localhost@{localPort}#DavWWWRoot";
            using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(key);
            k?.SetValue("_LabelFromReg", tr("Phone ({0})", Store.Shared.PhoneName));
        }
        catch { }
    }

    static (bool, string) Run(string exe, string args)
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(exe, args) { CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true });
            var o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            p.WaitForExit(30000);
            return (p.ExitCode == 0, o);
        }
        catch (Exception e) { return (false, e.Message); }
    }

    // ---------- relay: 127.0.0.1 -> phone, adds the Authorization header ----------

    static void EnsureRelay()
    {
        if (listener != null) return;
        // the same port every time if it's free, so a remembered drive path keeps working
        foreach (var p in new[] { 27191, 0 })
        {
            try { listener = new TcpListener(IPAddress.Loopback, p); listener.Start(); break; }
            catch { listener = null; }
        }
        if (listener == null) throw new Exception("no local port");
        localPort = ((IPEndPoint)listener.LocalEndpoint).Port;
        App.Log($"phone drive: relay on 127.0.0.1:{localPort}");
        new Thread(() =>
        {
            while (true)
            {
                TcpClient c;
                try { c = listener.AcceptTcpClient(); } catch { return; }
                new Thread(() => Serve(c)) { IsBackground = true, Name = "drive-conn" }.Start();
            }
        }) { IsBackground = true, Name = "drive-relay" }.Start();
    }

    static void Serve(TcpClient client)
    {
        using var _c = client;
        var t = target;
        if (t == null) return;
        var i = t.LastIndexOf(':');
        using var phone = new TcpClient();
        try { phone.Connect(t[..i].Trim('[', ']'), int.Parse(t[(i + 1)..])); } catch (Exception e) { App.Log("phone drive: " + e.Message); return; }
        phone.NoDelay = true; client.NoDelay = true;
        var cs = client.GetStream(); var ps = phone.GetStream();
        // answers go straight back
        var back = new Thread(() => { try { ps.CopyTo(cs); } catch { } try { client.Close(); } catch { } }) { IsBackground = true };
        back.Start();
        try
        {
            while (true)
            {
                var head = ReadHead(cs);
                if (head == null) break;
                // replace any sign-in header and the Host, then pass the body through
                var lines = head.Split("\r\n").Where(l => l.Length > 0).ToList();
                long len = 0; bool chunked = false;
                var outp = new StringBuilder(lines[0] + "\r\n");
                foreach (var l in lines.Skip(1))
                {
                    var k = l.Split(':', 2)[0].Trim().ToLowerInvariant();
                    if (k is "authorization" or "host") continue;
                    if (k == "content-length") long.TryParse(l.Split(':', 2)[1].Trim(), out len);
                    if (k == "transfer-encoding" && l.Contains("chunked", StringComparison.OrdinalIgnoreCase)) chunked = true;
                    outp.Append(l).Append("\r\n");
                }
                outp.Append("Host: ").Append(t).Append("\r\nAuthorization: ").Append(auth).Append("\r\n\r\n");
                var hb = Encoding.ASCII.GetBytes(outp.ToString());
                ps.Write(hb);
                if (chunked) CopyChunked(cs, ps);
                else CopyN(cs, ps, len);
            }
        }
        catch { }
        try { phone.Close(); } catch { }
    }

    static string ReadHead(Stream s)
    {
        var b = new List<byte>(1024);
        int c, state = 0;
        while ((c = s.ReadByte()) >= 0)
        {
            b.Add((byte)c);
            state = (state, c) switch { (0, '\r') => 1, (1, '\n') => 2, (2, '\r') => 3, (3, '\n') => 4, (_, '\r') => 1, _ => 0 };
            if (state == 4) return Encoding.ASCII.GetString(b.ToArray());
            if (b.Count > 64 * 1024) return null;
        }
        return null;
    }

    static void CopyN(Stream from, Stream to, long n)
    {
        var buf = new byte[81920];
        while (n > 0)
        {
            int r = from.Read(buf, 0, (int)Math.Min(buf.Length, n));
            if (r <= 0) throw new IOException("closed");
            to.Write(buf, 0, r); n -= r;
        }
    }

    static void CopyChunked(Stream from, Stream to)
    {
        while (true)
        {
            var line = ReadLine(from);
            to.Write(Encoding.ASCII.GetBytes(line + "\r\n"));
            long size = Convert.ToInt64(line.Split(';')[0].Trim(), 16);
            if (size == 0) { to.Write(Encoding.ASCII.GetBytes(ReadLine(from) + "\r\n")); return; }
            CopyN(from, to, size + 2);
        }
    }

    static string ReadLine(Stream s)
    {
        var sb = new StringBuilder();
        int c;
        while ((c = s.ReadByte()) >= 0) { if (c == '\n') break; if (c != '\r') sb.Append((char)c); }
        return sb.ToString();
    }
}
