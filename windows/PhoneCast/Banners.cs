using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PhoneCast;

/// PhoneCast's own banners (bottom right, above the taskbar): phone notifications with reply / open /
/// clear, incoming calls with Answer / Decline, received files, short info. They don't need Windows'
/// notification settings, and replying works right in the banner. Call from any thread.
static class Banners
{
    static readonly List<BannerForm> shown = new();
    const int MaxShown = 4;

    static void OnUi(Action a) { if (Ui.OnUiThread) a(); else Ui.Post(a); }

    public static void Show(Store.Notif n, Image icon) => OnUi(() =>
    {
        var b = new BannerForm(n.Key, icon, n.App, n.Title, n.Text, sticky: false);
        b.BodyClick = () => { MainForm.Open("notifications"); b.Close(); };
        if (n.CanReply) b.AddReply(text => { Store.Shared.ReplyTo(n, text); b.Close(); });
        b.AddButton(tr("Open on phone"), () => { Store.Shared.Open(n); b.Close(); });
        b.AddButton(tr("Clear"), () => { Store.Shared.Dismiss(n); b.Close(); });
        Present(b, sound: true);
    });

    public static void ShowCall(Dictionary<string, string> c) => OnUi(() =>
    {
        var who = c.GetValueOrDefault("name") is string nm && nm != "" ? nm : c.GetValueOrDefault("number") ?? tr("Unknown");
        bool ringing = c.GetValueOrDefault("state") == "ringing";
        var existing = shown.Find(x => x.Key == "call");
        existing?.Close();
        var b = new BannerForm("call", null, tr("Phone call"), ringing ? tr("{0} is calling", who) : tr("On a call with {0}", who),
            ringing ? tr("Answer here; you talk on the phone or its headset.") : "", sticky: true, glyph: Glyph.Phone);
        if (ringing) b.AddButton(tr("Answer"), () => Store.Shared.Answer(), color: Ui.Green);
        b.AddButton(ringing ? tr("Decline") : tr("End"), () => { Store.Shared.HangUp(); b.Close(); }, color: Ui.Red);
        Present(b, sound: ringing);
    });

    public static void EndCall() => OnUi(() => shown.Find(x => x.Key == "call")?.Close());

    public static void File(string path, string from) => OnUi(() =>
    {
        var b = new BannerForm("file:" + path, null, from, Path.GetFileName(path), tr("Saved in Downloads\\PhoneCast"), sticky: false, glyph: Glyph.Download);
        b.BodyClick = () => { Ui.Shell(path); b.Close(); };
        b.AddButton(tr("Open"), () => { Ui.Shell(path); b.Close(); });
        b.AddButton(tr("Show in folder"), () => { Ui.Reveal(path); b.Close(); });
        Present(b, sound: false);
    });

    public static void Info(string title, string text, Action click = null) => OnUi(() =>
    {
        var b = new BannerForm(null, null, "PhoneCast", title, text ?? "", sticky: false, glyph: Glyph.Phone, life: 5);
        if (click != null) b.BodyClick = () => { click(); b.Close(); };
        Present(b, sound: false);
    });

    public static void Remove(string key) => OnUi(() => { foreach (var b in shown.Where(x => x.Key == key).ToList()) b.Close(); });
    public static void RemoveAll() => OnUi(() => { foreach (var b in shown.ToList()) if (b.Key != "call") b.Close(); });

    static void Present(BannerForm b, bool sound)
    {
        if (b.Key != null) foreach (var old in shown.Where(x => x.Key == b.Key).ToList()) old.Close();
        while (shown.Count >= MaxShown && shown.FirstOrDefault(x => !x.Sticky) is BannerForm oldest) oldest.Close();
        shown.Add(b);
        b.FormClosed += (_, _) => { shown.Remove(b); Layout(); };
        Layout(b);
        b.Show();
        if (sound && Store.Shared.NotifSound) PlaySound("Notification.Default", IntPtr.Zero, 0x00010000 | 0x0001 | 0x0002); // SND_ALIAS | ASYNC | NODEFAULT
    }

    static void Layout(BannerForm fresh = null)
    {
        var area = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1280, 720);
        int gap = 10, y = area.Bottom - gap;
        foreach (var b in Enumerable.Reverse(shown).ToList())
        {
            y -= b.Height;
            b.Location = new Point(area.Right - b.Width - gap, y);
            y -= gap;
        }
    }

    internal static void Relayout() => Layout();

    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern bool PlaySound(string sound, IntPtr mod, uint flags);
}

sealed class BannerForm : Form
{
    public readonly string Key;
    public readonly bool Sticky;
    public Action BodyClick;
    readonly FlowLayoutPanel buttons;
    readonly TableLayoutPanel body;
    readonly System.Windows.Forms.Timer life;
    double left;
    TextBox reply;

