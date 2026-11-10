using System.Diagnostics;
using System.Drawing;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace PhoneCast;

/// The link features on Windows (the Mac has them in its sidebar): phone notifications as Windows
/// notifications (reply, open, dismiss), clipboard text and pictures both ways, files both ways
/// (drop files on the window), now playing with controls, ring the phone, links the phone shares.
sealed unsafe partial class App
{
    HubLink hub;
    bool hubUp, hubConnecting;
    int hubIndex;
    double hubRetryAt;
    bool hubQrRejected;
    NotifyIcon tray;
    readonly List<JsonObject> notifs = new();
    readonly Dictionary<int, (FileStream fs, string path, string name, long size, int req, bool clip, bool shot)> incoming = new();
    int nextFileId = 1, nextReq = 1;
    JsonObject media;
    bool ringing;
    string lastClipText;

    static string DownloadsDir
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "PhoneCast");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    // ---------- connection (every 3 s while not linked) ----------

    void HubTick()
    {
        if (hubUp || hubConnecting || Now < hubRetryAt || LoginPin == null) return;
        var c = WifiCandidates();
        if (c.Count == 0) return;
        if (hubIndex >= c.Count) hubIndex = 0;
        var host = c[hubIndex].host;
        hubConnecting = true;
        var (pid, pkey) = PairIdentity();
        var h = new HubLink(host);
        hub = h;
        h.OnLogin = (ok, why) => Post(() =>
        {
            if (hub != h) return;
            hubConnecting = false;
            if (ok)
            {
                hubUp = true; hubIndex = 0;
                Log($"link: connected to {h.PhoneName} via {host}{(h.UsedQr ? " (QR pairing, phone verified)" : "")}");
                Balloon("Linked with " + h.PhoneName, "Notifications, clipboard and files now come to this PC.", null);
                UpdateTray();
                h.SendJson(HubLink.Status, new JsonObject { ["name"] = Environment.MachineName, ["os"] = "windows" });
            }
            else
            {
                Log($"link: refused ({why})");
                if (why == "qr") hubQrRejected = true;
                if (why == "key") Balloon("A different phone answered", "PhoneCast didn't link: its key isn't the one paired with this PC.", null);
                hubRetryAt = Now + (why == "locked" ? 60 : 10);
            }
        });
        h.OnClosed = why => Post(() =>
        {
            if (hub != h) return;
            if (hubUp) Log($"link: closed ({why})");
            bool wasUp = hubUp;
            hubUp = false; hubConnecting = false; hub = null;
            foreach (var f in incoming.Values) { try { f.fs.Dispose(); File.Delete(f.path); } catch { } }
            incoming.Clear();
            if (!wasUp) hubIndex++;
            hubRetryAt = Now + (wasUp ? 2 : 3);
            UpdateTray();
        });
        h.OnPacket = (t, p) => Post(() => { if (hub == h) HubPacket(t, p); });
        h.Start(new Login(Settings.Str("pin") ?? "", pid, pkey, UseQr: Settings.Bool("qrPaired") && !hubQrRejected));
    }

    // ---------- packets from the phone (main thread) ----------

    void HubPacket(byte t, byte[] p)
    {
        switch (t)
        {
            case HubLink.Notif:
                {
                    if (JsonNode.Parse(Encoding.UTF8.GetString(p)) is not JsonObject o) break;
                    notifs.RemoveAll(n => (string)n["key"] == (string)o["key"]);
                    notifs.Insert(0, o);
                    if (notifs.Count > 30) notifs.RemoveAt(notifs.Count - 1);
                    Balloon($"{(string)o["app"]}: {(string)o["title"]}", (string)o["text"], () => ShowNotif(o));
                    UpdateTray();
                    break;
                }
            case HubLink.NotifGone:
                notifs.RemoveAll(n => (string)n["key"] == Encoding.UTF8.GetString(p));
                UpdateTray();
                break;
            case HubLink.Clip:
                {
                    var text = Encoding.UTF8.GetString(p);
                    lastClipText = text;
                    try { Clipboard.SetText(text); } catch { }
                    Balloon("Copied from the phone", text.Length > 80 ? text[..80] + "…" : text, null);
                    break;
                }
            case HubLink.FileBegin:
                {
                    if (JsonNode.Parse(Encoding.UTF8.GetString(p)) is not JsonObject o) break;
                    int id = (int)o["id"]; var name = SafeName((string)o["name"] ?? "file");
                    int req = (int?)o["req"] ?? 0;
                    // unrequested files say what they are for: "clipimg" (a copied picture), "screenshot" (new on the phone)
                    var kind = (string)o["kind"];
                    bool clip = kind == "clipimg", shot = kind == "screenshot";
                    var path = clip ? Path.Combine(Path.GetTempPath(), "phonecast-clip-" + name) : Unique(Path.Combine(DownloadsDir, name));
                    try { incoming[id] = (File.Create(path), path, name, (long?)o["size"] ?? -1, req, clip, shot); } catch (Exception e) { Log("link: file " + e.Message); }
                    break;
                }
            case HubLink.FileData:
                {
                    if (p.Length < 4) break;
                    int id = p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
                    if (incoming.TryGetValue(id, out var f)) f.fs.Write(p, 4, p.Length - 4);
                    break;
                }
            case HubLink.FileEnd:
            case HubLink.FileCancel:
                {
                    if (p.Length < 4) break;
                    int id = p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
                    if (!incoming.Remove(id, out var f)) break;
                    f.fs.Dispose();
                    if (t == HubLink.FileCancel) { try { File.Delete(f.path); } catch { } break; }
                    if (f.clip)
                    {
                        try { using var img = Image.FromFile(f.path); Clipboard.SetImage(new Bitmap(img)); Balloon("Picture copied from the phone", "Paste it anywhere.", null); }
                        catch (Exception e) { Log("link: clip picture " + e.Message); }
                        try { File.Delete(f.path); } catch { }
                    }
                    else
                    {
                        var path = f.path;
                        if (f.shot)
                        {
                            // a new screenshot on the phone: also on the clipboard, ready to paste
                            try { using var img = Image.FromFile(path); Clipboard.SetImage(new Bitmap(img)); } catch (Exception e) { Log("link: screenshot clip " + e.Message); }
                            Balloon("Screenshot from the phone", "Copied, and saved in Downloads\\PhoneCast", () => Process.Start("explorer.exe", $"/select,\"{path}\""));
                        }
                        else Balloon("From the phone: " + f.name, "Saved in Downloads\\PhoneCast", () => Process.Start("explorer.exe", $"/select,\"{path}\""));
                    }
                    break;
                }
            case HubLink.Event:
                {
                    if (JsonNode.Parse(Encoding.UTF8.GetString(p)) is not JsonObject o) break;
                    switch ((string)o["e"])
                    {
                        case "media": media = o["title"] is null ? null : o; UpdateTray(); break;
                        case "ring": ringing = (bool?)o["on"] ?? false; RefreshMenu(); UpdateTray(); break;
                        case "open":
                            {
                                var url = (string)o["url"] ?? "";
                                // only web links (the phone's "share to PhoneCast"), never other schemes or files
                                if (Uri.TryCreate(url, UriKind.Absolute, out var u) && (u.Scheme == "http" || u.Scheme == "https"))
                                    try { Process.Start(new ProcessStartInfo(u.AbsoluteUri) { UseShellExecute = true }); } catch { }
                                break;
                            }
                        case "call":
                            {
                                var state = (string)o["state"];
                                var who = (string)o["name"] ?? (string)o["number"] ?? "Unknown";
                                if (state == "ringing")
                                    Balloon("Incoming call: " + who, "Click to answer or decline on the phone.", () =>
                                    {
                                        var r = MessageBox.Show(Owner, $"{who} is calling.\n\nAnswer? (No = decline)", "PhoneCast — call", MessageBoxButtons.YesNoCancel);
                                        if (r == DialogResult.Yes) HubRequest("call.answer", new JsonObject());
                                        else if (r == DialogResult.No) HubRequest("call.end", new JsonObject());
                                    });
                                break;
                            }
                    }
                    break;
                }
            case HubLink.CastReady:
                // the phone started sharing: show it (if this PC wants to be connected)
                if (stateText != "Connected" && LoginPin != null) { wantConnected = true; wifiIndex = 0; ConnectSaved(); }
                break;
        }
    }

    static string SafeName(string n)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) n = n.Replace(c, '_');
        n = n.Trim().TrimStart('.');
        return n == "" ? "file" : n;
    }

    static string Unique(string path)
    {
        if (!File.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path); var b = Path.GetFileNameWithoutExtension(path); var e = Path.GetExtension(path);
        for (int i = 2; ; i++) { var p = Path.Combine(dir, $"{b} {i}{e}"); if (!File.Exists(p)) return p; }
    }

    // ---------- things this PC sends ----------

    void HubRequest(string m, JsonObject p) => hub?.SendJson(HubLink.Req, new JsonObject { ["id"] = nextReq++, ["m"] = m, ["p"] = p });

    bool HubNeeded()
    {
        if (hubUp) return true;
        Balloon("The phone isn't linked", "Open PhoneCast on the phone; the link connects by itself (same PIN / QR pairing as the mirror).", null);
        return false;
    }

    void SendClipboard()
    {
        if (!HubNeeded()) return;
        try
        {
            if (Clipboard.ContainsImage() && Clipboard.GetImage() is Image img)
            {
                var tmp = Path.Combine(Path.GetTempPath(), "phonecast-clip.png");
                img.Save(tmp, System.Drawing.Imaging.ImageFormat.Png);
                SendFiles(new[] { tmp }, clip: true);
                return;
            }
            if (Clipboard.ContainsFileDropList()) { SendFiles(Clipboard.GetFileDropList().Cast<string>().ToArray()); return; }
            var t = Clipboard.GetText();
            if (string.IsNullOrEmpty(t)) { Balloon("The clipboard is empty", "", null); return; }
            hub.Send(HubLink.Clip, Encoding.UTF8.GetBytes(t));
            Balloon("Copied to the phone", t.Length > 80 ? t[..80] + "…" : t, null);
        }
        catch (Exception e) { Log("link: clipboard " + e.Message); }
    }

    void SendFilesDialog()
    {
        if (!HubNeeded()) return;
        using var d = new OpenFileDialog { Multiselect = true, Title = "Send files to the phone" };
        if (d.ShowDialog(Owner) == DialogResult.OK) SendFiles(d.FileNames);
    }

    /// Files (and folders, zipped) to the phone's Downloads/PhoneCast; [clip] = a picture for its clipboard.
    void SendFiles(string[] paths, bool clip = false)
    {
        var h = hub;
        if (h == null || !hubUp) { HubNeeded(); return; }
        var ids = paths.Select(_ => nextFileId++).ToArray();
        new Thread(() =>
        {
            for (int i = 0; i < paths.Length; i++)
            {
                var path = paths[i]; string tmpZip = null;
                try
                {
                    if (Directory.Exists(path))
                    {
                        tmpZip = Path.Combine(Path.GetTempPath(), Path.GetFileName(path.TrimEnd('\\')) + ".zip");
                        File.Delete(tmpZip);
                        System.IO.Compression.ZipFile.CreateFromDirectory(path, tmpZip, System.IO.Compression.CompressionLevel.Fastest, true);
                        path = tmpZip;
                    }
                    var fi = new FileInfo(path);
                    var begin = new JsonObject { ["id"] = ids[i], ["name"] = fi.Name, ["size"] = fi.Length };
                    if (clip) begin["clip"] = true;
                    h.SendJson(HubLink.FileBegin, begin);
                    using var fs = fi.OpenRead();
                    var buf = new byte[256 * 1024 + 4];
                    buf[0] = (byte)(ids[i] >> 24); buf[1] = (byte)(ids[i] >> 16); buf[2] = (byte)(ids[i] >> 8); buf[3] = (byte)ids[i];
                    int n;
                    while ((n = fs.Read(buf, 4, buf.Length - 4)) > 0) h.Send(HubLink.FileData, buf.AsSpan(0, n + 4).ToArray());
                    h.Send(HubLink.FileEnd, buf.AsSpan(0, 4).ToArray());
                    var name = fi.Name;
                    if (!clip) Post(() => Balloon("Sent to the phone: " + name, "In the phone's Downloads/PhoneCast", null));
                    else Post(() => Balloon("Picture copied to the phone", "Paste it there.", null));
                }
                catch (Exception e) { Log("link: send " + e.Message); }
                finally { if (tmpZip != null) try { File.Delete(tmpZip); } catch { } }
            }
        }) { IsBackground = true, Name = "hub-send" }.Start();
    }

    // ---------- notifications ----------

    void ShowNotif(JsonObject o)
    {
        if (mode == Mode.Game) SetMode(Mode.Normal);
        using var d = new NotifDialog(o);
        var r = d.ShowDialog(Owner);
        var key = (string)o["key"];
        switch (d.Choice)
        {
            case "reply": hub?.SendJson(HubLink.NotifAction, new JsonObject { ["key"] = key, ["action"] = "reply", ["text"] = d.ReplyText }); break;
            case "open":
                hub?.SendJson(HubLink.NotifAction, new JsonObject { ["key"] = key, ["action"] = "open" });
                if (stateText != "Connected") { wantConnected = true; ConnectSaved(); }
                break;
            case "dismiss": hub?.SendJson(HubLink.NotifAction, new JsonObject { ["key"] = key, ["action"] = "dismiss" }); notifs.Remove(o); UpdateTray(); break;
        }
    }

    // ---------- tray icon (status, notifications, now playing) ----------

    Action balloonClick;

    void EnsureTray()
    {
        if (tray != null) return;
        tray = new NotifyIcon { Text = "PhoneCast", Visible = true };
        var ico = Path.Combine(AppContext.BaseDirectory, "phonecast_off.ico");
        tray.Icon = File.Exists(ico) ? new Icon(ico) : SystemIcons.Application;
        tray.BalloonTipClicked += (_, _) => { var a = balloonClick; balloonClick = null; a?.Invoke(); };
        tray.DoubleClick += (_, _) => Sdl.SDL_RaiseWindow(win);
        tray.ContextMenuStrip = new ContextMenuStrip();
        tray.ContextMenuStrip.Opening += (_, _) => BuildTrayMenu();
    }

    void Balloon(string title, string text, Action onClick)
    {
        EnsureTray();
        balloonClick = onClick;
        tray.ShowBalloonTip(5000, string.IsNullOrEmpty(title) ? "PhoneCast" : title, string.IsNullOrEmpty(text) ? " " : text, ToolTipIcon.None);
    }

    void UpdateTray()
    {
        EnsureTray();
        var ico = Path.Combine(AppContext.BaseDirectory, hubUp ? "phonecast_on.ico" : "phonecast_off.ico");
        if (File.Exists(ico)) try { tray.Icon = new Icon(ico); } catch { }
        var t = hubUp ? $"PhoneCast — linked with {hub?.PhoneName}" : "PhoneCast — phone not linked";
        if (media != null) t += $"\n♪ {(string)media["title"]}";
        tray.Text = t.Length > 127 ? t[..127] : t;
    }

    void BuildTrayMenu()
    {
        var m = tray.ContextMenuStrip;
        m.Items.Clear();
        m.Items.Add(new ToolStripMenuItem(hubUp ? $"Linked with {hub?.PhoneName}" : "Phone not linked") { Enabled = false });
        m.Items.Add("Show PhoneCast", null, (_, _) => Sdl.SDL_RaiseWindow(win));
        m.Items.Add(new ToolStripSeparator());
        if (media != null)
        {
            bool playing = (bool?)media["playing"] ?? false;
            m.Items.Add(new ToolStripMenuItem($"♪ {(string)media["title"]} — {(string)media["artist"]}") { Enabled = false });
            m.Items.Add(playing ? "Pause" : "Play", null, (_, _) => HubRequest("media.cmd", new JsonObject { ["a"] = "toggle" }));
            m.Items.Add("Next", null, (_, _) => HubRequest("media.cmd", new JsonObject { ["a"] = "next" }));
            m.Items.Add("Previous", null, (_, _) => HubRequest("media.cmd", new JsonObject { ["a"] = "prev" }));
            m.Items.Add(new ToolStripSeparator());
        }
        var nm = new ToolStripMenuItem($"Notifications ({notifs.Count})") { Enabled = notifs.Count > 0 };
        foreach (var n in notifs.Take(15))
        {
            var o = n;
            var label = $"{(string)o["app"]}: {(string)o["title"]}";
            nm.DropDownItems.Add(label.Length > 60 ? label[..60] + "…" : label, null, (_, _) => ShowNotif(o));
        }
        m.Items.Add(nm);
        m.Items.Add("Send clipboard to the phone", null, (_, _) => SendClipboard());
        m.Items.Add("Send files to the phone…", null, (_, _) => SendFilesDialog());
        m.Items.Add(ringing ? "Stop ringing the phone" : "Ring the phone", null, (_, _) => RingPhone());
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add("Quit PhoneCast", null, (_, _) => { var q = new Sdl.Event { type = Sdl.QUIT }; Sdl.SDL_PushEvent(ref q); });
    }

    void RingPhone()
    {
        if (!HubNeeded()) return;
        HubRequest("phone.ring", new JsonObject { ["on"] = !ringing });
        ringing = !ringing;
        RefreshMenu();
    }

    void MediaCmd(string a) { if (HubNeeded()) HubRequest("media.cmd", new JsonObject { ["a"] = a }); }

    void HubShutdown()
    {
        hub?.Close();
        if (tray != null) { tray.Visible = false; tray.Dispose(); tray = null; }
    }
}

