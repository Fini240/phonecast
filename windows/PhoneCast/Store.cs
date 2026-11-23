using System.Drawing;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PhoneCast;

/// An answer from the phone to a request (see the phone's Features.kt).
sealed record Reply(bool Ok, JsonNode Data, string Error, bool Permission);

/// What the window can ask of the connection (App implements it; every method is thread-safe and
/// callbacks come back on the UI thread).
interface IPhoneLink
{
    void Request(string m, JsonObject p, Action<Reply> done, double timeout = 30);
    /// Ask for a photo or file; [then] gets the local path once it has arrived ([keep] = Downloads, else temp).
    void FetchFile(string m, JsonObject p, bool keep, Action<string> then);
    void NotifAction(string key, string action, string text = "");
    void SendClipText(string text);
    void SendClipImage(Image img);
    void SendFiles(string[] paths, string dir = null);
    void Mirror();
    void ShowPairing();
    /// This PC's status for the phone (battery, CPU, stay awake…): its PC tab shows it.
    void SendStatus(JsonObject o);
    void ShowConnect();
    void ForgetPhoneKey();
    void NewPairCode();
    void ToggleRecording();
    bool Recording { get; }
    bool MirrorConnected { get; }
    string PairCode();
    void Quit();
}

/// Everything the PhoneCast window shows, owned by the UI thread (the Windows twin of the Mac's Store).
sealed class Store
{
    public static readonly Store Shared = new();
    public IPhoneLink Link;
    /// Something changed: "status", "notifications", "messages", "thread", "calls", "contacts", "photos",
    /// "files", "apps", "transfers", "media", "call", "settings", "devices", "pc", "recording".
    public event Action<string> Changed;
    public void Fire(string what) { try { Changed?.Invoke(what); } catch (Exception e) { App.Log("ui fire: " + e); } }

    // ---------- connection / phone ----------
    public bool Connected;
    public string PhoneName = "Phone";
    public JsonObject Status = new();
    public Dictionary<string, bool> Perms = new();
    public double Rtt = -1;
    public bool PhoneCasting, Ringing, PhoneDnd;
    public string LinkState = tr("Looking for the phone…");

    public void SetConnected(bool on, string name)
    {
        bool was = Connected;
        Connected = on;
        if (name != null) PhoneName = name;
        LinkState = on ? tr("Connected") : tr("Looking for the phone…");
        if (!on) { Rtt = -1; Ringing = false; Media = null; Art = null; Call = null; Banners.EndCall(); }
        Fire("status");
        if (on && !was) RefreshAll();
    }

    public void ApplyStatus(JsonObject o)
    {
        Status = o;
        Desk.Shared.Update(o);
        PhoneCasting = (bool?)o["casting"] ?? false;
        bool dnd = (bool?)o["dnd"] ?? false;
        bool dndChanged = dnd != PhoneDnd;
        PhoneDnd = dnd;
        if ((string)o["name"] is string n) PhoneName = n;
        if (o["perms"] is JsonObject p)
        {
            var newly = new List<string>();
            foreach (var (k, v) in p)
            {
                bool ok = v?.GetValueKind() == JsonValueKind.True;
                if (ok && !Perms.GetValueOrDefault(k)) newly.Add(k);
                Perms[k] = ok;
            }
            if (newly.Count > 0 && Connected && Perms.Count > newly.Count) RefreshAll(newly.ToHashSet());
        }
        Fire("status");
        if (dndChanged) Fire("settings");
    }

    public string PhoneSummary
    {
        get
        {
            var p = new List<string>();
            if ((int?)Status["battery"] is int b) p.Add($"{b} %" + (((bool?)Status["charging"] ?? false) ? " ⚡" : ""));
            if (Status["batteryTemp"] is JsonNode t) p.Add($"{(double)t:0} °C");
            if ((string)Status["net"] is string n) p.Add(n);
            return string.Join(" · ", p);
        }
    }

    // ---------- the website the phone's browser has open (continue it here) ----------
    public sealed record PhoneWebInfo(string Url, string App, bool Front, DateTime At)
    {
        public string Short
        {
            get
            {
                if (!Uri.TryCreate(Url, UriKind.Absolute, out var u)) return Url;
                var host = u.Host.StartsWith("www.") ? u.Host[4..] : u.Host;
                var rest = u.PathAndQuery == "/" ? "" : Uri.UnescapeDataString(u.PathAndQuery);
                return host + rest;
            }
        }
    }

    /// The Accessibility service (mouse & keyboard) is on on the phone: it reads the browser's address.
    public bool PhoneControl => (bool?)Status["control"] ?? false;

