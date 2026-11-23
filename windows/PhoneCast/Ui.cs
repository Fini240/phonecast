global using static PhoneCast.L10n;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PhoneCast;

/// The PhoneCast window, banners and tray icon live on their own UI thread with a normal WinForms
/// message loop (the mirror's SDL loop runs on the main thread). Everything the UI shows is owned by
/// this thread: other threads hand work over with Ui.Post.
static class Ui
{
    static Control marshal;
    public static int ThreadId { get; private set; }

    public static void Start(Action ready)
    {
        var started = new ManualResetEventSlim();
        var t = new Thread(() =>
        {
            ThreadId = Environment.CurrentManagedThreadId;
            marshal = new Control();
            marshal.CreateControl();
            _ = marshal.Handle;
            started.Set();
            try { ready(); } catch (Exception e) { App.Log("ui: " + e); }
            Application.ThreadException += (_, e) => App.Log("ui crash: " + e.Exception);
            Application.Run();
        }) { IsBackground = true, Name = "ui" };
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        started.Wait();
    }

    public static void Post(Action a)
    {
        if (marshal == null || marshal.IsDisposed) return;
        try
        {
            marshal.BeginInvoke(() => { try { a(); } catch (Exception e) { App.Log("ui: " + e); } });
        }
        catch (InvalidOperationException) { }
    }

    public static bool OnUiThread => Environment.CurrentManagedThreadId == ThreadId;

    // ---------- theme ----------