/// One phone notification: full text, reply (if the app allows it), open on the phone, dismiss.
sealed class NotifDialog : Form
{
    public string Choice { get; private set; }
    public string ReplyText => reply.Text;
    readonly TextBox reply = new() { Width = 380 };

    public NotifDialog(JsonObject o)
    {
        Text = $"{(string)o["app"]} — PhoneCast";
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent; AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink; Font = new Font("Segoe UI", 9.5f);
        var flow = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Padding = new Padding(14), WrapContents = false };
        flow.Controls.Add(new Label { AutoSize = true, MaximumSize = new Size(380, 0), Font = new Font(Font, FontStyle.Bold), Text = (string)o["title"] ?? "" });
        flow.Controls.Add(new Label { AutoSize = true, MaximumSize = new Size(380, 0), Margin = new Padding(0, 6, 0, 8), Text = (string)o["text"] ?? "" });
        bool canReply = (bool?)o["reply"] ?? false;
        if (canReply) { reply.PlaceholderText = "Reply…"; flow.Controls.Add(reply); }
        var b = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Width = 380, Margin = new Padding(0, 10, 0, 0) };
        Button Btn(string t, string c) { var x = new Button { Text = t, AutoSize = true }; x.Click += (_, _) => { Choice = c; DialogResult = DialogResult.OK; Close(); }; return x; }
        if (canReply) { var r = Btn("Send reply", "reply"); b.Controls.Add(r); AcceptButton = r; }
        b.Controls.Add(Btn("Open on the phone", "open"));
        b.Controls.Add(Btn("Dismiss", "dismiss"));
        var close = new Button { Text = "Close", AutoSize = true, DialogResult = DialogResult.Cancel };
        b.Controls.Add(close); CancelButton = close;
        flow.Controls.Add(b);
        Controls.Add(flow);
    }
}
