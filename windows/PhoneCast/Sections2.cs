using System.Drawing;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace PhoneCast;

sealed class ContactsSection : Section
{
    readonly RowList list = new();
    readonly Panel host = new() { Dock = DockStyle.Fill };
    readonly TextBox search = Ui.Input(tr("Search"));

    public ContactsSection()
    {
        search.Width = LogicalToDeviceUnits(220);
        search.Margin = new Padding(0, 6, 8, 0);
        search.TextChanged += (_, _) => Refresh2();
        Controls.Add(host);
        Controls.Add(Header(tr("Contacts"), search, Ui.Button(tr("Refresh"), () => S.LoadContacts())));
        list.Activated += r => { if (First((JsonObject)r.Tag) is string n) S.Dial(n); };
        list.Menu += (r, p) =>
        {
            var o = (JsonObject)r.Tag;
            var m = new ContextMenuStrip();
            if (o["numbers"] is JsonArray nums)
                foreach (var n in nums.OfType<JsonObject>())
                {
                    var num = (string)n["n"]; var label = (string)n["label"];
                    var suffix = string.IsNullOrEmpty(label) ? num : $"{num} ({label})";
                    m.Items.Add(tr("Call {0}", suffix), null, (_, _) => S.Dial(num));
                    m.Items.Add(tr("Text {0}", suffix), null, (_, _) => MessagesSection.ComposeTo(num));
                    m.Items.Add(tr("Copy {0}", num), null, (_, _) => { try { Clipboard.SetText(num); } catch { } });
                    m.Items.Add(new ToolStripSeparator());
                }
            m.Show(list, p);
        };
    }

    static string First(JsonObject c) => (c["numbers"] as JsonArray)?.OfType<JsonObject>().Select(n => (string)n["n"]).FirstOrDefault();

    public override void Shown() { Refresh2(); if (S.Connected && S.Contacts.Count == 0) S.LoadContacts(); }
    public override void Changed(string what) { if (what is "contacts" or "status") Refresh2(); }

    void Refresh2()
    {
        host.Controls.Clear();
        var state = S.Contacts.Count == 0 ? StateFor("contacts", "contacts", "contacts") : null;
        if (state == null && S.Contacts.Count == 0) state = new Placeholder(Glyph.Contact, S.Loading.Contains("contacts") ? tr("Loading…") : tr("No contacts"), "");
        if (state != null) { host.Controls.Add(state); return; }
        var q = search.Text.Trim().ToLowerInvariant();
        list.SetRows(S.Contacts.Where(c => q == "" || ((string)c["name"] ?? "").ToLowerInvariant().Contains(q)
                || (c["numbers"] as JsonArray)?.OfType<JsonObject>().Any(n => ((string)n["n"] ?? "").Replace(" ", "").Contains(q.Replace(" ", ""))) == true)
            .Select((c, i) => new Row
            {
                Key = i + (string)c["name"], Glyph = Glyph.Contact, Title = (string)c["name"],
                Sub = string.Join("  ·  ", (c["numbers"] as JsonArray)?.OfType<JsonObject>().Select(n => (string)n["n"] + (string.IsNullOrEmpty((string)n["label"]) ? "" : $" ({(string)n["label"]})")) ?? Array.Empty<string>()),
                Tag = c,
            }));
        host.Controls.Add(list);
    }
}

// =====================================================================

sealed class PhotosSection : Section
{
    readonly FlowLayoutPanel grid = new() { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Ui.Bg };
    readonly Panel host = new() { Dock = DockStyle.Fill };
    readonly Label count = Ui.Label("", Ui.Body, Ui.Sub);
    readonly FlatButton save;
    readonly HashSet<string> selected = new();
    int shownCount = -1;

    public PhotosSection()
    {
        save = Ui.Button(tr("Save to Downloads"), Save, primary: true);
        Controls.Add(host);
        Controls.Add(Header(tr("Photos"), count, save, Ui.Button(tr("Refresh"), () => { shownCount = -1; S.LoadPhotos(); })));
        HandleCreated += (_, _) => Win.DarkScroll(grid);
    }

    public override void Shown() { Refresh2(); if (S.Connected && S.Photos.Count == 0) S.LoadPhotos(); }
    public override void Changed(string what) { if (what is "photos" or "status") Refresh2(); }