    public BannerForm(string key, Image icon, string app, string title, string text, bool sticky, string glyph = null, double life = 7)
    {
        Key = key; Sticky = sticky; left = life;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Ui.Card;
        Font = Ui.Body;
        Width = LogicalToDeviceUnits(380);
        Padding = new Padding(LogicalToDeviceUnits(12));
        Ui.Chrome(this, round: true);

        body = new TableLayoutPanel { ColumnCount = 3, RowCount = 4, Dock = DockStyle.Top, AutoSize = true, BackColor = Color.Transparent };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        body.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        Control pic = icon != null
            ? new PictureBox { Image = icon, SizeMode = PictureBoxSizeMode.Zoom, Width = LogicalToDeviceUnits(32), Height = LogicalToDeviceUnits(32), Margin = new Padding(0, 2, 10, 0) }
            : new Label { Text = glyph ?? Glyph.Bell, Font = Ui.IconFont(18), ForeColor = Ui.Accent, AutoSize = true, Margin = new Padding(0, 4, 10, 0) };
        body.Controls.Add(pic, 0, 0);
        body.SetRowSpan(pic, 3);
        var appL = Ui.Label(app, Ui.Small, Ui.Sub);
        body.Controls.Add(appL, 1, 0);
        var close = new Label { Text = Glyph.Cancel, Font = Ui.IconFont(9), ForeColor = Ui.Sub, AutoSize = true, Cursor = Cursors.Hand, Margin = new Padding(6, 2, 0, 0) };
        close.Click += (_, _) => Close();
        body.Controls.Add(close, 2, 0);
        var titleL = Ui.Label(title, Ui.Bold, Ui.Text, LogicalToDeviceUnits(290));
        body.Controls.Add(titleL, 1, 1);
        body.SetColumnSpan(titleL, 2);
        if (!string.IsNullOrEmpty(text))
        {
            var t = text.Length > 300 ? text[..300] + "…" : text;
            var textL = Ui.Label(t, Ui.Body, Ui.Sub, LogicalToDeviceUnits(290));
            textL.MaximumSize = new Size(LogicalToDeviceUnits(290), LogicalToDeviceUnits(60));
            body.Controls.Add(textL, 1, 2);
            body.SetColumnSpan(textL, 2);
        }
        buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = true, BackColor = Color.Transparent, Margin = new Padding(0, 6, 0, 0) };
        body.Controls.Add(buttons, 1, 3);
        body.SetColumnSpan(buttons, 2);
        Controls.Add(body);

        foreach (Control c in new Control[] { body, appL, titleL, pic })
            c.Click += (_, _) => BodyClick?.Invoke();
        foreach (Control c in body.Controls) if (c is Label l && l != close) l.Click += (_, _) => BodyClick?.Invoke();

        this.life = new System.Windows.Forms.Timer { Interval = 250 };
        this.life.Tick += (_, _) =>
        {
            if (Sticky || Bounds.Contains(Cursor.Position) || (reply != null && reply.Focused)) return;
            left -= 0.25;
            if (left <= 0) Close();
        };
        this.life.Start();
        FormClosed += (_, _) => this.life.Dispose();
        SizeHeight();
    }

    void SizeHeight()
    {
        body.PerformLayout();
        Height = body.PreferredSize.Height + Padding.Vertical;
    }

    public void AddButton(string text, Action click, Color? color = null)
    {
        var b = Ui.Button(text, click);
        if (color is Color c) { b.BackColor = c; b.ForeColor = Color.White; b.FlatAppearance.BorderSize = 0; b.FlatAppearance.MouseOverBackColor = ControlPaint.Light(c, 0.2f); }
        buttons.Controls.Add(b);
        SizeHeight();
    }

    public void AddReply(Action<string> send)
    {
        var open = Ui.Button(tr("Reply"), null, primary: true);
        buttons.Controls.Add(open);
        open.Click += (_, _) =>
        {
            if (reply != null) return;
            reply = Ui.Input(tr("Reply…"));
            reply.Width = LogicalToDeviceUnits(220);
            reply.Margin = new Padding(0, 6, 8, 4);
            var go = Ui.Button(tr("Send"), () => { if (reply.Text.Trim() != "") send(reply.Text.Trim()); }, primary: true);
            reply.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; go.PerformClick(); } if (e.KeyCode == Keys.Escape) Close(); };
            buttons.Controls.Clear();
            buttons.Controls.Add(reply);
            buttons.Controls.Add(go);
            SizeHeight();
            Banners.Relayout();
            Activate();
            reply.Focus();
        };
        SizeHeight();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x80 | 0x08;   // WS_EX_TOOLWINDOW | WS_EX_TOPMOST
            cp.ClassStyle |= 0x20000;    // CS_DROPSHADOW
            return cp;
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        using var pen = new Pen(Ui.Line);
        e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
    }
}
