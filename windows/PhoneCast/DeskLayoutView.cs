using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace PhoneCast;

/// Settings → Shared keyboard & mouse: this PC's monitors and the linked Mac on one canvas. Drag the Mac against any
/// monitor edge; it snaps there (Desk.Snap) and the pointer crosses exactly where they touch, both ways. The Mac keeps
/// the arrangement, so changing it here or in the Mac's Settings is the same thing.
sealed class DeskLayoutView : Control
{
    Point? dragFrom;
    Size drag;

    public DeskLayoutView()
    {
        SetStyle(ControlStyles.ResizeRedraw | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        BackColor = Ui.Card;
        Cursor = Cursors.Default;
    }

    // plane (PC pixels) <-> view
    (RectangleF bounds, float scale, float ox, float oy) Map()
    {
        var pcs = Desk.PcScreens();
        var mac = Desk.Shared.MacRects;
        var all = pcs.Concat(mac).ToList();
        var u = all.Aggregate(all[0], Rectangle.Union);
        var macU = mac.Count > 0 ? mac.Aggregate(mac[0], Rectangle.Union) : new Rectangle(0, 0, 1600, 1000);
        var b = RectangleF.Inflate(u, macU.Width * 0.45f, macU.Height * 0.45f);
        float sc = Math.Min(Width / b.Width, Height / b.Height);
        return (b, sc, (Width - b.Width * sc) / 2, (Height - b.Height * sc) / 2);
    }

    RectangleF View(Rectangle r, (RectangleF b, float sc, float ox, float oy) m) =>
        new(m.ox + (r.X - m.b.X) * m.sc, m.oy + (r.Y - m.b.Y) * m.sc, r.Width * m.sc, r.Height * m.sc);

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(BackColor);
        var m = Map();
        var pcs = Desk.PcScreens();
        using var font = new Font(Ui.Small.FontFamily, Ui.Small.Size);
        using var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        for (int i = 0; i < pcs.Count; i++)
        {
            var v = View(pcs[i], m);
            using var fill = new SolidBrush(Color.FromArgb(70, 128, 128, 128));
            using var pen = new Pen(Color.Gray);
            g.FillRectangle(fill, v); g.DrawRectangle(pen, v.X, v.Y, v.Width, v.Height);
            using var tb = new SolidBrush(Ui.Text);
            g.DrawString($"PC {i + 1}\n{pcs[i].Width}×{pcs[i].Height}", font, tb, v, center);
        }
        var mac = Desk.Shared.MacRects;
        if (mac.Count == 0)
        {
            using var tb = new SolidBrush(Ui.Sub);
            g.DrawString(tr("The Mac shows up here once it's connected."), font, tb, new RectangleF(0, Height - 24, Width, 20), center);
            return;
        }
        foreach (var r in mac)
        {
            var v = View(r, m); v.Offset(drag.Width, drag.Height);
            using var fill = new SolidBrush(Color.FromArgb(150, Ui.Accent));
            using var pen = new Pen(Ui.Accent, 2);
            g.FillRectangle(fill, v); g.DrawRectangle(pen, v.X, v.Y, v.Width, v.Height);
            using var bold = new Font(font, FontStyle.Bold);
            g.DrawString("Mac", bold, Brushes.White, v, center);
        }
    }

    bool OnMac(Point p)
    {
        var m = Map();
        return Desk.Shared.MacRects.Any(r => View(r, m).Contains(p));
    }

    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left && OnMac(e.Location)) dragFrom = e.Location; }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        Cursor = dragFrom != null ? Cursors.SizeAll : OnMac(e.Location) ? Cursors.Hand : Cursors.Default;
        if (dragFrom is { } f) { drag = new Size(e.X - f.X, e.Y - f.Y); Invalidate(); }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (dragFrom == null) return;
        var m = Map();
        var mac = Desk.Shared.MacRects;
        var u = mac.Aggregate(mac[0], Rectangle.Union);
        int dx = (int)Math.Round(drag.Width / m.scale), dy = (int)Math.Round(drag.Height / m.scale);
        dragFrom = null; drag = Size.Empty;
        var o = Desk.Snap(new Rectangle(u.X + dx, u.Y + dy, u.Width, u.Height));
        // show it at once; the Mac stores it and sends the layout back
        Desk.Shared.MacRects = mac.Select(r => new Rectangle(r.X + o.X - u.X, r.Y + o.Y - u.Y, r.Width, r.Height)).ToList();
        if (Desk.Shared.Connected) Desk.Shared.SetMacOrigin(o);
        Invalidate();
    }
}
