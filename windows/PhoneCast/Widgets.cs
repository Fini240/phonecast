using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace PhoneCast;

sealed class Row
{
    public string Key;
    public Image Icon;
    public string Glyph;
    public Color? GlyphColor;
    public string Title, Sub, Right;
    public Color? RightColor;
    public int Badge;
    public bool Bold;
    public double? Progress;
    public object Tag;
}

/// An owner-drawn list of rows (icon, title, two lines of text, a note on the right), themed light/dark.
sealed class RowList : ListBox
{
    public event Action<Row> Activated;
    public event Action<Row, Point> Menu;
    public event Action<Row> Picked;
    int hover = -1;
    public bool Compact;

    public RowList()
    {
        DrawMode = DrawMode.OwnerDrawVariable;
        BorderStyle = BorderStyle.None;
        BackColor = Ui.Card;
        ForeColor = Ui.Text;
        IntegralHeight = false;
        Font = Ui.Body;
        Dock = DockStyle.Fill;
        HandleCreated += (_, _) => Win.DarkScroll(this);
    }

    public Row Current => SelectedItem as Row;

    /// Replaces the rows, keeping the selection and scroll position when the same keys are still there.
    public void SetRows(IEnumerable<Row> rows)
    {
        var key = Current?.Key;
        int top = TopIndex;
        BeginUpdate();
        Items.Clear();
        foreach (var r in rows) Items.Add(r);
        if (key != null) for (int i = 0; i < Items.Count; i++) if (((Row)Items[i]).Key == key) { SelectedIndex = i; break; }
        if (top < Items.Count) TopIndex = top;
        EndUpdate();
    }

    protected override void OnMeasureItem(MeasureItemEventArgs e)
    {
        var r = e.Index >= 0 && e.Index < Items.Count ? Items[e.Index] as Row : null;
        e.ItemHeight = LogicalToDeviceUnits(Compact || string.IsNullOrEmpty(r?.Sub) ? 44 : (r.Progress != null ? 64 : 60));
    }

