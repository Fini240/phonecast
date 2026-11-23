using System.Collections.Concurrent;
using System.Drawing;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace PhoneCast;

/// The phone link on Windows: connection (every 3 s while not linked), packets from the phone handed
/// to the window's Store on the UI thread, requests with answers, files both ways with progress, and
/// the phone controlling this PC (PcScreen). App is the IPhoneLink the window talks to.
sealed unsafe partial class App : IPhoneLink
{
    volatile HubLink hub;
    volatile bool hubUp;
    bool hubConnecting;
    int hubIndex;
    double hubRetryAt;
    bool hubQrRejected, autoMirrorDone;
    PcScreen screen;

    sealed class Incoming
    {
        public FileStream Fs; public string Path, Name, Kind; public long Size, Got; public int Req, Transfer, LastPct = -1;
    }
    readonly Dictionary<int, Incoming> incoming = new();
    readonly ConcurrentDictionary<int, Action<Reply>> pendingReq = new();
    readonly ConcurrentDictionary<int, (Action<string> then, bool keep)> wanted = new();
    int nextFileId = 1, nextReq = 1;

    public static string DownloadsDir
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "PhoneCast");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    // ---------- connection (main thread) ----------

    void HubTick()
    {
        if (hubUp || hubConnecting || Now < hubRetryAt || LoginPin == null) return;
        var c = WifiCandidates();
        if (c.Count == 0) return;
        if (hubIndex >= c.Count) hubIndex = 0;
        var host = c[hubIndex].host;
        int hubPort = HubLink.Port;
        if (c[hubIndex].label == Relay.Label)
        {
            if (Relay.LocalPort(HubLink.Port) is not int rp) { hubIndex++; return; }
            hubPort = rp;
        }
        hubConnecting = true;
        var (pid, pkey) = PairIdentity();
        var h = new HubLink(host, hubPort);
        hub = h;
        h.OnLogin = (ok, why) => Post(() =>
        {
            if (hub != h) return;
            hubConnecting = false;
            if (ok)
            {
                hubUp = true; hubIndex = 0; autoMirrorDone = false;
                Log($"link: connected to {h.PhoneName} via {host}{(h.UsedQr ? " (QR pairing, phone verified)" : "")}");
                h.SendJson(HubLink.Status, new JsonObject { ["name"] = Environment.MachineName, ["os"] = "windows" });
                var name = h.PhoneName;
                Ui.Post(() => { Store.Shared.SetConnected(true, name); AutoLock.Changed(true); });
            }
            else
            {
                Log($"link: refused ({why})");
                if (why == "qr") hubQrRejected = true;
                if (why == "key") Banners.Info(tr("A different phone answered"), tr("PhoneCast didn't link: its key isn't the one paired with this PC."));
                hubRetryAt = Now + (why == "locked" ? 60 : 10);
            }
        });
        h.OnClosed = why => Post(() =>
        {
            if (hub != h) return;
            if (hubUp) Log($"link: closed ({why})");
            bool wasUp = hubUp;
            hubUp = false; hubConnecting = false; hub = null;
            screen?.Stop();
            foreach (var f in incoming.Values) { try { f.Fs.Dispose(); File.Delete(f.Path); } catch { } var tid = f.Transfer; Ui.Post(() => Store.Shared.FailTransfer(tid)); }
            incoming.Clear();
            foreach (var (id, done) in pendingReq.ToArray()) if (pendingReq.TryRemove(id, out _)) Ui.Post(() => done(new Reply(false, null, tr("The phone disconnected."), false)));
            if (!wasUp) hubIndex++;
            hubRetryAt = Now + (wasUp ? 2 : 3);
            if (wasUp) Ui.Post(() => { Store.Shared.SetConnected(false, null); AutoLock.Changed(false); });
        });
        h.OnPacket = (t, p) =>
        {
            // the phone controlling this PC: straight from the network thread (lowest delay)
            if (t == HubLink.Input) { if (Settings.Bool("allowControl", true)) PcInput.Handle(p); return; }
            Post(() => { if (hub == h) HubPacket(t, p); });
        };
        h.Start(new Login(Settings.Str("pin") ?? "", pid, pkey, UseQr: Settings.Bool("qrPaired") && !hubQrRejected));
    }

    // ---------- packets from the phone (main thread) ----------

    static JsonObject Json(byte[] p) { try { return JsonNode.Parse(Encoding.UTF8.GetString(p)) as JsonObject; } catch { return null; } }

    void HubPacket(byte t, byte[] p)
    {
        switch (t)
        {
            case HubLink.Status:
                if (Json(p) is JsonObject st)
                {
                    Ui.Post(() => Store.Shared.ApplyStatus(st));
                    // the phone was already sharing when we linked: show it, like after "Cast"
                    if (!autoMirrorDone && ((bool?)st["casting"] ?? false) && stateText != "Connected" && !mirrorDismissed)
                    { autoMirrorDone = true; StartMirror(request: false); }
                    autoMirrorDone = true;
                }
                break;
            case HubLink.Pong:
                if (p.Length == 8)
                {
                    double ms = (Environment.TickCount64 - BitConverter.ToInt64(p)) * 1.0;
                    Ui.Post(() => { var s = Store.Shared; s.Rtt = s.Rtt < 0 ? ms : s.Rtt * 0.7 + ms * 0.3; });
                }
                break;
            case HubLink.Notif:
                if (Json(p) is JsonObject n) Ui.Post(() => Store.Shared.AddNotification(n));
                break;
            case HubLink.NotifGone:
                { var key = Encoding.UTF8.GetString(p); Ui.Post(() => Store.Shared.RemoveNotification(key)); break; }
            case HubLink.Clip:
                {
                    var text = Encoding.UTF8.GetString(p);
                    var phone = hub?.PhoneName ?? "phone";
                    Ui.Post(() =>
                    {
                        ClipboardSync.FromPhone(text);
                        Banners.Info(tr("Copied from {0}", phone), text.Length > 80 ? text[..80] + "…" : text);
                    });
                    break;
                }
            case HubLink.Resp:
                {
                    if (Json(p) is not JsonObject o || (int?)o["id"] is not int id || !pendingReq.TryRemove(id, out var done)) break;
                    bool ok = (bool?)o["ok"] ?? false;
                    var r = new Reply(ok, o["data"]?.DeepClone(), (string)o["message"] ?? tr("Failed"), (string)o["error"] == "permission");
                    Ui.Post(() => done(r));
                    break;
                }
            case HubLink.FileBegin:
                {
                    if (Json(p) is not JsonObject o) break;
                    int id = (int?)o["id"] ?? 0;
                    var name = SafeName((string)o["name"] ?? "file");
                    int req = (int?)o["req"] ?? 0;
                    // unrequested files say what they are for: "clipimg" (a copied picture), "screenshot" (new on the phone)
                    var kind = (string)o["kind"];
                    bool temp = kind == "clipimg" || (req != 0 && wanted.TryGetValue(req, out var w) && !w.keep);
                    var dir = temp ? Path.Combine(Path.GetTempPath(), "PhoneCast") : DownloadsDir;
                    Directory.CreateDirectory(dir);
                    var path = Unique(Path.Combine(dir, name));
                    long size = (long?)o["size"] ?? -1;
                    try
                    {
                        var f = new Incoming { Fs = File.Create(path), Path = path, Name = name, Kind = kind, Size = size, Req = req };
                        incoming[id] = f;
                        if (kind != "clipimg")
                        {
                            var tcs = new TaskCompletionSource<int>();
                            Ui.Post(() => tcs.SetResult(Store.Shared.BeginTransfer(name, false, size)));
                            tcs.Task.ContinueWith(x => f.Transfer = x.Result);
                        }
                    }
                    catch (Exception e) { Log("link: file " + e.Message); }
                    break;
                }
            case HubLink.FileData:
                {
                    if (p.Length < 4) break;
                    int id = p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
                    if (!incoming.TryGetValue(id, out var f)) break;
                    f.Fs.Write(p, 4, p.Length - 4);
                    f.Got += p.Length - 4;
                    if (f.Size > 0 && f.Transfer != 0)
                    {
                        int pct = (int)(f.Got * 100 / f.Size);
                        if (pct != f.LastPct) { f.LastPct = pct; int tid = f.Transfer; Ui.Post(() => Store.Shared.Progress(tid, pct / 100.0)); }
                    }
                    break;
                }
            case HubLink.FileEnd:
            case HubLink.FileCancel:
                {
                    if (p.Length < 4) break;
                    int id = p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
                    if (!incoming.Remove(id, out var f)) break;
                    f.Fs.Dispose();
                    int tid = f.Transfer;
                    if (t == HubLink.FileCancel)
                    {
                        try { File.Delete(f.Path); } catch { }
                        Ui.Post(() => Store.Shared.FailTransfer(tid));
                        if (f.Req != 0) wanted.TryRemove(f.Req, out _);
                        break;
                    }
                    FileArrived(f);
                    break;
                }
            case HubLink.Event:
                {
                    if (Json(p) is not JsonObject o) break;
                    switch ((string)o["e"])
                    {
                        case "media": Ui.Post(() => { Store.Shared.SetMedia(o); Tray.Update(); }); break;
                        case "ring": { bool on = (bool?)o["on"] ?? false; Ui.Post(() => { Store.Shared.Ringing = on; Store.Shared.Fire("media"); }); break; }
                        case "call": Ui.Post(() => Store.Shared.CallEvent(o)); break;
                        case "open":
                            {
                                var url = (string)o["url"] ?? "";
                                // only web links (the phone's "share to PhoneCast"), never other schemes or files
                                if (Uri.TryCreate(url, UriKind.Absolute, out var u) && (u.Scheme == "http" || u.Scheme == "https"))
                                {
                                    Ui.Shell(u.AbsoluteUri);
                                    Banners.Info(tr("Opened a link from {0}", hub?.PhoneName ?? "phone"), u.Host);
                                }
                                break;
                            }
                    }
                    break;
                }
            case HubLink.CastReady:
                Ui.Post(() => { Store.Shared.PhoneCasting = true; Store.Shared.Fire("status"); });
                // the phone started sharing: show it (if this PC asked, or nobody closed the mirror on purpose)
                if (stateText != "Connected" && LoginPin != null && (castAsked || !mirrorDismissed)) StartMirror(request: false);
                castAsked = false;
                break;
            case HubLink.CastStopped:
                Ui.Post(() => { Store.Shared.PhoneCasting = false; Store.Shared.Fire("status"); });
                break;
            case HubLink.ScreenStart:
                {
                    int longSide = p.Length >= 2 ? p[0] << 8 | p[1] : 1920, mbps = p.Length >= 3 ? p[2] : 16;
                    if (!Settings.Bool("allowControl", true)) { hub?.Send(HubLink.ScreenDenied, Encoding.UTF8.GetBytes(tr("This PC doesn't allow control from the phone (PhoneCast → Settings on the PC)."))); break; }
                    screen ??= new PcScreen((ty, data) => hub?.Send(ty, data), (ty, data, max) => hub?.SendVideo(ty, data, max) ?? false);
                    screen.Start(longSide, mbps);
                    break;
                }
            case HubLink.ScreenStop: screen?.Stop(); break;
            case HubLink.ScreenKey: screen?.ForceKeyframe(); break;
            case HubLink.MacAction: if (Settings.Bool("allowControl", true)) PcInput.Action(Encoding.UTF8.GetString(p), path => SendFiles(new[] { path }), url => Request("url.open", new JsonObject { ["url"] = url }, _ => { })); break;
        }
    }

    void FileArrived(Incoming f)
    {
        var path = f.Path;
        int tid = f.Transfer;
        var phone = hub?.PhoneName ?? "phone";
        Action<string> then = null;
        if (f.Req != 0 && wanted.TryRemove(f.Req, out var w)) then = w.then;
        Log($"link: received {path}");
        Ui.Post(() =>
        {
            if (tid != 0) Store.Shared.FinishTransfer(tid, path);
            if (then != null) { then(path); return; }
            if (f.Kind == "clipimg")
            {
                try { using var img = Image.FromFile(path); ClipboardSync.FromPhone(img); Banners.Info(tr("Picture copied from {0}", phone), tr("Paste it anywhere (Ctrl+V).")); }
                catch (Exception e) { Log("link: clip picture " + e.Message); }
                try { File.Delete(path); } catch { }
            }
            else if (f.Kind == "screenshot")
            {
                // a new screenshot on the phone: also on the clipboard, ready to paste
                try { using var img = Image.FromFile(path); ClipboardSync.FromPhone(img, path); } catch (Exception e) { Log("link: screenshot clip " + e.Message); }
                Banners.File(path, phone + " · " + tr("screenshot, copied"));
            }
            else Banners.File(path, phone);
        });
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

    // =====================================================================
    // IPhoneLink (any thread)

    public void Request(string m, JsonObject p, Action<Reply> done, double timeout = 30)
    {
        var h = hub;
        if (h == null || !hubUp) { Ui.Post(() => done(new Reply(false, null, tr("The phone isn't connected."), false))); return; }
        int id = Interlocked.Increment(ref nextReq);
        pendingReq[id] = done;
        h.SendJson(HubLink.Req, new JsonObject { ["id"] = id, ["m"] = m, ["p"] = p ?? new JsonObject() });
        _ = Task.Delay(TimeSpan.FromSeconds(timeout)).ContinueWith(_ =>
        {
            if (pendingReq.TryRemove(id, out var d)) Ui.Post(() => d(new Reply(false, null, tr("The phone didn't answer."), false)));
        });
    }

    /// "Show the phone on a map": its position in the browser (OpenStreetMap).
    public void LocatePhone()
    {
        Banners.Info(tr("Locating the phone…"), tr("This can take up to 20 seconds."));
        Request("phone.locate", new JsonObject(), r =>
        {
            if (!r.Ok) { Banners.Info(tr("Couldn't locate the phone"), r.Permission
                ? tr("On the phone: PhoneCast → Settings → Allow location (Allow all the time).") : r.Error); return; }
            var d = r.Data as JsonObject;
            double lat = (double?)d?["lat"] ?? 0, lon = (double?)d?["lon"] ?? 0;
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            OpenUrl($"https://www.openstreetmap.org/?mlat={lat.ToString(inv)}&mlon={lon.ToString(inv)}#map=17/{lat.ToString(inv)}/{lon.ToString(inv)}");
        }, 30);
    }

    public static void OpenUrl(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }

    void ExportMap()
    {
        if (mode == Mode.Game) SetMode(Mode.Normal);
        using var d = new SaveFileDialog { FileName = $"Key map {KeyMap.Layout}.phonecast-keys.json", Filter = "PhoneCast key map|*.json" };
        if (d.ShowDialog() != DialogResult.OK) return;
        var game = Path.GetFileNameWithoutExtension(Path.GetFileNameWithoutExtension(d.FileName));
        File.WriteAllText(d.FileName, map.Export(game));
    }

    void ImportMap()
    {
        if (mode == Mode.Game) SetMode(Mode.Normal);
        using var d = new OpenFileDialog { Filter = "PhoneCast key map|*.json" };
        if (d.ShowDialog() != DialogResult.OK) return;
        var m = KeyMap.Import(File.ReadAllText(d.FileName));
        if (m == null) { MessageBox.Show(tr("That file isn't a PhoneCast key map."), "PhoneCast"); return; }
        m.sens = map.sens;   // keep your own mouse speed
        map = m; map.Save(); overlayDirty = true;
    }

    public void SendStatus(JsonObject o) { if (hubUp) hub?.SendJson(HubLink.Status, o); }

    public void FetchFile(string m, JsonObject p, bool keep, Action<string> then)
    {
        int req = Interlocked.Increment(ref nextReq);
        wanted[req] = (then, keep);
        p["req"] = req;
        Request(m, p, r =>
        {
            if (!r.Ok) { wanted.TryRemove(req, out _); Banners.Info(tr("Couldn't get it from the phone"), r.Permission ? tr("Allow this in the PhoneCast app on the phone.") : r.Error); }
        });
    }

    public void NotifAction(string key, string action, string text = "") =>
        hub?.SendJson(HubLink.NotifAction, new JsonObject { ["key"] = key, ["action"] = action, ["text"] = text });

    public void SendClipText(string text) => hub?.Send(HubLink.Clip, Encoding.UTF8.GetBytes(text));

    public void SendClipImage(Image img)
    {
        var tmp = Path.Combine(Path.GetTempPath(), "phonecast-clip.png");
        try { img.Save(tmp, System.Drawing.Imaging.ImageFormat.Png); } catch (Exception e) { Log("clip png: " + e.Message); return; }
        SendFiles(new[] { tmp }, clip: true);
    }

    void IPhoneLink.SendFiles(string[] paths, string dir) => SendFiles(paths, dir);

    /// Files (folders zipped) to the phone's Downloads/PhoneCast or [dir]; [clip] = a picture for its clipboard.
    void SendFiles(string[] paths, string dir = null, bool clip = false)
    {
        var h = hub;
        if (h == null || !hubUp) { Banners.Info(tr("The phone isn't linked"), tr("Open PhoneCast on the phone; the link connects by itself.")); return; }
        var ids = paths.Select(_ => Interlocked.Increment(ref nextFileId)).ToArray();
        new Thread(() =>
        {
            for (int i = 0; i < paths.Length; i++)
            {
                var path = paths[i]; string tmpZip = null; int tid = 0;
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
                    if (!clip)
                    {
                        var tcs = new TaskCompletionSource<int>();
                        Ui.Post(() => tcs.SetResult(Store.Shared.BeginTransfer(fi.Name, true, fi.Length)));
                        tid = tcs.Task.Wait(2000) ? tcs.Task.Result : 0;
                    }
                    var begin = new JsonObject { ["id"] = ids[i], ["name"] = fi.Name, ["size"] = fi.Length };
                    if (clip) begin["clip"] = true;
                    if (!string.IsNullOrEmpty(dir)) begin["dir"] = dir;
                    h.SendJson(HubLink.FileBegin, begin);
                    using var fs = fi.OpenRead();
                    var buf = new byte[256 * 1024 + 4];
                    buf[0] = (byte)(ids[i] >> 24); buf[1] = (byte)(ids[i] >> 16); buf[2] = (byte)(ids[i] >> 8); buf[3] = (byte)ids[i];
                    int n, lastPct = -1; long sent = 0;
                    while ((n = fs.Read(buf, 4, buf.Length - 4)) > 0)
                    {
                        h.Send(HubLink.FileData, buf.AsSpan(0, n + 4).ToArray());
                        sent += n;
                        int pct = fi.Length > 0 ? (int)(sent * 100 / fi.Length) : 100;
                        if (tid != 0 && pct != lastPct) { lastPct = pct; int t2 = tid; Ui.Post(() => Store.Shared.Progress(t2, pct / 100.0)); }
                    }
                    h.Send(HubLink.FileEnd, buf.AsSpan(0, 4).ToArray());
                    var name = fi.Name; int t3 = tid;
                    if (!clip) Ui.Post(() => { Store.Shared.FinishTransfer(t3, paths[0]); Banners.Info(tr("Sent to the phone: {0}", name), string.IsNullOrEmpty(dir) ? tr("In the phone's Downloads/PhoneCast") : dir); });
                    else Ui.Post(() => Banners.Info(tr("Picture copied to the phone"), tr("Paste it there.")));
                }
                catch (Exception e)
                {
                    Log("link: send " + e.Message);
                    int t4 = tid;
                    if (t4 != 0) Ui.Post(() => Store.Shared.FailTransfer(t4));
                }
                finally { if (tmpZip != null) try { File.Delete(tmpZip); } catch { } }
            }
        }) { IsBackground = true, Name = "hub-send" }.Start();
    }

    /// The mirror window: show it if connected, else ask the phone to share and connect when it does.
    public void Mirror() => Post(() =>
    {
        mirrorDismissed = false;
        if (stateText == "Connected") { ShowMirrorWindow(); return; }
        StartMirror(request: true);
    });

    bool mirrorShown, mirrorDismissed, castAsked;

    void StartMirror(bool request)
    {
        if (LoginPin == null) { Ui.Post(() => MainForm.Open("settings")); return; }
        if (request && hubUp) { castAsked = true; hub?.Send(HubLink.CastRequest, Array.Empty<byte>()); }
        SetMessage(tr("Waiting for the phone…\nAllow screen sharing on the phone (Start sharing)."));
        ShowMirrorWindow();
        wantConnected = true; wifiIndex = 0;
        ConnectSaved();
    }

    void ShowMirrorWindow()
    {
        if (!mirrorShown) { mirrorShown = true; Sdl.SDL_ShowWindow(win); WindowIcon(iconConnected); }
        Sdl.SDL_RaiseWindow(win);
        Win32.SetForegroundWindow(hwnd);
    }

    /// The mirror window's close button: hide it and stop the mirror (PhoneCast keeps running).
    void HideMirrorWindow()
    {
        mirrorDismissed = true;
        if (mode != Mode.Normal) SetMode(Mode.Normal);
        if (Recorder.Shared.Recording) Recorder.Shared.Stop();
        if (fullscreen) ToggleFullScreen();
        SaveWindow();
        Sdl.SDL_HideWindow(win);
        mirrorShown = false;
        Disconnect();
        Ui.Post(() => Store.Shared.Fire("status"));
    }

    public bool MirrorConnected => stateText == "Connected";
    public bool Recording => Recorder.Shared.Recording;
    public void ToggleRecording() => Post(ToggleRecord);
    void IPhoneLink.ShowPairing() => Post(ShowPairing);
    void IPhoneLink.ShowConnect() => Post(() => ShowConnect());
    string IPhoneLink.PairCode() => PairCode();
    public void ForgetPhoneKey() { Settings.Remove("phoneKey"); Post(() => { hub?.Close(); hubRetryAt = 0; }); }
    public void NewPairCode()
    {
        Settings.Remove("pairId"); Settings.Remove("pairKey"); Settings.Set("qrPaired", false);
        Post(ShowPairing);
    }
    public void Quit() => Post(() => { var q = new Sdl.Event { type = Sdl.QUIT }; Sdl.SDL_PushEvent(ref q); });

    // ---------- the mirror window's menu / shortcuts ----------

    void SendClipboard() => Ui.Post(ClipboardSync.SendNow);
    void SendFilesDialog() => Ui.Post(() =>
    {
        using var d = new OpenFileDialog { Multiselect = true, Title = tr("Send files to the phone") };
        if (d.ShowDialog() == DialogResult.OK) SendFiles(d.FileNames);
    });
    void RingPhone() => Ui.Post(() => Store.Shared.Ring(!Store.Shared.Ringing));
    void MediaCmd(string a) => Ui.Post(() => Store.Shared.MediaCmd(a));

    void HubShutdown()
    {
        screen?.Stop();
        KeepAwake.Shared.StopOnQuit();
        Advanced.StopAll();
        hub?.Close();
        MainForm.Quitting = true;
        var done = new ManualResetEventSlim();
        Ui.Post(() => { Tray.Stop(); done.Set(); });
        done.Wait(1000);
    }
}