    void Refresh2()
    {
        count.Text = S.Photos.Count == 0 ? "" : tr("{0} photos and videos", S.Photos.Count) + (S.PhotosDone ? "" : "+");
        save.Text = selected.Count > 0 ? tr("Save {0} to Downloads", selected.Count) : tr("Save to Downloads");
        save.Enabled = selected.Count > 0;
        var state = S.Photos.Count == 0 ? StateFor("photos", "photos", "photos and videos") : null;
        if (state == null && S.Photos.Count == 0) state = new Placeholder(Glyph.Photo, S.Loading.Contains("photos") ? tr("Loading…") : tr("No photos"), "");
        host.Controls.Clear();
        if (state != null) { host.Controls.Add(state); shownCount = -1; return; }
        host.Controls.Add(grid);
        if (shownCount == S.Photos.Count && grid.Controls.Count > 0) { foreach (Control c in grid.Controls) c.Invalidate(); UpdateMore(); return; }
        grid.SuspendLayout();
        // only add the new tiles ("Load more"), keep the old ones
        if (shownCount < 0 || shownCount > S.Photos.Count) grid.Controls.Clear();
        else if (grid.Controls.Count > 0 && grid.Controls[^1] is FlatButton) grid.Controls.RemoveAt(grid.Controls.Count - 1);
        for (int i = Math.Max(0, shownCount); i < S.Photos.Count; i++) grid.Controls.Add(new PhotoTile(S.Photos[i], this));
        shownCount = S.Photos.Count;
        UpdateMore();
        grid.ResumeLayout();
    }

    void UpdateMore()
    {
        if (grid.Controls.Count > 0 && grid.Controls[^1] is FlatButton) grid.Controls.RemoveAt(grid.Controls.Count - 1);
        if (!S.PhotosDone) grid.Controls.Add(Ui.Button(S.Loading.Contains("photos") ? tr("Loading…") : tr("Load more"), () => S.LoadPhotos(more: true)));
    }

    public bool IsSelected(string uri) => selected.Contains(uri);
    public void Toggle(string uri) { if (!selected.Remove(uri)) selected.Add(uri); Refresh2(); }

    public static void OpenPhoto(JsonObject p) =>
        S.Link.FetchFile("photo.get", new JsonObject { ["uri"] = (string)p["uri"] }, false, Ui.Shell);

    void Save()
    {
        foreach (var uri in selected.ToList())
            S.Link.FetchFile("photo.get", new JsonObject { ["uri"] = uri }, true, _ => { });
        Banners.Info(tr("Saving {0} to Downloads\\PhoneCast", selected.Count), "");
        selected.Clear();
        Refresh2();
    }