    public PhoneWebInfo PhoneWeb
    {
        get
        {
            if (!Connected || Status["web"] is not JsonObject w || (string)w["url"] is not string u) return null;
            if (!Uri.TryCreate(u, UriKind.Absolute, out var uri) || (uri.Scheme != "https" && uri.Scheme != "http")) return null;
            var at = w["at"] is JsonNode a ? DateTimeOffset.FromUnixTimeSeconds((long)(double)a).LocalDateTime : DateTime.Now;
            return new PhoneWebInfo(u, (string)w["app"] ?? "", (bool?)w["front"] ?? false, at);
        }
    }

    /// "Open on PC": ask the phone for the full address first (Samsung Internet shows only the domain; the phone reads
    /// the whole one from its address bar), else open what the status had.
    public void OpenPhoneWeb()
    {
        var w = PhoneWeb;
        if (w == null) return;
        if (!w.Front) { Ui.Shell(w.Url); return; }
        Link.Request("web.url", new JsonObject(), r =>
        {
            var fresh = r.Ok && r.Data is JsonValue v && v.TryGetValue<string>(out var s) && (s.StartsWith("https://") || s.StartsWith("http://")) ? s : null;
            Ui.Shell(fresh ?? w.Url);
        }, 4);
    }

    // ---------- notifications ----------
    public sealed class Notif
    {
        public string Key, Pkg, App, Title, Text;
        public DateTime When;
        public bool CanReply;
    }
    public readonly List<Notif> Notifs = new();
    public readonly Dictionary<string, Image> Icons = new();

    public bool MuteAll { get => Settings.Bool("muteAll"); set { Settings.Set("muteAll", value); Fire("settings"); } }
    public bool NotifSound { get => Settings.Bool("notifSound", true); set => Settings.Set("notifSound", value); }
    public bool FollowPhoneDnd { get => Settings.Bool("followPhoneDnd", true); set { Settings.Set("followPhoneDnd", value); Fire("settings"); } }
    public bool QuietHours { get => Settings.Bool("quietHours"); set { Settings.Set("quietHours", value); Fire("settings"); } }
    public int QuietFrom { get => Settings.Int("quietFrom", 22); set => Settings.Set("quietFrom", value); }
    public int QuietTo { get => Settings.Int("quietTo", 7); set => Settings.Set("quietTo", value); }
    public bool AutoClipboard { get => Settings.Bool("autoClipboard"); set => Settings.Set("autoClipboard", value); }
    public bool AutoLock { get => Settings.Bool("autoLock"); set => Settings.Set("autoLock", value); }
    public int AutoLockMinutes { get => Settings.Int("autoLockMinutes", 2); set => Settings.Set("autoLockMinutes", value); }
    public bool AllowControl { get => Settings.Bool("allowControl", true); set => Settings.Set("allowControl", value); }