    public static readonly bool Dark = ReadDark();
    static bool ReadDark()
    {
        try
        {
            using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    public static readonly Color Bg = Dark ? Color.FromArgb(32, 32, 32) : Color.FromArgb(243, 243, 243);
    public static readonly Color Side = Dark ? Color.FromArgb(26, 26, 26) : Color.FromArgb(235, 235, 235);
    public static readonly Color Card = Dark ? Color.FromArgb(43, 43, 43) : Color.White;
    public static readonly Color Hover = Dark ? Color.FromArgb(55, 55, 55) : Color.FromArgb(229, 229, 229);
    public static readonly Color Selected = Dark ? Color.FromArgb(61, 61, 61) : Color.FromArgb(220, 228, 240);
    public static readonly Color Line = Dark ? Color.FromArgb(60, 60, 60) : Color.FromArgb(222, 222, 222);
    public static readonly Color Text = Dark ? Color.FromArgb(240, 240, 240) : Color.FromArgb(26, 26, 26);
    public static readonly Color Sub = Dark ? Color.FromArgb(170, 170, 170) : Color.FromArgb(96, 96, 96);
    public static readonly Color Accent = Dark ? Color.FromArgb(96, 165, 250) : Color.FromArgb(0, 95, 184);
    public static readonly Color AccentText = Color.White;
    public static readonly Color Green = Color.FromArgb(16, 160, 80);
    public static readonly Color Orange = Color.FromArgb(230, 140, 0);
    public static readonly Color Red = Color.FromArgb(210, 50, 50);
    public static readonly Color Mine = Dark ? Color.FromArgb(0, 95, 184) : Color.FromArgb(0, 103, 192);
    public static readonly Color Theirs = Dark ? Color.FromArgb(58, 58, 58) : Color.FromArgb(232, 232, 232);
    public static readonly Color InputBg = Dark ? Color.FromArgb(50, 50, 50) : Color.White;

    public static readonly Font Body = new("Segoe UI", 9.5f);
    public static readonly Font Bold = new("Segoe UI Semibold", 9.5f);
    public static readonly Font Small = new("Segoe UI", 8.5f);
    public static readonly Font H1 = new("Segoe UI Semibold", 18f);
    public static readonly Font H2 = new("Segoe UI Semibold", 11.5f);
    public static readonly string IconFontName = FontExists("Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";
    public static Font IconFont(float size) => new(IconFontName, size);

    static bool FontExists(string name)
    {
        try { using var f = new Font(name, 10); return f.Name == name; } catch { return false; }
    }

    /// Dark title bar and rounded corners (Windows 11) for our windows.
    public static void Chrome(Form f, bool round = false)
    {
        f.HandleCreated += (_, _) =>
        {
            try
            {
                int on = Dark ? 1 : 0;
                DwmSetWindowAttribute(f.Handle, 20, ref on, 4);
                if (round) { int r = 2; DwmSetWindowAttribute(f.Handle, 33, ref r, 4); }
            }
            catch { }
        };
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);

    // ---------- small widgets ----------

    public static Label Label(string text, Font font = null, Color? color = null, int maxWidth = 0)
    {
        var l = new Label { Text = text, AutoSize = true, Font = font ?? Body, ForeColor = color ?? Text, BackColor = Color.Transparent, Margin = new Padding(0, 2, 0, 2) };
        if (maxWidth > 0) l.MaximumSize = new Size(maxWidth, 0);
        return l;
    }

    public static FlatButton Button(string text, Action click, bool primary = false)
    {
        var b = new FlatButton(text, primary);
        if (click != null) b.Click += (_, _) => click();
        return b;
    }

    public static CheckBox Check(string text, bool on, Action<bool> changed)
    {
        var c = new CheckBox { Text = text, Checked = on, AutoSize = true, Font = Body, ForeColor = Text, BackColor = Color.Transparent, Margin = new Padding(0, 4, 0, 4) };
        c.CheckedChanged += (_, _) => changed(c.Checked);
        return c;
    }

    public static TextBox Input(string placeholder = "", bool multiline = false)
    {
        var t = new TextBox { PlaceholderText = placeholder, Font = Body, BackColor = InputBg, ForeColor = Text, BorderStyle = BorderStyle.FixedSingle, Multiline = multiline };
        return t;
    }

    public static ComboBox Combo(IEnumerable<string> items, int selected, Action<int> changed)
    {
        var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Font = Body, BackColor = InputBg, ForeColor = Text, FlatStyle = FlatStyle.Flat, Width = 120 };
        foreach (var i in items) c.Items.Add(i);
        if (selected >= 0 && selected < c.Items.Count) c.SelectedIndex = selected;
        c.SelectedIndexChanged += (_, _) => changed(c.SelectedIndex);
        return c;
    }

    public static FlowLayoutPanel Row(params Control[] items)
    {
        var p = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = true, BackColor = Color.Transparent, Margin = new Padding(0, 4, 0, 4) };
        p.Controls.AddRange(items);
        return p;
    }

    public static GraphicsPath Round(RectangleF r, float rad)
    {
        var p = new GraphicsPath();
        float d = rad * 2;
        if (d <= 0) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    public static Image FromBase64(string b64)
    {
        if (string.IsNullOrEmpty(b64)) return null;
        try { return Image.FromStream(new MemoryStream(Convert.FromBase64String(b64))); } catch { return null; }
    }

    public static string Ago(DateTime t)
    {
        var d = DateTime.Now - t;
        if (d.TotalMinutes < 1) return tr("now");
        if (d.TotalHours < 1) return tr("{0} min", (int)d.TotalMinutes);
        if (t.Date == DateTime.Today) return t.ToString("t");
        if (t.Date == DateTime.Today.AddDays(-1)) return tr("Yesterday");
        if (d.TotalDays < 7) return t.ToString("ddd");
        return t.ToString("d");
    }

    public static DateTime FromMs(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).LocalDateTime;

    public static string Size(long b) => b < 1024 ? $"{b} B" : b < 1 << 20 ? $"{b / 1024.0:0} KB" : b < 1L << 30 ? $"{b / 1048576.0:0.0} MB" : $"{b / 1073741824.0:0.00} GB";

    public static void Shell(string target)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(target) { UseShellExecute = true }); } catch { }
    }

    public static void Reveal(string path)
    {
        try { System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\""); } catch { }
    }
}

/// A flat button in the window's colours (WinForms' own buttons ignore dark mode).
sealed class FlatButton : Button
{
    readonly bool primary;
    public FlatButton(string text, bool primary)
    {
        this.primary = primary;
        Text = text;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        FlatStyle = FlatStyle.Flat;
        Font = Ui.Body;
        Padding = new Padding(8, 2, 8, 2);
        Margin = new Padding(0, 4, 8, 4);
        UseVisualStyleBackColor = false;
        Cursor = Cursors.Hand;
        FlatAppearance.BorderSize = primary ? 0 : 1;
        FlatAppearance.BorderColor = Ui.Line;
        ApplyColors();
        EnabledChanged += (_, _) => ApplyColors();
    }

