using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace PhoneCast;

/// The PhoneCast window: a sidebar (Overview, Mirror, Notifications, Messages, Calls, Contacts, Photos,
/// Files, Apps, Transfers, Settings) and the section on the right. Closing it hides it; PhoneCast keeps
/// running in the tray (notification area).
sealed class MainForm : Form
{
    public static MainForm Instance;
    public static bool Quitting;

    static readonly (string key, string title, string glyph)[] Sections =
    {
        ("overview", "Overview", Glyph.Home), ("mirror", "Mirror", Glyph.Mirror), ("notifications", "Notifications", Glyph.Bell),
        ("messages", "Messages", Glyph.Message), ("calls", "Calls", Glyph.Phone), ("contacts", "Contacts", Glyph.Contact),
        ("photos", "Photos", Glyph.Photo), ("files", "Files", Glyph.Folder), ("apps", "Apps", Glyph.Apps),
        ("transfers", "Transfers", Glyph.Transfer), ("settings", "Settings", Glyph.Settings),
    };

    readonly NavList nav = new();
    readonly Panel content = new() { Dock = DockStyle.Fill };
    readonly Label phoneName = Ui.Label("", Ui.H2), phoneState = Ui.Label("", Ui.Small, Ui.Sub);
    readonly Dictionary<string, Section> built = new();
    Section current;
    string currentKey;
    static bool toldTray = Settings.Bool("toldTray");

    /// Shows the window (creating it once) at [section]. Any thread.
    public static void Open(string section = null)
    {
        void Go()
        {
            Instance ??= new MainForm();
            if (!Instance.Visible) Instance.Show();
            if (Instance.WindowState == FormWindowState.Minimized) Instance.WindowState = FormWindowState.Normal;
            Instance.Activate();
            if (section != null) Instance.ShowSection(section);
        }
        if (Ui.OnUiThread) Go(); else Ui.Post(Go);
    }

    MainForm()
    {
        Text = "PhoneCast";
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = Ui.Body;
        BackColor = Ui.Bg;
        ForeColor = Ui.Text;
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(LogicalToDeviceUnits(Settings.Int("mainW", 1020)), LogicalToDeviceUnits(Settings.Int("mainH", 700)));
        MinimumSize = new Size(LogicalToDeviceUnits(760), LogicalToDeviceUnits(500));
        Ui.Chrome(this);
        Tray.SetFormIcon(this);
        AllowDrop = true;

        var side = new Panel { Dock = DockStyle.Left, Width = LogicalToDeviceUnits(230), BackColor = Ui.Side, Padding = new Padding(LogicalToDeviceUnits(10)) };
        var head = new FlowLayoutPanel { Dock = DockStyle.Top, FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Padding = new Padding(LogicalToDeviceUnits(6), LogicalToDeviceUnits(6), 0, LogicalToDeviceUnits(14)) };
        phoneName.MaximumSize = new Size(LogicalToDeviceUnits(200), 0);
        phoneState.MaximumSize = new Size(LogicalToDeviceUnits(200), 0);
        head.Controls.Add(phoneName);
        head.Controls.Add(phoneState);
        nav.Dock = DockStyle.Fill;
        foreach (var (k, t, g) in Sections) nav.Items.Add(new NavItem { Key = k, Title = tr(t), Glyph = g });
        nav.SelectedIndexChanged += (_, _) => { if (nav.SelectedItem is NavItem n) ShowSection(n.Key); };
        side.Controls.Add(nav);
        side.Controls.Add(head);

        content.BackColor = Ui.Bg;
        content.Padding = new Padding(LogicalToDeviceUnits(24), LogicalToDeviceUnits(18), LogicalToDeviceUnits(24), LogicalToDeviceUnits(18));
        Controls.Add(content);
        Controls.Add(side);

        Store.Shared.Changed += OnChanged;
        UpdateHeader();
        ShowSection(Settings.Bool("qrPaired") || Settings.Str("pin") != null ? "overview" : "settings");

        DragEnter += (_, e) => { if (e.Data?.GetDataPresent(DataFormats.FileDrop) == true) e.Effect = DragDropEffects.Copy; };
        DragDrop += (_, e) =>
        {
            if (e.Data?.GetData(DataFormats.FileDrop) is string[] files && files.Length > 0)
                Store.Shared.Link.SendFiles(files, current is FilesSection fs ? fs.DropFolder : null);
        };
    }

