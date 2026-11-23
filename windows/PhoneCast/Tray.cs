using System.Drawing;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace PhoneCast;

/// The tray icon (UI thread): lit phone = linked. Menu: open the window, mirror, now playing, recent
/// notifications, clipboard/files to the phone, ring, the phone's Do Not Disturb, mute banners, quit.
static class Tray
{
    static NotifyIcon icon;
    static Icon on, off;

    static Icon Load(string file)
    {
        var p = Path.Combine(AppContext.BaseDirectory, file);
        try { return File.Exists(p) ? new Icon(p) : SystemIcons.Application; } catch { return SystemIcons.Application; }
    }

    public static void Start()
    {
        on = Load("phonecast_on.ico"); off = Load("phonecast_off.ico");
        icon = new NotifyIcon { Icon = off, Text = "PhoneCast", Visible = true, ContextMenuStrip = new ContextMenuStrip() };
        icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) MainForm.Open(); };
        icon.ContextMenuStrip.Opening += (_, _) => Build(icon.ContextMenuStrip);
        Update();
    }

    public static void SetFormIcon(Form f) => f.Icon = Store.Shared.Connected ? on ?? Load("phonecast_on.ico") : off ?? Load("phonecast_off.ico");

    public static void Update()
    {
        if (icon == null) return;
        var s = Store.Shared;
        icon.Icon = s.Connected ? on : off;
        var t = s.Connected ? tr("PhoneCast — linked with {0}", s.PhoneName) : tr("PhoneCast — phone not linked");
        if (s.Media != null) t += $"\n♪ {(string)s.Media["title"]}";
        icon.Text = t.Length > 127 ? t[..127] : t;
        if (MainForm.Instance != null) SetFormIcon(MainForm.Instance);
    }

    static void Build(ContextMenuStrip m)
    {
        var s = Store.Shared;
        m.Items.Clear();
        m.Items.Add(new ToolStripMenuItem(s.Connected ? tr("Linked with {0}", s.PhoneName) + (s.PhoneSummary != "" ? " · " + s.PhoneSummary : "") : tr("Phone not linked")) { Enabled = false });
        m.Items.Add(tr("Open PhoneCast"), null, (_, _) => MainForm.Open());
        m.Items.Add(tr("Mirror"), null, (_, _) => s.Link.Mirror()).Enabled = s.Connected || s.Link.MirrorConnected;
        m.Items.Add(new ToolStripSeparator());
        if (s.Media is JsonObject media)
        {
            bool playing = (bool?)media["playing"] ?? false;
            m.Items.Add(new ToolStripMenuItem($"♪ {(string)media["title"]} — {(string)media["artist"]}") { Enabled = false });
            m.Items.Add(playing ? tr("Pause") : tr("Play"), null, (_, _) => s.MediaCmd("toggle"));
            m.Items.Add(tr("Next"), null, (_, _) => s.MediaCmd("next"));
            m.Items.Add(tr("Previous"), null, (_, _) => s.MediaCmd("prev"));
            m.Items.Add(new ToolStripSeparator());
        }
        var nm = new ToolStripMenuItem(tr("Notifications ({0})", s.Notifs.Count)) { Enabled = s.Notifs.Count > 0 };
        foreach (var n in s.Notifs.Take(15))
        {
            var label = $"{n.App}: {n.Title}";
            nm.DropDownItems.Add(label.Length > 60 ? label[..60] + "…" : label, null, (_, _) => MainForm.Open("notifications"));
        }
        m.Items.Add(nm);
        m.Items.Add(tr("Send clipboard to the phone"), null, (_, _) => ClipboardSync.SendNow()).Enabled = s.Connected;
        m.Items.Add(tr("Send files to the phone…"), null, (_, _) =>
        {
            using var d = new OpenFileDialog { Multiselect = true, Title = tr("Send files to the phone") };
            if (d.ShowDialog() == DialogResult.OK) s.Link.SendFiles(d.FileNames);
        }).Enabled = s.Connected;
        m.Items.Add(s.Ringing ? tr("Stop ringing the phone") : tr("Ring the phone"), null, (_, _) => s.Ring(!s.Ringing)).Enabled = s.Connected;
        var dnd = new ToolStripMenuItem(tr("Do Not Disturb on the phone")) { Checked = s.PhoneDnd, Enabled = s.Connected };
        dnd.Click += (_, _) => s.SetPhoneDnd(!s.PhoneDnd);
        m.Items.Add(dnd);
        var mute = new ToolStripMenuItem(tr("Mute banners")) { Checked = s.MuteAll };
        mute.Click += (_, _) => s.MuteAll = !s.MuteAll;
        m.Items.Add(mute);
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add(tr("Quit PhoneCast"), null, (_, _) => s.Link.Quit());
    }

    public static void Stop()
    {
        if (icon == null) return;
        icon.Visible = false;
        icon.Dispose();
        icon = null;
    }
}
