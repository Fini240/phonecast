using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace PhoneCast;

/// "Phone in a browser": the phone's notifications and text messages on any device in your network (iPad, school
/// laptop) at http://<this PC>:27190/phone, through this PC's link to the phone. Off until turned on in Settings;
/// sign-in with the 6-digit code shown there (new every start), then a cookie. Like the Mac's PhoneWeb.
static class PhoneWeb
{
    public const int Port = 27190;
    static TcpListener listener;
    static readonly HashSet<string> tokens = new();
    static int wrong;
    static DateTime lockedUntil;
    public static string Code { get; private set; } = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
    public static bool Running => listener != null;

    public static void NewCode() { Code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6"); lock (tokens) tokens.Clear(); }

    public static void Apply()
    {
        if (Settings.Bool("phoneWeb")) Start(); else Stop();
    }

    static void Start()
    {
        if (listener != null) return;
        try
        {
            // PHONECAST_WEB_LOOPBACK=1 (tests): only this PC, so Windows' firewall doesn't ask
            bool loop = Environment.GetEnvironmentVariable("PHONECAST_WEB_LOOPBACK") == "1";
            listener = new TcpListener(loop ? IPAddress.IPv6Loopback : IPAddress.IPv6Any, Port);
            listener.Server.DualMode = true;
            listener.Start();
        }
        catch (Exception e) { App.Log("phone web: " + e.Message); listener = null; Banners.Info(tr("Couldn't start the phone page"), e.Message); return; }
        App.Log("phone web: on :" + Port);
        var l = listener;
        new Thread(() =>
        {
            while (true)
            {
                TcpClient c;
                try { c = l.AcceptTcpClient(); } catch { return; }
                new Thread(() => Serve(c)) { IsBackground = true, Name = "phoneweb-conn" }.Start();
            }
        }) { IsBackground = true, Name = "phoneweb" }.Start();
    }

    static void Stop()
    {
        try { listener?.Stop(); } catch { }
        listener = null;
    }

    /// Addresses others can open (for Settings).
    public static IEnumerable<string> Urls()
    {
        foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
            foreach (var a in ni.GetIPProperties().UnicastAddresses)
                if (a.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a.Address))
                    yield return $"http://{a.Address}:{Port}/phone";
        }
    }

    static void Serve(TcpClient c)
    {
        using var _ = c;
        c.ReceiveTimeout = 15000;
        var s = c.GetStream();
        try
        {
            while (true)
            {
                var head = ReadHead(s);
                if (head == null) return;
                var lines = head.Split("\r\n");
                var parts = lines[0].Split(' ');
                if (parts.Length < 2) return;
                string method = parts[0], path = parts[1].Split('?')[0];
                var h = lines.Skip(1).Where(x => x.Contains(':')).ToDictionary(x => x.Split(':', 2)[0].Trim().ToLowerInvariant(), x => x.Split(':', 2)[1].Trim(), StringComparer.Ordinal);
                int len = h.TryGetValue("content-length", out var cl) && int.TryParse(cl, out var n) ? Math.Min(n, 1 << 20) : 0;
                var body = new byte[len];
                for (int o = 0; o < len;) { int r = s.Read(body, o, len - o); if (r <= 0) return; o += r; }
                bool signedIn = h.TryGetValue("cookie", out var ck) && ck.Split(';').Select(x => x.Trim()).Any(x => x.StartsWith("pcp=") && Has(x[4..]));

                switch ((method, path))
                {
                    case ("GET", "/"): Respond(s, 302, "text/plain", Array.Empty<byte>(), "Location: /phone\r\n"); break;
                    case ("GET", "/phone"): Respond(s, 200, "text/html; charset=utf-8", Encoding.UTF8.GetBytes(PhoneWebPage.Html), "Cache-Control: no-store\r\n"); break;
                    case ("POST", "/login"):
                        {
                            var o = Parse(body);
                            if (DateTime.Now < lockedUntil) { Json(s, 429, new JsonObject { ["ok"] = false, ["message"] = "Too many wrong codes. Wait a few minutes." }); break; }
                            var given = new string(((string)o?["code"] ?? "").Where(char.IsDigit).ToArray());
                            if (given == Code)
                            {
                                wrong = 0;
                                var t = Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
                                lock (tokens) tokens.Add(t);
                                Json(s, 200, new JsonObject { ["ok"] = true }, $"Set-Cookie: pcp={t}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000\r\n");
                                App.Log("phone web: signed in from " + c.Client.RemoteEndPoint);
                            }
                            else
                            {
                                if (++wrong >= 5) { lockedUntil = DateTime.Now.AddMinutes(5); wrong = 0; }
                                Json(s, 401, new JsonObject { ["ok"] = false, ["message"] = "Wrong code." });
                            }
                            break;
                        }
                    case ("POST", "/phoneapi"):
                        if (!signedIn) { Json(s, 401, new JsonObject { ["ok"] = false, ["message"] = "Sign in first." }); break; }
                        Json(s, 200, Handle(Parse(body)));
                        break;
                    default: Respond(s, 404, "text/plain", Encoding.UTF8.GetBytes("not found")); break;
                }
                if (h.TryGetValue("connection", out var conn) && conn.Equals("close", StringComparison.OrdinalIgnoreCase)) return;
            }
        }
        catch { }
    }

    static bool Has(string t) { lock (tokens) return tokens.Contains(t); }
    static JsonObject Parse(byte[] b) { try { return JsonNode.Parse(Encoding.UTF8.GetString(b)) as JsonObject; } catch { return null; } }

    /// One API call from the page: {m, p}.
    static JsonObject Handle(JsonObject o)
    {
        string m = (string)o?["m"] ?? "";
        var p = o?["p"] as JsonObject ?? new JsonObject();
        var S = Store.Shared;
        JsonObject OnUi(Func<JsonObject> f)
        {
            var done = new TaskCompletionSource<JsonObject>();
            Ui.Post(() => { try { done.SetResult(f()); } catch (Exception e) { done.SetResult(new JsonObject { ["ok"] = false, ["message"] = e.Message }); } });
            return done.Task.Wait(5000) ? done.Task.Result : new JsonObject { ["ok"] = false, ["message"] = "busy" };
        }
        JsonObject Proxy(string method, JsonObject prm)
        {
            if (!S.Connected) return new JsonObject { ["ok"] = false, ["message"] = "The phone isn't connected to the PC." };
            var done = new TaskCompletionSource<JsonObject>();
            Ui.Post(() => S.Link.Request(method, prm, r => done.TrySetResult(r.Ok
                ? new JsonObject { ["ok"] = true, ["data"] = r.Data?.DeepClone() }
                : new JsonObject { ["ok"] = false, ["message"] = r.Permission ? "Allow this in the PhoneCast app on the phone." : r.Error })));
            return done.Task.Wait(35000) ? done.Task.Result : new JsonObject { ["ok"] = false, ["message"] = "The phone didn't answer." };
        }
        switch (m)
        {
            case "status":
                return OnUi(() => new JsonObject { ["ok"] = true, ["data"] = new JsonObject { ["connected"] = S.Connected, ["phone"] = S.PhoneName, ["battery"] = S.Status["battery"]?.DeepClone() } });
            case "notifs":
                return OnUi(() =>
                {
                    var a = new JsonArray();
                    foreach (var n in S.Notifs.Take(150))
                        a.Add(new JsonObject { ["key"] = n.Key, ["app"] = n.App, ["title"] = n.Title, ["text"] = n.Text,
                            ["date"] = new DateTimeOffset(n.When).ToUnixTimeMilliseconds(), ["canReply"] = n.CanReply });
                    return new JsonObject { ["ok"] = true, ["data"] = a };
                });
            case "notif.action":
                {
                    string key = (string)p["key"] ?? "", action = (string)p["action"] ?? "";
                    if (key == "" || action is not ("reply" or "dismiss" or "open")) return new JsonObject { ["ok"] = false, ["message"] = "bad action" };
                    return OnUi(() =>
                    {
                        S.Link.NotifAction(key, action, (string)p["text"] ?? "");
                        if (action == "dismiss") { S.Notifs.RemoveAll(x => x.Key == key); S.Fire("notifications"); }
                        return new JsonObject { ["ok"] = true };
                    });
                }
            case "threads": return Proxy("sms.threads", new JsonObject { ["limit"] = 80 });
            case "thread": return Proxy("sms.thread", new JsonObject { ["thread"] = p["thread"]?.DeepClone() ?? 0, ["limit"] = 150 });
            case "send":
                {
                    string to = (string)p["to"] ?? "", text = (string)p["text"] ?? "";
                    if (to == "" || text == "") return new JsonObject { ["ok"] = false, ["message"] = "Number and text needed." };
                    return Proxy("sms.send", new JsonObject { ["to"] = to, ["text"] = text });
                }
            case "ring": return Proxy("phone.ring", new JsonObject { ["on"] = (bool?)p["on"] ?? true });
        }
        return new JsonObject { ["ok"] = false, ["message"] = "unknown request" };
    }

    static void Json(Stream s, int status, JsonObject o, string extra = "") =>
        Respond(s, status, "application/json", Encoding.UTF8.GetBytes(o.ToJsonString()), extra);

    static void Respond(Stream s, int status, string type, byte[] body, string extra = "")
    {
        var reason = status switch { 200 => "OK", 302 => "Found", 401 => "Unauthorized", 404 => "Not Found", 429 => "Too Many Requests", _ => "OK" };
        var head = $"HTTP/1.1 {status} {reason}\r\nContent-Type: {type}\r\nContent-Length: {body.Length}\r\n{extra}\r\n";
        s.Write(Encoding.ASCII.GetBytes(head));
        s.Write(body);
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
            if (b.Count > 32 * 1024) return null;
        }
        return null;
    }
}