    protected override void OnDrawItem(DrawItemEventArgs e)
    {
        if (e.Index < 0 || e.Index >= Items.Count) return;
        var r = (Row)Items[e.Index];
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        bool sel = (e.State & DrawItemState.Selected) != 0;
        using (var bg = new SolidBrush(sel ? Ui.Selected : e.Index == hover ? Ui.Hover : BackColor)) g.FillRectangle(bg, e.Bounds);
        int pad = LogicalToDeviceUnits(12), ic = LogicalToDeviceUnits(Compact ? 24 : 34);
        var b = e.Bounds;
        int x = b.X + pad;
        var iconRect = new Rectangle(x, b.Y + (b.Height - ic) / 2, ic, ic);
        if (r.Icon != null)
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            var img = r.Icon;
            float k = Math.Min((float)ic / img.Width, (float)ic / img.Height);
            var dst = new RectangleF(iconRect.X + (ic - img.Width * k) / 2, iconRect.Y + (ic - img.Height * k) / 2, img.Width * k, img.Height * k);
            g.DrawImage(img, dst);
        }
        else if (r.Glyph != null)
        {
            using var circle = new SolidBrush(Color.FromArgb(Ui.Dark ? 60 : 30, r.GlyphColor ?? Ui.Accent));
            g.FillEllipse(circle, iconRect);
            using var f = Ui.IconFont(Compact ? 10 : 12);
            TextRenderer.DrawText(g, r.Glyph, f, iconRect, r.GlyphColor ?? Ui.Accent, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
        x += ic + pad;
        int right = b.Right - pad;
        if (r.Badge > 0)
        {
            var s = r.Badge > 99 ? "99+" : r.Badge.ToString();
            var sz = TextRenderer.MeasureText(s, Ui.Small);
            int bw = Math.Max(sz.Width + LogicalToDeviceUnits(6), LogicalToDeviceUnits(20)), bh = LogicalToDeviceUnits(18);
            var br = new Rectangle(right - bw, b.Y + (b.Height - bh) / 2, bw, bh);
            using var p = Ui.Round(br, bh / 2f);
            using var fill = new SolidBrush(Ui.Accent);
            g.FillPath(fill, p);
            TextRenderer.DrawText(g, s, Ui.Small, br, Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            right -= bw + LogicalToDeviceUnits(8);
        }
        bool hasSub = !string.IsNullOrEmpty(r.Sub) && !Compact;
        int lineH = Ui.Body.Height;
        int top = hasSub ? b.Y + LogicalToDeviceUnits(9) : b.Y + (b.Height - lineH) / 2;
        if (!string.IsNullOrEmpty(r.Right))
        {
            var rs = TextRenderer.MeasureText(r.Right, Ui.Small);
            TextRenderer.DrawText(g, r.Right, Ui.Small, new Point(right - rs.Width, top + 1), r.RightColor ?? Ui.Sub);
            right -= rs.Width + LogicalToDeviceUnits(8);
        }
        var font = r.Bold ? Ui.Bold : Ui.Body;
        TextRenderer.DrawText(g, r.Title ?? "", font, new Rectangle(x, top, Math.Max(10, right - x), lineH + 2), Ui.Text, TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        if (hasSub)
        {
            int subTop = top + lineH + LogicalToDeviceUnits(2);
            int w = b.Right - pad - x;
            var sub = r.Sub.Replace('\n', ' ');
            TextRenderer.DrawText(g, sub, Ui.Small, new Rectangle(x, subTop, Math.Max(10, w), Ui.Small.Height + 2), Ui.Sub, TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            if (r.Progress is double pr)
            {
                int py = subTop + Ui.Small.Height + LogicalToDeviceUnits(6), ph = LogicalToDeviceUnits(4);
                using var track = new SolidBrush(Ui.Line);
                g.FillRectangle(track, x, py, w, ph);
                using var bar = new SolidBrush(Ui.Accent);
                g.FillRectangle(bar, x, py, (int)(w * Math.Clamp(pr, 0, 1)), ph);
            }
        }
        using var line = new Pen(Ui.Line);
        g.DrawLine(line, x, b.Bottom - 1, b.Right, b.Bottom - 1);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        int i = IndexFromPoint(e.Location);
        if (i == hover) return;
        int old = hover; hover = i;
        if (old >= 0 && old < Items.Count) Invalidate(GetItemRectangle(old));
        if (i >= 0 && i < Items.Count) Invalidate(GetItemRectangle(i));
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (hover >= 0 && hover < Items.Count) Invalidate(GetItemRectangle(hover));
        hover = -1;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        int i = IndexFromPoint(e.Location);
        if (e.Button == MouseButtons.Right && i >= 0 && i < Items.Count)
        {
            SelectedIndex = i;
            Menu?.Invoke((Row)Items[i], e.Location);
        }
    }

    protected override void OnSelectedIndexChanged(EventArgs e)
    {
        base.OnSelectedIndexChanged(e);
        if (Current != null) Picked?.Invoke(Current);
    }

    protected override void OnDoubleClick(EventArgs e) { base.OnDoubleClick(e); if (Current != null) Activated?.Invoke(Current); }
    protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); if (e.KeyCode == Keys.Enter && Current != null) Activated?.Invoke(Current); }
    protected override void OnResize(EventArgs e) { base.OnResize(e); Invalidate(); }
}

/// The chat view of one conversation: bubbles (mine on the right), MMS pictures inline.
/// A scrolling panel that lays out and paints its own bubbles (a ListBox caps rows at 255 px).
sealed class BubbleList : ScrollableControl
{
    List<JsonObject> msgs = new();
    readonly Dictionary<long, Image> thumbs = new();
    readonly List<(Rectangle bubble, Rectangle pic, int dateY)> layout = new();
    int total;
    public event Action<JsonObject> PictureClick;

    public BubbleList()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        AutoScroll = true;
        BackColor = Ui.Card;
        Dock = DockStyle.Fill;
        HandleCreated += (_, _) => Win.DarkScroll(this);
    }

    public void SetMessages(List<JsonObject> m)
    {
        msgs = m ?? new();
        Relayout();
        ScrollToEnd();
    }

    void ScrollToEnd()
    {
        if (total > ClientSize.Height) AutoScrollPosition = new Point(0, total);
        Invalidate();
    }

    int lastWidth;
    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (Math.Abs(ClientSize.Width - lastWidth) > 4) { lastWidth = ClientSize.Width; Relayout(); ScrollToEnd(); }
    }

    int MaxBubble => Math.Max(LogicalToDeviceUnits(160), (int)(ClientSize.Width * 0.68));
    const TextFormatFlags Flags = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix;

    Image Thumb(JsonObject o)
    {
        long id = (long?)o["id"] ?? 0;
        if (thumbs.TryGetValue(id, out var img)) return img;
        img = Ui.FromBase64((string)o["thumb"]);
        thumbs[id] = img;
        return img;
    }

    Size PicSize(Image img)
    {
        int maxW = Math.Min(LogicalToDeviceUnits(220), MaxBubble);
        float k = Math.Min(1f, (float)maxW / img.Width);
        return new Size((int)(img.Width * k), (int)(img.Height * k));
    }

    bool ShowDate(int i)
    {
        if (i == 0) return true;
        var a = Ui.FromMs((long?)msgs[i - 1]["date"] ?? 0);
        var b = Ui.FromMs((long?)msgs[i]["date"] ?? 0);
        return (b - a).TotalMinutes > 60;
    }