    public HashSet<string> MutedApps
    {
        get => (Settings.Str("mutedApps") ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
        set { Settings.Set("mutedApps", string.Join("\n", value)); Fire("settings"); }
    }

    public Dictionary<string, string> AppNames
    {
        get { try { return JsonSerializer.Deserialize<Dictionary<string, string>>(Settings.Str("appNames") ?? "{}") ?? new(); } catch { return new(); } }
        set => Settings.Set("appNames", JsonSerializer.Serialize(value));
    }

    public bool QuietNow
    {
        get
        {
            if (!QuietHours) return false;
            int h = DateTime.Now.Hour, f = QuietFrom, t = QuietTo;
            return f <= t ? h >= f && h < t : h >= f || h < t;
        }
    }

    /// Banners are off: muted, quiet hours, or the phone is on Do Not Disturb.
    public bool Quiet => MuteAll || QuietNow || (FollowPhoneDnd && PhoneDnd);

    public void AddNotification(JsonObject o)
    {
        var key = (string)o["key"];
        if (key == null) return;
        var pkg = (string)o["pkg"] ?? "";
        if (Ui.FromBase64((string)o["icon"]) is Image img) Icons[pkg] = img;
        var n = new Notif
        {
            Key = key, Pkg = pkg, App = (string)o["app"] ?? pkg, Title = (string)o["title"] ?? "", Text = (string)o["text"] ?? "",
            When = DateTime.Now, CanReply = (bool?)o["reply"] ?? false,
        };
        var names = AppNames;
        if (names.GetValueOrDefault(pkg) != n.App) { names[pkg] = n.App; AppNames = names; }
        Notifs.RemoveAll(x => x.Key == key);
        Notifs.Insert(0, n);
        if (Notifs.Count > 300) Notifs.RemoveRange(300, Notifs.Count - 300);
        Fire("notifications");
        // SMS threads change with every message: keep Messages fresh
        if (pkg.Contains("messag") || pkg.Contains("mms")) Delay(1.5, LoadThreads);
        if (!Quiet && !MutedApps.Contains(pkg)) Banners.Show(n, Icons.GetValueOrDefault(pkg));
    }

    public void RemoveNotification(string key)
    {
        Notifs.RemoveAll(x => x.Key == key);
        Banners.Remove(key);
        Fire("notifications");
    }

    public void Dismiss(Notif n) { Link.NotifAction(n.Key, "dismiss"); RemoveNotification(n.Key); }
    public void ReplyTo(Notif n, string text) => Link.NotifAction(n.Key, "reply", text);
    public void Open(Notif n) { Link.NotifAction(n.Key, "open"); if (PhoneCasting) Link.Mirror(); }
    public void ClearAll()
    {
        foreach (var n in Notifs) Link.NotifAction(n.Key, "dismiss");
        Notifs.Clear();
        Banners.RemoveAll();
        Fire("notifications");
    }

    public void SetAppMuted(string pkg, bool muted)
    {
        var m = MutedApps;
        if (muted) m.Add(pkg); else m.Remove(pkg);
        MutedApps = m;
    }

    // ---------- now playing, ring, Do Not Disturb ----------
    public JsonObject Media;
    public Image Art;

    public void SetMedia(JsonObject o)
    {
        if (o == null || string.IsNullOrEmpty((string)o["title"])) { Media = null; Art = null; }
        else
        {
            bool same = Media != null && (string)Media["title"] == (string)o["title"];
            Media = o;
            var art = Ui.FromBase64((string)o["art"]);
            if (art != null) Art = art; else if (!same) Art = null;
        }
        Fire("media");
    }

    public void MediaCmd(string a) => Link.Request("media.cmd", new JsonObject { ["a"] = a }, _ => { });

    public void Ring(bool on)
    {
        Link.Request("phone.ring", new JsonObject { ["on"] = on }, r =>
        {
            if (!r.Ok) Banners.Info(tr("Couldn't ring the phone"), r.Error);
        });
        Ringing = on;
        Fire("media");
    }

    public void SetPhoneDnd(bool on)
    {
        Link.Request("dnd.set", new JsonObject { ["on"] = on }, r =>
        {
            if (!r.Ok) Banners.Info(tr("Couldn't change Do Not Disturb"), r.Permission ? tr("Allow notification access in the PhoneCast app on the phone.") : r.Error);
        });
    }

    // ---------- calls ----------
    public Dictionary<string, string> Call;

    public void CallEvent(JsonObject o)
    {
        var st = (string)o["state"] ?? "idle";
        if (st == "idle") { Call = null; Banners.EndCall(); Fire("call"); Delay(1, LoadCalls); return; }
        var c = Call ?? new Dictionary<string, string>();
        c["state"] = st;
        if ((string)o["number"] is string num && num != "") c["number"] = num;
        if ((string)o["name"] is string nm && nm != "") c["name"] = nm;
        Call = c;
        Banners.ShowCall(c);
        Fire("call");
    }

    public void Answer() => Link.Request("call.answer", new JsonObject(), _ => { });
    public void HangUp() => Link.Request("call.end", new JsonObject(), _ => { });
    public void Dial(string number) => Link.Request("call.dial", new JsonObject { ["number"] = number }, r => Report("calls", r));

    // ---------- data the sections show ----------
    public List<JsonObject> Threads = new(), Contacts = new(), Calls = new(), Photos = new(), Files = new(), Apps = new();
    public readonly Dictionary<long, List<JsonObject>> Messages = new();
    public bool PhotosDone;
    public string FilePath = "";
    public readonly Dictionary<string, string> Errors = new();
    public readonly HashSet<string> Loading = new();

    public void RefreshAll(HashSet<string> only = null)
    {
        bool Want(string k) => only == null || only.Contains(k);
        if (Want("sms")) LoadThreads();
        if (Want("calls")) LoadCalls();
        if (Want("contacts")) LoadContacts();
    }

    void Report(string section, Reply r)
    {
        Loading.Remove(section);
        if (!r.Ok) Errors[section] = r.Permission ? "permission" : r.Error;
        else Errors.Remove(section);
    }

    void Load(string section, string m, JsonObject p, Action<JsonNode> apply)
    {
        if (!Connected) return;
        Loading.Add(section);
        Fire(section);
        Link.Request(m, p ?? new JsonObject(), r =>
        {
            Report(section, r);
            if (r.Ok) apply(r.Data);
            Fire(section);
        });
    }

    static List<JsonObject> Objects(JsonNode n) => n is JsonArray a ? a.OfType<JsonObject>().ToList() : new();

    public void LoadThreads() => Load("messages", "sms.threads", new JsonObject { ["limit"] = 80 }, d => Threads = Objects(d));

    public void LoadThread(long id) => Load("messages", "sms.thread", new JsonObject { ["thread"] = id, ["limit"] = 200 }, d => { Messages[id] = Objects(d); Fire("thread"); });

    public void SendSms(string to, string text, long? thread)
    {
        Link.Request("sms.send", new JsonObject { ["to"] = to, ["text"] = text }, r =>
        {
            if (!r.Ok) { Banners.Info(tr("The message wasn't sent"), r.Permission ? tr("Allow SMS in the PhoneCast app on the phone.") : r.Error); return; }
            Delay(1.2, () => { LoadThreads(); if (thread is long t) LoadThread(t); });
        });
        // show it right away; the reload replaces it
        if (thread is long id)
        {
            if (!Messages.TryGetValue(id, out var list)) Messages[id] = list = new();
            list.Add(new JsonObject { ["id"] = 0, ["text"] = text, ["date"] = DateTimeOffset.Now.ToUnixTimeMilliseconds(), ["mine"] = true, ["sending"] = true });
            Fire("thread");
        }
    }

    public void LoadContacts() => Load("contacts", "contacts", null, d => Contacts = Objects(d));
    public void LoadCalls() => Load("calls", "calls.log", new JsonObject { ["limit"] = 150 }, d => Calls = Objects(d));

    public void LoadPhotos(bool more = false)
    {
        if (!more) { Photos = new(); PhotosDone = false; }
        int offset = Photos.Count;
        Load("photos", "photos", new JsonObject { ["offset"] = offset, ["limit"] = 60 }, d =>
        {
            var got = Objects(d);
            if (more) Photos.AddRange(got); else Photos = got;
            PhotosDone = got.Count < 60;
        });
    }

    public void LoadFiles(string path) => Load("files", "files", new JsonObject { ["path"] = path }, d =>
    {
        if (d is not JsonObject o) return;
        FilePath = (string)o["path"] ?? path;
        Files = Objects(o["items"]);
    });

    public void LoadApps() => Load("apps", "apps", null, d => Apps = Objects(d));

    public void OpenApp(JsonObject a)
    {
        Link.Request("app.open", new JsonObject { ["pkg"] = (string)a["pkg"] }, r =>
        {
            if (!r.Ok) Banners.Info(tr("Couldn't open {0}", (string)a["name"]), r.Error);
        });
        Link.Mirror();
    }

    // ---------- transfers ----------
    public enum TState { Running, Done, Failed }
    public sealed class Transfer
    {
        public int Id; public string Name, Path; public bool Outgoing; public long Size; public double Progress; public TState State; public DateTime When;
    }
    public readonly List<Transfer> Transfers = new();
    int nextTransfer = 1;

    public int BeginTransfer(string name, bool outgoing, long size)
    {
        var t = new Transfer { Id = nextTransfer++, Name = name, Outgoing = outgoing, Size = size, When = DateTime.Now };
        Transfers.Insert(0, t);
        if (Transfers.Count > 200) Transfers.RemoveAt(Transfers.Count - 1);
        Fire("transfers");
        return t.Id;
    }

    public void Progress(int id, double f) { if (Transfers.Find(t => t.Id == id) is Transfer t) { t.Progress = f; Fire("transfers"); } }
    public void FinishTransfer(int id, string path) { if (Transfers.Find(t => t.Id == id) is Transfer t) { t.State = TState.Done; t.Progress = 1; t.Path = path; Fire("transfers"); } }
    public void FailTransfer(int id) { if (Transfers.Find(t => t.Id == id) is Transfer t) { t.State = TState.Failed; Fire("transfers"); } }

    // ---------- this PC + other devices ----------
    public PcStats.Sample Pc;
    public string GamepadName;
    public List<(string name, double? ms)> Devices = new();
    public string DevicesConfig { get => Settings.Str("monitorDevices") ?? ""; set { Settings.Set("monitorDevices", value); Fire("devices"); } }

    // ---------- helpers ----------
    public static void Delay(double seconds, Action a)
    {
        var t = new System.Windows.Forms.Timer { Interval = Math.Max(1, (int)(seconds * 1000)) };
        t.Tick += (_, _) => { t.Stop(); t.Dispose(); a(); };
        t.Start();
    }
}