    sealed class PhotoTile : Control
    {
        readonly JsonObject p;
        readonly PhotosSection owner;
        readonly Image thumb;
        public PhotoTile(JsonObject p, PhotosSection owner)
        {
            this.p = p; this.owner = owner;
            thumb = Ui.FromBase64((string)p["thumb"]);
            Size = new Size(LogicalToDeviceUnits(132), LogicalToDeviceUnits(132));
            Margin = new Padding(LogicalToDeviceUnits(3));
            DoubleBuffered = true;
            Cursor = Cursors.Hand;
            var tip = new ToolTip();
            tip.SetToolTip(this, $"{(string)p["name"]}\n{Ui.FromMs((long?)p["date"] ?? 0):g} · {Ui.Size((long?)p["size"] ?? 0)}\n" + tr("Double-click to open, Ctrl-click to select"));
            var menu = new ContextMenuStrip();
            menu.Items.Add(tr("Open"), null, (_, _) => OpenPhoto(p));
            menu.Items.Add(tr("Save to Downloads"), null, (_, _) => S.Link.FetchFile("photo.get", new JsonObject { ["uri"] = (string)p["uri"] }, true, _ => { }));
            menu.Items.Add(tr("Select"), null, (_, _) => owner.Toggle((string)p["uri"]));
            ContextMenuStrip = menu;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.Clear(Ui.Card);
            if (thumb != null)
            {
                float k = Math.Max((float)Width / thumb.Width, (float)Height / thumb.Height);
                float w = thumb.Width * k, h = thumb.Height * k;
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(thumb, (Width - w) / 2, (Height - h) / 2, w, h);
            }
            if ((bool?)p["video"] == true)
            {
                using var f = Ui.IconFont(14);
                using var bg = new SolidBrush(Color.FromArgb(140, 0, 0, 0));
                g.FillEllipse(bg, 6, Height - 34, 28, 28);
                TextRenderer.DrawText(g, Glyph.Play, f, new Rectangle(6, Height - 34, 28, 28), Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
            if (owner.IsSelected((string)p["uri"]))
            {
                using var pen = new Pen(Ui.Accent, LogicalToDeviceUnits(4));
                g.DrawRectangle(pen, 2, 2, Width - 4, Height - 4);
                using var f = Ui.IconFont(11);
                using var bg = new SolidBrush(Ui.Accent);
                g.FillEllipse(bg, Width - 30, 6, 24, 24);
                TextRenderer.DrawText(g, Glyph.Check, f, new Rectangle(Width - 30, 6, 24, 24), Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }
        protected override void OnMouseClick(MouseEventArgs e)
        {
            base.OnMouseClick(e);
            if (e.Button == MouseButtons.Left && (ModifierKeys & (Keys.Control | Keys.Shift)) != 0) owner.Toggle((string)p["uri"]);
        }
        protected override void OnMouseDoubleClick(MouseEventArgs e) { base.OnMouseDoubleClick(e); if (e.Button == MouseButtons.Left) OpenPhoto(p); }
    }
}

// =====================================================================

sealed class FilesSection : Section
{
    readonly RowList list = new();
    readonly Panel host = new() { Dock = DockStyle.Fill };
    readonly Label crumbs = Ui.Label("", Ui.Body, Ui.Sub);
    bool loadedOnce;

    /// Files dropped on the window while this section is open go into this phone folder.
    public string DropFolder => S.FilePath;

    public FilesSection()
    {
        Controls.Add(host);
        var up = Ui.Button(Glyph.Up, () => { if (S.FilePath != "") S.LoadFiles(Parent(S.FilePath)); });
        up.Font = Ui.IconFont(10);
        Controls.Add(Header(tr("Files"), crumbs, up, Ui.Button(tr("Upload…"), Upload), Ui.Button(tr("Refresh"), () => S.LoadFiles(S.FilePath)), Ui.Button(tr("Open in File Explorer"), PhoneDrive.Open)));
        var hint = Ui.Label(tr("Double-click to open · drop files here to upload into this folder"), Ui.Small, Ui.Sub);
        hint.Dock = DockStyle.Bottom;
        hint.Margin = new Padding(0, 6, 0, 0);
        Controls.Add(hint);
        list.Activated += r => Open((JsonObject)r.Tag);
        list.Menu += (r, p) =>
        {
            var f = (JsonObject)r.Tag;
            bool dir = (bool?)f["dir"] ?? false;
            var m = new ContextMenuStrip();
            m.Items.Add(tr("Open"), null, (_, _) => Open(f));
            m.Items.Add(dir ? tr("Download as .zip") : tr("Download"), null, (_, _) => S.Link.FetchFile("file.get", new JsonObject { ["path"] = Join((string)f["name"]) }, true, _ => { }));
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add(tr("Delete on phone…"), null, (_, _) => Delete(f));
            m.Show(list, p);
        };
    }

    static string Parent(string p) { int i = p.LastIndexOf('/'); return i < 0 ? "" : p[..i]; }
    string Join(string name) => S.FilePath == "" ? name : S.FilePath + "/" + name;

    void Open(JsonObject f)
    {
        if ((bool?)f["dir"] ?? false) S.LoadFiles(Join((string)f["name"]));
        else S.Link.FetchFile("file.get", new JsonObject { ["path"] = Join((string)f["name"]) }, false, Ui.Shell);
    }

    void Delete(JsonObject f)
    {
        var name = (string)f["name"];
        if (MessageBox.Show(FindForm(), tr("Delete “{0}” on the phone? This can't be undone.", name), "PhoneCast", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
        S.Link.Request("file.delete", new JsonObject { ["path"] = Join(name) }, r =>
        {
            if (!r.Ok) Banners.Info(tr("Couldn't delete {0}", name), r.Error);
            S.LoadFiles(S.FilePath);
        });
    }

    void Upload()
    {
        using var d = new OpenFileDialog { Multiselect = true, Title = tr("Upload to the phone") };
        if (d.ShowDialog(FindForm()) == DialogResult.OK) S.Link.SendFiles(d.FileNames, S.FilePath);
        Store.Delay(2, () => S.LoadFiles(S.FilePath));
    }

    public override void Shown() { Refresh2(); if (S.Connected && !loadedOnce) { loadedOnce = true; S.LoadFiles(""); } }
    public override void Changed(string what) { if (what is "files" or "status") Refresh2(); if (what == "status" && !S.Connected) loadedOnce = false; }

    void Refresh2()
    {
        crumbs.Text = tr("Phone") + (S.FilePath == "" ? "" : " › " + S.FilePath.Replace("/", " › "));
        host.Controls.Clear();
        var state = StateFor("files", "files", "“All files access”");
        if (state != null) { host.Controls.Add(state); return; }
        if (S.Files.Count == 0) { host.Controls.Add(new Placeholder(Glyph.Folder, S.Loading.Contains("files") ? tr("Loading…") : tr("Empty folder"), "")); return; }
        list.SetRows(S.Files.Select(f =>
        {
            bool dir = (bool?)f["dir"] ?? false;
            var name = (string)f["name"];
            var ext = Path.GetExtension(name).ToLowerInvariant();
            string glyph = dir ? Glyph.Folder : ext is ".jpg" or ".jpeg" or ".png" or ".heic" or ".webp" or ".gif" ? Glyph.Photo : ext is ".mp4" or ".mkv" or ".mov" or ".webm" ? Glyph.Video : ext is ".mp3" or ".m4a" or ".flac" or ".ogg" or ".wav" ? Glyph.Music : Glyph.Doc;
            long size = (long?)f["size"] ?? 0;
            return new Row
            {
                Key = name, Glyph = glyph, GlyphColor = dir ? Ui.Orange : Ui.Accent, Title = name,
                Sub = (dir ? tr("{0} items", size) : Ui.Size(size)) + " · " + Ui.FromMs((long?)f["date"] ?? 0).ToString("g"), Tag = f,
            };
        }));
        host.Controls.Add(list);
    }
}

// =====================================================================

sealed class AppsSection : Section
{
    readonly FlowLayoutPanel grid = new() { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Ui.Bg };
    readonly Panel host = new() { Dock = DockStyle.Fill };
    readonly TextBox search = Ui.Input(tr("Search"));
    readonly Dictionary<string, Image> icons = new();

    public AppsSection()
    {
        search.Width = LogicalToDeviceUnits(220);
        search.Margin = new Padding(0, 6, 8, 0);
        search.TextChanged += (_, _) => Refresh2();
        Controls.Add(host);
        Controls.Add(Header(tr("Apps"), search, Ui.Button(tr("Refresh"), () => S.LoadApps())));
        var hint = Ui.Label(tr("Click an app to open it on the phone and show it in the mirror. Right-click: in its own window (USB debugging)."), Ui.Small, Ui.Sub);
        hint.Dock = DockStyle.Bottom;
        Controls.Add(hint);
        HandleCreated += (_, _) => Win.DarkScroll(grid);
    }

    public override void Shown() { Refresh2(); if (S.Connected && S.Apps.Count == 0) S.LoadApps(); }
    public override void Changed(string what) { if (what is "apps" or "status") Refresh2(); }

    void Refresh2()
    {
        host.Controls.Clear();
        var state = S.Apps.Count == 0 ? StateFor("apps", "apps", "") : null;
        if (state == null && S.Apps.Count == 0) state = new Placeholder(Glyph.Apps, tr("Loading…"), "");
        if (state != null) { host.Controls.Add(state); return; }
        var q = search.Text.Trim().ToLowerInvariant();
        grid.SuspendLayout();
        grid.Controls.Clear();
        foreach (var a in S.Apps.Where(a => q == "" || ((string)a["name"] ?? "").ToLowerInvariant().Contains(q)))
        {
            var pkg = (string)a["pkg"];
            if (!icons.TryGetValue(pkg, out var img)) icons[pkg] = img = Ui.FromBase64((string)a["icon"]);
            var b = new Button
            {
                Text = (string)a["name"], Image = img == null ? null : new Bitmap(img, LogicalToDeviceUnits(40), LogicalToDeviceUnits(40)),
                TextImageRelation = TextImageRelation.ImageAboveText, Size = new Size(LogicalToDeviceUnits(104), LogicalToDeviceUnits(92)),
                FlatStyle = FlatStyle.Flat, BackColor = Ui.Card, ForeColor = Ui.Text, Font = Ui.Small, Margin = new Padding(4), Cursor = Cursors.Hand,
                AutoEllipsis = true,
            };
            b.FlatAppearance.BorderColor = Ui.Line;
            b.FlatAppearance.MouseOverBackColor = Ui.Hover;
            var app = a;
            b.Click += (_, _) => S.OpenApp(app);
            // right-click: the app in its own window (Advanced, USB debugging + scrcpy)
            var cm = new ContextMenuStrip();
            cm.Items.Add(tr("Open on the phone"), null, (_, _) => S.OpenApp(app));
            cm.Items.Add(tr("Open in its own window (USB debugging)"), null, (_, _) => Advanced.OpenAppWindow(pkg, (string)app["name"]));
            b.ContextMenuStrip = cm;
            grid.Controls.Add(b);
        }
        grid.ResumeLayout();
        host.Controls.Add(grid);
    }
}

// =====================================================================

sealed class TransfersSection : Section
{
    readonly RowList list = new();
    readonly Panel host = new() { Dock = DockStyle.Fill };

    public TransfersSection()
    {
        Controls.Add(host);
        Controls.Add(Header(tr("Transfers"),
            Ui.Button(tr("Send files…"), () =>
            {
                using var d = new OpenFileDialog { Multiselect = true, Title = tr("Send files to the phone") };
                if (d.ShowDialog(FindForm()) == DialogResult.OK) S.Link.SendFiles(d.FileNames);
            }, primary: true),
            Ui.Button(tr("Open Downloads\\PhoneCast"), () => Ui.Shell(App.DownloadsDir))));
        list.Activated += r => { if (r.Tag is Store.Transfer t && t.Path != null) Ui.Shell(t.Path); };
        list.Menu += (r, p) =>
        {
            if (r.Tag is not Store.Transfer t || t.Path == null) return;
            var m = new ContextMenuStrip();
            m.Items.Add(tr("Open"), null, (_, _) => Ui.Shell(t.Path));
            m.Items.Add(tr("Show in folder"), null, (_, _) => Ui.Reveal(t.Path));
            m.Show(list, p);
        };
    }

    public override void Shown() => Refresh2();
    public override void Changed(string what) { if (what == "transfers") Refresh2(); }

    void Refresh2()
    {
        host.Controls.Clear();
        if (S.Transfers.Count == 0)
        {
            host.Controls.Add(new Placeholder(Glyph.Transfer, tr("Drop files here"),
                tr("Files dropped on this window go to the phone's Downloads/PhoneCast. Files from the phone land in Downloads\\PhoneCast on this PC.")));
            return;
        }
        list.SetRows(S.Transfers.Select(t => new Row
        {
            Key = t.Id.ToString(), Glyph = t.Outgoing ? Glyph.Up : Glyph.Download,
            GlyphColor = t.State == Store.TState.Failed ? Ui.Red : t.State == Store.TState.Done ? Ui.Green : Ui.Accent,
            Title = t.Name,
            Sub = (t.Outgoing ? tr("To the phone") : tr("From the phone")) + " · " +
                  (t.State == Store.TState.Running ? $"{t.Progress * 100:0} %" : t.State == Store.TState.Done ? tr("done") : tr("failed")) +
                  (t.Size > 0 ? " · " + Ui.Size(t.Size) : ""),
            Progress = t.State == Store.TState.Running ? t.Progress : null,
            Right = Ui.Ago(t.When), Tag = t,
        }));
        host.Controls.Add(list);
    }
}

// =====================================================================

sealed class SettingsSection : Section
{
    readonly FlowLayoutPanel flow = new() { Dock = DockStyle.Fill, AutoScroll = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, BackColor = Ui.Bg };
    readonly Label pairState = Ui.Label("", Ui.Body, null, 520), keyLabel = Ui.Label("", Ui.Small, Ui.Sub, 520), dndState = Ui.Label("", Ui.Small, Ui.Sub);
    readonly CheckedListBox apps = new() { CheckOnClick = true, BorderStyle = BorderStyle.None, IntegralHeight = false };
    readonly Label awakeState = Ui.Label("", Ui.Body, null, 520), webState = Ui.Label("", Ui.Body, null, 520),
        advState = Ui.Label("", Ui.Body, null, 520), advResult = Ui.Label("", Ui.Small, Ui.Sub, 520);
    bool advChecking;

    /// adb is slow: ask in the background.
    void RefreshAdvanced()
    {
        if (advChecking) return;
        advChecking = true;
        Task.Run(() => { var t = Advanced.Status(); Ui.Post(() => { advState.Text = t; advChecking = false; }); });
    }
    readonly FlowLayoutPanel perms = new() { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, BackColor = Color.Transparent };
    bool filling;
    const int W = 540;

    public SettingsSection()
    {
        Controls.Add(flow);
        Controls.Add(Header(tr("Settings")));
        HandleCreated += (_, _) => Win.DarkScroll(flow);
        int w = LogicalToDeviceUnits(W);
        Label Note(string t) => Ui.Label(t, Ui.Small, Ui.Sub, w);

        var pair = new CardPanel(tr("Pair a phone"), Glyph.Phone);
        pair.Controls.Add(pairState);
        pair.Controls.Add(Note(tr("Phone app → Settings → “Scan computer's QR code”. Both sides then prove a shared key to each other on every connection: no PIN to type, and nothing secret crosses the network.")));
        pair.Controls.Add(Ui.Row(
            Ui.Button(tr("Pair with QR code…"), () => S.Link.ShowPairing(), primary: true),
            Ui.Button(tr("PIN or address…"), () => S.Link.ShowConnect()),
            Ui.Button(tr("New QR code"), () =>
            {
                if (MessageBox.Show(FindForm(), tr("Phones paired by QR code have to scan the new code again. Continue?"), "PhoneCast", MessageBoxButtons.OKCancel) == DialogResult.OK) S.Link.NewPairCode();
            })));

        var sec = new CardPanel(tr("Security"), Glyph.Lock);
        sec.Controls.Add(keyLabel);
        sec.Controls.Add(Note(tr("The link (notifications, messages, files, clipboard) is encrypted with TLS 1.3 and only accepts this phone's key. The mirror's video isn't encrypted to keep it fast; away from home, Tailscale encrypts it.")));
        sec.Controls.Add(Ui.Button(tr("Forget phone key (after reinstalling PhoneCast on the phone)"), () => { S.Link.ForgetPhoneKey(); Fill(); }));

        var notif = new CardPanel(tr("Notifications"), Glyph.Bell);
        notif.Controls.Add(Ui.Check(tr("Show banners"), !S.MuteAll, on => { if (!filling) S.MuteAll = !on; }));
        notif.Controls.Add(Ui.Check(tr("Play a sound"), S.NotifSound, on => S.NotifSound = on));
        notif.Controls.Add(Ui.Check(tr("Quiet while the phone is on Do Not Disturb"), S.FollowPhoneDnd, on => S.FollowPhoneDnd = on));
        notif.Controls.Add(dndState);
        var hours = Enumerable.Range(0, 24).Select(h => $"{h:00}:00").ToList();
        var from = Ui.Combo(hours, S.QuietFrom, i => S.QuietFrom = i);
        var to = Ui.Combo(hours, S.QuietTo, i => S.QuietTo = i);
        from.Width = to.Width = LogicalToDeviceUnits(80);
        notif.Controls.Add(Ui.Row(Ui.Check(tr("Quiet hours from"), S.QuietHours, on => S.QuietHours = on), from, Ui.Label(tr("to")), to));
        notif.Controls.Add(Ui.Label(tr("Banners per app"), Ui.Bold));
        apps.Width = w; apps.Height = LogicalToDeviceUnits(150);
        apps.BackColor = Ui.Card; apps.ForeColor = Ui.Text; apps.Font = Ui.Body;
        apps.ItemCheck += (_, e) =>
        {
            if (filling || apps.Items[e.Index] is not AppItem a) return;
            S.SetAppMuted(a.Pkg, e.NewValue != CheckState.Checked);
        };
        notif.Controls.Add(apps);
        notif.Controls.Add(Note(tr("Apps appear here after their first notification.")));

        var clip = new CardPanel(tr("Clipboard"), Glyph.Doc);
        clip.Controls.Add(Ui.Check(tr("Copy to the phone automatically when I copy on this PC"), S.AutoClipboard, on => S.AutoClipboard = on));
        clip.Controls.Add(Note(tr("Text and pictures. From the phone: copying lands here by itself, or Share → “PhoneCast to Mac”. Ctrl+Shift+C in the mirror sends the clipboard by hand.")));

        var control = new CardPanel(tr("Control this PC from the phone"), Glyph.Keyboard);
        control.Controls.Add(Ui.Check(tr("Let the phone see and control this PC"), S.AllowControl, on => S.AllowControl = on));
        control.Controls.Add(Note(tr("On the phone: the Mac tab → “Open the PC's screen” or “Trackpad & keyboard only”, plus volume, media, lock, screen off, screenshot and the browser tab. With a Mac and this PC both linked, pick this PC at the top of that tab. Keys: ⌘ = Ctrl, ⌥ = Alt, ⌃ = Windows key.")));

        var awake = new CardPanel(tr("Stay awake"), Glyph.Power);
        awake.Controls.Add(awakeState);
        awake.Controls.Add(Ui.Row(
            Ui.Button(tr("1 hour"), () => KeepAwake.Shared.Enable(60)), Ui.Button(tr("2 hours"), () => KeepAwake.Shared.Enable(120)),
            Ui.Button(tr("8 hours"), () => KeepAwake.Shared.Enable(480)), Ui.Button(tr("Until I turn it off"), () => KeepAwake.Shared.Enable(0)),
            Ui.Button(tr("Off"), () => KeepAwake.Shared.Disable(null))));
        awake.Controls.Add(Note(tr("While on, this PC doesn't go to sleep, and closing a laptop's lid does nothing, so the phone can still reach it. Turns itself off on battery at {0} % and when PhoneCast quits. Also in the tray and on the phone's Mac tab.", KeepAwake.Shared.MinBattery)));

        var web = new CardPanel(tr("Phone in a browser"), Glyph.Globe);
        web.Controls.Add(Ui.Check(tr("Show the phone's notifications and messages on other devices in my network"), Settings.Bool("phoneWeb"), on => { Settings.Set("phoneWeb", on); PhoneWeb.Apply(); Fill(); }));
        web.Controls.Add(webState);
        web.Controls.Add(Ui.Row(Ui.Button(tr("New code"), () => { PhoneWeb.NewCode(); Fill(); }), Ui.Button(tr("Open it here"), () => Ui.Shell($"http://localhost:{PhoneWeb.Port}/phone"))));
        web.Controls.Add(Note(tr("For an iPad or a school laptop: open the address there and enter the code. It goes through this PC's link, so nothing leaves your network. Windows asks once whether to allow PhoneCast through the firewall: allow it for private networks.")));

        var adv = new CardPanel(tr("Advanced (USB debugging)"), Glyph.Gamepad);
        adv.Controls.Add(advState);
        var shapes = new[] { "tall", "wide", "phone" };
        var shapeBox = Ui.Combo(new[] { tr("Tall (phone app)"), tr("Wide (tablet app)"), tr("The phone's own size") }, Math.Max(0, Array.IndexOf(shapes, Advanced.AppShape)), i => Advanced.AppShape = shapes[i]);
        shapeBox.Width = LogicalToDeviceUnits(200);
        adv.Controls.Add(Ui.Row(Ui.Label(tr("App windows:")), shapeBox));
        adv.Controls.Add(Ui.Row(Ui.Button(tr("Phone camera (back)"), () => Advanced.Camera("back")), Ui.Button(tr("Phone camera (front)"), () => Advanced.Camera("front")), Ui.Button(tr("Stop camera"), () => Advanced.Stop("camera"))));
        adv.Controls.Add(Ui.Check(tr("Play the phone's microphone on this PC"), Advanced.Running("mic"), on => Advanced.Microphone(on)));
        adv.Controls.Add(Ui.Check(tr("Turn the phone's screen off while it's mirrored"), Settings.Bool("advancedScreenOff"), on => Advanced.ScreenOff(on)));
        var pairAddr = Ui.Input(tr("IP:port")); var pairCode = Ui.Input(tr("Code")); var connAddr = Ui.Input(tr("IP:port"));
        pairAddr.Width = connAddr.Width = LogicalToDeviceUnits(160); pairCode.Width = LogicalToDeviceUnits(90);
        adv.Controls.Add(Ui.Row(Ui.Label(tr("Wireless debugging:")), pairAddr, pairCode, Ui.Button(tr("Pair"), () => Task.Run(() => { var r = Advanced.Pair(pairAddr.Text, pairCode.Text); Ui.Post(() => { advResult.Text = r; RefreshAdvanced(); }); }))));
        adv.Controls.Add(Ui.Row(Ui.Label(tr("then connect to:")), connAddr, Ui.Button(tr("Connect"), () => Task.Run(() => { var r = Advanced.Connect(connAddr.Text); Ui.Post(() => { advResult.Text = r; RefreshAdvanced(); }); }))));
        adv.Controls.Add(advResult);
        adv.Controls.Add(Note(tr("Phone apps in their own windows (right-click an app in Apps), the phone's camera as a window for calls or OBS, its microphone, and a really dark phone screen while mirroring. Needs USB debugging on the phone and scrcpy on this PC (winget install Genymobile.scrcpy). Nothing else in PhoneCast needs it.")));

        var files = new CardPanel(tr("Files"), Glyph.Folder);
        files.Controls.Add(Note(tr("Explorer: right-click files → Send to → PhoneCast (phone). They land in the phone's Downloads. The phone's storage opens as a drive with Files → Open in File Explorer (or the tray).")));
        files.Controls.Add(Ui.Button(tr("Open the phone in File Explorer"), PhoneDrive.Open));

        var lockCard = new CardPanel(tr("Lock this PC when the phone leaves"), Glyph.Lock);
        var mins = new[] { 1, 2, 5, 10 };
        var minBox = Ui.Combo(mins.Select(m => tr("{0} min", m)), Array.IndexOf(mins, S.AutoLockMinutes) is int ix && ix >= 0 ? ix : 1, i => S.AutoLockMinutes = mins[i]);
        minBox.Width = LogicalToDeviceUnits(90);
        lockCard.Controls.Add(Ui.Row(Ui.Check(tr("Lock when the phone has been gone for"), S.AutoLock, on => S.AutoLock = on), minBox));
        lockCard.Controls.Add(Note(tr("Locks only when the phone's link has been gone that long AND nobody has touched this PC's keyboard or mouse for that long, so it never locks while you work.")));

        var dev = new CardPanel(tr("Devices to watch"), Glyph.Network);
        var devBox = Ui.Input("", multiline: true);
        devBox.Width = w; devBox.Height = LogicalToDeviceUnits(90);
        devBox.ScrollBars = ScrollBars.Vertical;
        devBox.Text = S.DevicesConfig.Replace("\n", "\r\n");
        dev.Controls.Add(devBox);
        dev.Controls.Add(Ui.Row(Ui.Button(tr("Save"), () => S.DevicesConfig = devBox.Text.Replace("\r\n", "\n").Trim()), Note(tr("One per line: name, then host:port (for example “NAS 192.168.1.10:445”)."))));

        var pc = new CardPanel(tr("This PC"), Glyph.Pc);
        pc.Controls.Add(Ui.Check(tr("Start PhoneCast when I sign in to Windows"), Autostart.Enabled, on => Autostart.Enabled = on));
        pc.Controls.Add(Ui.Row(
            Ui.Button(tr("Check for updates"), () => Updater.Check(FindForm(), quiet: false)),
            Ui.Button(tr("Open log folder"), () => Ui.Shell(Settings.LogDir))));
        pc.Controls.Add(Note(tr("PhoneCast {0} · language follows Windows (English or German).", Application.ProductVersion.Split('+')[0])));

        var phone = new CardPanel(tr("Phone"), Glyph.Phone);
        phone.Controls.Add(perms);
        phone.Controls.Add(Note(tr("Missing ones are allowed in the PhoneCast app on the phone (Phone features on the computer).")));

        foreach (var c in new Control[] { pair, sec, notif, clip, control, awake, files, web, lockCard, dev, adv, pc, phone })
        {
            c.MinimumSize = new Size(w + LogicalToDeviceUnits(32), 0);
            flow.Controls.Add(c);
        }
        Fill();
    }

    sealed class AppItem { public string Pkg, Name; public override string ToString() => Name; }

    public override void Shown() { Fill(); RefreshAdvanced(); }
    public override void Changed(string what) { if (what is "settings" or "status" or "pc") Fill(); }

    void Fill()
    {
        filling = true;
        bool qr = Settings.Bool("qrPaired"), pin = !string.IsNullOrEmpty(Settings.Str("pin"));
        pairState.Text = S.Connected ? tr("Connected to {0}.", S.PhoneName) + (qr ? " " + tr("Paired by QR code.") : "")
            : qr ? tr("Paired by QR code. Waiting for the phone…") : pin ? tr("Uses the PIN. Waiting for the phone…") : tr("Not paired yet: scan this PC's QR code with the phone.");
        var key = Settings.Str("phoneKey");
        keyLabel.Text = key == null ? tr("No phone key yet (saved on the first connection).") : tr("Phone key: {0}", string.Join(" ", Enumerable.Range(0, Math.Min(8, key.Length / 4)).Select(i => key.Substring(i * 4, 4))) + " …");
        var ka = KeepAwake.Shared;
        awakeState.Text = ka.On ? tr("On · {0}", ka.Summary) : tr("Off");
        awakeState.ForeColor = ka.On ? Ui.Orange : Ui.Text;
        webState.Text = PhoneWeb.Running ? tr("On. Address: {0} · code {1}", string.Join("  or  ", PhoneWeb.Urls().Take(2)), PhoneWeb.Code) : tr("Off");
        dndState.Text = S.Connected ? (S.PhoneDnd ? tr("The phone is on Do Not Disturb now.") : tr("The phone isn't on Do Not Disturb.")) : "";

        var muted = S.MutedApps;
        var names = S.AppNames.OrderBy(kv => kv.Value, StringComparer.CurrentCultureIgnoreCase).ToList();
        if (apps.Items.Count != names.Count || names.Where((kv, i) => ((AppItem)apps.Items[i]).Pkg != kv.Key).Any())
        {
            apps.BeginUpdate();
            apps.Items.Clear();
            foreach (var (pkg, name) in names) apps.Items.Add(new AppItem { Pkg = pkg, Name = name }, !muted.Contains(pkg));
            apps.EndUpdate();
        }
        else for (int i = 0; i < apps.Items.Count; i++) apps.SetItemChecked(i, !muted.Contains(((AppItem)apps.Items[i]).Pkg));

        perms.Controls.Clear();
        if (!S.Connected || S.Perms.Count == 0) perms.Controls.Add(Ui.Label(tr("Shown once the phone is connected."), Ui.Body, Ui.Sub));
        else
            foreach (var (k, label) in new[] { ("notifications", "Notifications"), ("sms", "Messages (SMS)"), ("calls", "Call log"), ("callControl", "Answer and place calls"), ("contacts", "Contacts"), ("photos", "Photos and videos"), ("files", "All files access"), ("control", "Mouse & keyboard (mirror)") })
            {
                bool ok = S.Perms.GetValueOrDefault(k);
                perms.Controls.Add(Ui.Row(new Label { Text = ok ? Glyph.Check : Glyph.Cancel, Font = Ui.IconFont(10), ForeColor = ok ? Ui.Green : Ui.Red, AutoSize = true, Margin = new Padding(0, 4, 6, 0) }, Ui.Label(tr(label))));
            }
        filling = false;
    }
}

/// "Start PhoneCast when I sign in": HKCU\…\Run (starts in the tray, no window).
static class Autostart
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static bool Enabled
    {
        get
        {
            try { using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(Key); return k?.GetValue("PhoneCast") != null; } catch { return false; }
        }
        set
        {
            try
            {
                using var k = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Key);
                if (value) k.SetValue("PhoneCast", $"\"{Environment.ProcessPath}\" --tray");
                else k.DeleteValue("PhoneCast", false);
            }
            catch (Exception e) { App.Log("autostart: " + e.Message); }
        }
    }
}