    void Relayout()
    {
        layout.Clear();
        int w = ClientSize.Width, pad = LogicalToDeviceUnits(14), y = LogicalToDeviceUnits(8);
        using var g = CreateGraphics();
        for (int i = 0; i < msgs.Count; i++)
        {
            var o = msgs[i];
            bool mine = (bool?)o["mine"] ?? false;
            int dateY = -1;
            if (ShowDate(i)) { dateY = y; y += LogicalToDeviceUnits(24); }
            var pic = Rectangle.Empty;
            if (Thumb(o) is Image img)
            {
                var ps = PicSize(img);
                pic = new Rectangle(mine ? w - pad - ps.Width : pad, y, ps.Width, ps.Height);
                y += ps.Height + LogicalToDeviceUnits(4);
            }
            else if (o["image"] != null)
            {
                pic = new Rectangle(mine ? w - pad - LogicalToDeviceUnits(120) : pad, y, LogicalToDeviceUnits(120), LogicalToDeviceUnits(28));
                y += pic.Height + LogicalToDeviceUnits(4);
            }
            var bubble = Rectangle.Empty;
            var text = (string)o["text"] ?? "";
            if (text != "")
            {
                var sz = TextRenderer.MeasureText(g, text, Ui.Body, new Size(MaxBubble - LogicalToDeviceUnits(24), 100000), Flags);
                int bw = sz.Width + LogicalToDeviceUnits(24), bh = sz.Height + LogicalToDeviceUnits(14);
                bubble = new Rectangle(mine ? w - pad - bw : pad, y, bw, bh);
                y += bh;
            }
            y += LogicalToDeviceUnits(6);
            layout.Add((bubble, pic, dateY));
        }
        total = y + LogicalToDeviceUnits(8);
        AutoScrollMinSize = new Size(0, total);
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int dy = AutoScrollPosition.Y;
        g.TranslateTransform(0, dy);
        int top = -dy, bottom = top + ClientSize.Height;
        for (int i = 0; i < msgs.Count && i < layout.Count; i++)
        {
            var (bubble, pic, dateY) = layout[i];
            int itemTop = dateY >= 0 ? dateY : !pic.IsEmpty ? pic.Y : bubble.Y;
            int itemBottom = Math.Max(bubble.Bottom, pic.Bottom);
            if (itemBottom < top || itemTop > bottom) continue;
            var o = msgs[i];
            bool mine = (bool?)o["mine"] ?? false;
            if (dateY >= 0)
            {
                var d = Ui.FromMs((long?)o["date"] ?? 0);
                var s = d.Date == DateTime.Today ? d.ToString("t") : d.ToString("g");
                TextRenderer.DrawText(g, s, Ui.Small, new Rectangle(0, dateY, ClientSize.Width, LogicalToDeviceUnits(20)), Ui.Sub, TextFormatFlags.HorizontalCenter);
            }
            if (!pic.IsEmpty)
            {
                if (Thumb(o) is Image img)
                {
                    using var clip = Ui.Round(pic, LogicalToDeviceUnits(10));
                    var state = g.Save();
                    g.SetClip(clip);
                    g.DrawImage(img, pic);
                    g.Restore(state);
                }
                else TextRenderer.DrawText(g, "📷 " + tr("Picture"), Ui.Body, pic, Ui.Sub, TextFormatFlags.VerticalCenter);
            }
            if (!bubble.IsEmpty)
            {
                var color = mine ? Ui.Mine : Ui.Theirs;
                if ((bool?)o["sending"] == true) color = Color.FromArgb(160, color);
                using var path = Ui.Round(bubble, LogicalToDeviceUnits(12));
                using var fill = new SolidBrush(color);
                g.FillPath(fill, path);
                var inner = Rectangle.Inflate(bubble, -LogicalToDeviceUnits(12), -LogicalToDeviceUnits(7));
                TextRenderer.DrawText(g, (string)o["text"], Ui.Body, inner, mine ? Color.White : Ui.Text, Flags);
            }
        }
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        var p = new Point(e.X, e.Y - AutoScrollPosition.Y);
        for (int i = 0; i < layout.Count; i++)
            if (!layout[i].pic.IsEmpty && layout[i].pic.Contains(p) && msgs[i]["image"] != null) { PictureClick?.Invoke(msgs[i]); return; }
    }

    protected override void OnMouseWheel(MouseEventArgs e) { base.OnMouseWheel(e); Invalidate(); }
    protected override void OnScroll(ScrollEventArgs se) { base.OnScroll(se); Invalidate(); }
}

/// Small Win32 helpers for the window.
static class Win
{
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string id);

    /// Dark scrollbars on lists in dark mode (Windows 10 1809+).
    public static void DarkScroll(Control c)
    {
        if (!Ui.Dark) return;
        try { SetWindowTheme(c.Handle, "DarkMode_Explorer", null); } catch { }
    }
}