    void ApplyColors()
    {
        BackColor = primary ? (Enabled ? Ui.Accent : Ui.Line) : Ui.Card;
        ForeColor = primary ? Ui.AccentText : (Enabled ? Ui.Text : Ui.Sub);
        FlatAppearance.MouseOverBackColor = primary ? ControlPaint.Light(Ui.Accent, 0.15f) : Ui.Hover;
        FlatAppearance.MouseDownBackColor = primary ? ControlPaint.Dark(Ui.Accent, 0.05f) : Ui.Selected;
    }
}

/// A white (dark: grey) block with an optional title, the building block of Overview and Settings.
sealed class CardPanel : FlowLayoutPanel
{
    public CardPanel(string title = null, string glyph = null)
    {
        FlowDirection = FlowDirection.TopDown;
        WrapContents = false;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        BackColor = Ui.Card;
        Padding = new Padding(16, 12, 16, 12);
        Margin = new Padding(0, 0, 12, 12);
        if (title != null)
        {
            var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Margin = new Padding(0, 0, 0, 6) };
            if (glyph != null) row.Controls.Add(new Label { Text = glyph, Font = Ui.IconFont(12), AutoSize = true, ForeColor = Ui.Accent, Margin = new Padding(0, 3, 6, 0) });
            row.Controls.Add(Ui.Label(title, Ui.H2));
            Controls.Add(row);
        }
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(Parent?.BackColor ?? Ui.Bg);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var b = new SolidBrush(BackColor);
        using var p = Ui.Round(new RectangleF(0, 0, Width - 1, Height - 1), LogicalToDeviceUnits(8));
        e.Graphics.FillPath(b, p);
        using var pen = new Pen(Ui.Line);
        e.Graphics.DrawPath(pen, p);
    }
}

/// Centred icon + title + text (+ button) for empty, not-connected and permission states.
sealed class Placeholder : TableLayoutPanel
{
    public Placeholder(string glyph, string title, string text, string action = null, Action onAction = null)
    {
        Dock = DockStyle.Fill;
        BackColor = Ui.Bg;
        ColumnCount = 1; RowCount = 3;
        RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        RowStyles.Add(new RowStyle(SizeType.AutoSize));
        RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        var inner = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Anchor = AnchorStyles.None, BackColor = Color.Transparent };
        var g = new Label { Text = glyph, Font = Ui.IconFont(32), AutoSize = true, ForeColor = Ui.Sub, Anchor = AnchorStyles.None, Margin = new Padding(0, 0, 0, 10) };
        inner.Controls.Add(g);
        var t = Ui.Label(title, Ui.H2); t.Anchor = AnchorStyles.None; inner.Controls.Add(t);
        if (!string.IsNullOrEmpty(text)) { var s = Ui.Label(text, Ui.Body, Ui.Sub, 420); s.TextAlign = ContentAlignment.MiddleCenter; s.Anchor = AnchorStyles.None; inner.Controls.Add(s); }
        if (action != null) { var b = Ui.Button(action, onAction, primary: true); b.Anchor = AnchorStyles.None; b.Margin = new Padding(0, 12, 0, 0); inner.Controls.Add(b); }
        Controls.Add(inner, 0, 1);
    }
}

/// Segoe MDL2 / Fluent icon glyphs used across the window.
static class Glyph
{
    public const string Home = "", Mirror = "", Bell = "", Message = "", Phone = "", Contact = "",
        Photo = "", Folder = "", Apps = "", Transfer = "", Settings = "", Battery = "",
        Pc = "", Network = "", Music = "", Play = "", Pause = "", Next = "", Prev = "",
        Ring = "", Moon = "", Doc = "", Video = "", Up = "", Download = "", Delete = "",
        Refresh = "", Send = "", Add = "", Search = "", Cancel = "", Check = "", Warning = "",
        Lock = "", Disconnected = "", Record = "", Gamepad = "", Keyboard = "";
}