    void OnChanged(string what)
    {
        if (IsDisposed) return;
        if (what is "status" or "notifications" or "messages" or "transfers") { UpdateHeader(); nav.Invalidate(); }
        try { current?.Changed(what); } catch (Exception e) { App.Log("ui section: " + e); }
    }

    void UpdateHeader()
    {
        var s = Store.Shared;
        phoneName.Text = s.Connected ? s.PhoneName : tr("PhoneCast");
        phoneState.Text = s.Connected
            ? string.Join(" · ", new[] { tr("Connected"), s.PhoneSummary }.Where(x => !string.IsNullOrEmpty(x)))
            : (Settings.Bool("qrPaired") || Settings.Str("pin") != null ? tr("Looking for the phone…") : tr("Not paired yet"));
        phoneState.ForeColor = s.Connected ? Ui.Green : Ui.Sub;
        foreach (NavItem n in nav.Items)
            n.Badge = n.Key switch
            {
                "notifications" => s.Notifs.Count,
                "messages" => s.Threads.Sum(t => (int?)t["unread"] ?? 0),
                "transfers" => s.Transfers.Count(t => t.State == Store.TState.Running),
                _ => 0,
            };
        Tray.Update();
    }

    public void ShowSection(string key)
    {
        if (key == currentKey && current != null) { current.Shown(); return; }
        if (!built.TryGetValue(key, out var sec))
        {
            sec = key switch
            {
                "overview" => new OverviewSection(),
                "mirror" => new MirrorSection(),
                "notifications" => new NotificationsSection(),
                "messages" => new MessagesSection(),
                "calls" => new CallsSection(),
                "contacts" => new ContactsSection(),
                "photos" => new PhotosSection(),
                "files" => new FilesSection(),
                "apps" => new AppsSection(),
                "transfers" => new TransfersSection(),
                _ => new SettingsSection(),
            };
            sec.Dock = DockStyle.Fill;
            built[key] = sec;
        }
        content.SuspendLayout();
        content.Controls.Clear();
        content.Controls.Add(sec);
        content.ResumeLayout();
        current = sec;
        currentKey = key;
        for (int i = 0; i < nav.Items.Count; i++) if (((NavItem)nav.Items[i]).Key == key && nav.SelectedIndex != i) nav.SelectedIndex = i;
        sec.Shown();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (WindowState == FormWindowState.Normal)
        {
            Settings.Set("mainW", (int)(Width * 96f / DeviceDpi));
            Settings.Set("mainH", (int)(Height * 96f / DeviceDpi));
        }
        if (!Quitting && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            if (!toldTray)
            {
                toldTray = true; Settings.Set("toldTray", true);
                Banners.Info(tr("PhoneCast keeps running"), tr("Notifications, calls and the clipboard still come to this PC. Open PhoneCast again from the tray icon."));
            }
            return;
        }
        Store.Shared.Changed -= OnChanged;
        base.OnFormClosing(e);
    }
}

/// One page of the window.
abstract class Section : Panel
{
    protected Section() { BackColor = Ui.Bg; Font = Ui.Body; }
    /// The section was opened (load what it shows).
    public virtual void Shown() { }
    /// Store changed [what].
    public virtual void Changed(string what) { }

    protected static Store S => Store.Shared;

    /// A title row: big title on the left, controls on the right.
    protected Panel Header(string title, params Control[] right)
    {
        var p = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, BackColor = Color.Transparent, Padding = new Padding(0, 0, 0, LogicalToDeviceUnits(10)) };
        p.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        p.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        p.Controls.Add(Ui.Label(title, Ui.H1), 0, 0);
        var flow = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Anchor = AnchorStyles.Right, Margin = new Padding(0, 6, 0, 0) };
        flow.Controls.AddRange(right);
        p.Controls.Add(flow, 1, 0);
        return p;
    }

    /// Not connected / permission / error states shared by the phone sections. Returns null when fine.
    protected Control StateFor(string section, string what, string perm)
    {
        if (!S.Connected)
            return new Placeholder(Glyph.Disconnected, tr("Phone not connected"),
                tr("Open PhoneCast on the phone. It connects by itself over Wi-Fi, Tailscale or the USB cable."),
                Settings.Bool("qrPaired") || Settings.Str("pin") != null ? null : tr("Pair with QR code"), () => S.Link.ShowPairing());
        if (S.Errors.TryGetValue(section, out var err))
        {
            if (err == "permission")
                return new Placeholder(Glyph.Lock, tr("Allow {0} on the phone", tr(what)),
                    tr("Open PhoneCast on the phone → Phone features on the computer, and allow {0}.", tr(perm)), tr("Try again"), () => Shown());
            return new Placeholder(Glyph.Warning, tr("Couldn't load {0}", tr(what)), err, tr("Try again"), () => Shown());
        }
        return null;
    }
}

sealed class NavItem { public string Key, Title, Glyph; public int Badge; }

/// The sidebar list.
sealed class NavList : ListBox
{
    public NavList()
    {
        DrawMode = DrawMode.OwnerDrawFixed;
        BorderStyle = BorderStyle.None;
        BackColor = Ui.Side;
        IntegralHeight = false;
        ItemHeight = 36;
        Font = Ui.Body;
    }

    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); ItemHeight = LogicalToDeviceUnits(36); }

    protected override void OnDrawItem(DrawItemEventArgs e)
    {
        if (e.Index < 0 || e.Index >= Items.Count) return;
        var n = (NavItem)Items[e.Index];
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var bg = new SolidBrush(BackColor)) g.FillRectangle(bg, e.Bounds);
        bool sel = (e.State & DrawItemState.Selected) != 0;
        var r = Rectangle.Inflate(e.Bounds, 0, -LogicalToDeviceUnits(2));
        if (sel)
        {
            using var p = Ui.Round(r, LogicalToDeviceUnits(6));
            using var b = new SolidBrush(Ui.Selected);
            g.FillPath(b, p);
            using var bar = new SolidBrush(Ui.Accent);
            g.FillRectangle(bar, r.X, r.Y + r.Height / 4, LogicalToDeviceUnits(3), r.Height / 2);
        }
        using var icon = Ui.IconFont(11);
        TextRenderer.DrawText(g, n.Glyph, icon, new Rectangle(r.X + LogicalToDeviceUnits(12), r.Y, LogicalToDeviceUnits(22), r.Height), sel ? Ui.Accent : Ui.Text, TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter);
        TextRenderer.DrawText(g, n.Title, sel ? Ui.Bold : Ui.Body, new Rectangle(r.X + LogicalToDeviceUnits(44), r.Y, r.Width - LogicalToDeviceUnits(80), r.Height), Ui.Text, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        if (n.Badge > 0)
        {
            var s = n.Badge > 99 ? "99+" : n.Badge.ToString();
            var sz = TextRenderer.MeasureText(s, Ui.Small);
            int bw = Math.Max(sz.Width + LogicalToDeviceUnits(6), LogicalToDeviceUnits(20)), bh = LogicalToDeviceUnits(18);
            var br = new Rectangle(r.Right - bw - LogicalToDeviceUnits(8), r.Y + (r.Height - bh) / 2, bw, bh);
            using var p = Ui.Round(br, bh / 2f);
            using var b = new SolidBrush(Ui.Accent);
            g.FillPath(b, p);
            TextRenderer.DrawText(g, s, Ui.Small, br, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }
}
