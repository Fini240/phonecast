using System.Drawing;
using System.Text.Json.Nodes;
using System.Windows.Forms;

namespace PhoneCast;

/// Key/value rows inside a card (Battery 80 %, Heat cool, …).
sealed class KvTable : TableLayoutPanel
{
    readonly Dictionary<string, (Label k, Label v)> rows = new();
    public KvTable()
    {
        ColumnCount = 2; AutoSize = true; BackColor = Color.Transparent; Margin = new Padding(0, 2, 0, 6);
        ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
    }
    public void Set(string key, string value, Color? color = null)
    {
        if (!rows.TryGetValue(key, out var r))
        {
            r = (Ui.Label(tr(key), Ui.Body, Ui.Sub), Ui.Label("", Ui.Body));
            r.k.Margin = new Padding(0, 2, 18, 2);
            rows[key] = r;
            Controls.Add(r.k, 0, RowCount); Controls.Add(r.v, 1, RowCount); RowCount++;
        }
        r.v.Text = value ?? "—";
        r.v.ForeColor = color ?? Ui.Text;
        r.k.Visible = r.v.Visible = value != null;
    }
}

// =====================================================================

sealed class OverviewSection : Section
{
    readonly FlowLayoutPanel flow = new() { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Ui.Bg };
    readonly KvTable phone = new(), pc = new();
    readonly CardPanel phoneCard, mediaCard, pcCard, devicesCard;
    readonly Label phoneTitle = Ui.Label("", Ui.H2);
    readonly FlatButton ringBtn, mirrorBtn;
    readonly CheckBox dnd;
    readonly PictureBox art = new() { SizeMode = PictureBoxSizeMode.Zoom, Width = 72, Height = 72, Margin = new Padding(0, 0, 12, 0) };
    readonly Label mediaTitle = Ui.Label("", Ui.Bold, null, 260), mediaSub = Ui.Label("", Ui.Small, Ui.Sub, 260);
    readonly FlatButton playBtn;
    readonly RowList devices = new() { Compact = true, Dock = DockStyle.None };
    bool updatingDnd;

    public OverviewSection()
    {
        Controls.Add(flow);
        Controls.Add(Header(tr("Overview")));

        phoneCard = new CardPanel(null);
        phoneCard.Controls.Add(Ui.Row(new Label { Text = Glyph.Phone, Font = Ui.IconFont(12), AutoSize = true, ForeColor = Ui.Accent, Margin = new Padding(0, 3, 6, 0) }, phoneTitle));
        phoneCard.Controls.Add(phone);
        mirrorBtn = Ui.Button(tr("Mirror"), () => S.Link.Mirror(), primary: true);
        ringBtn = Ui.Button(tr("Find phone"), () => S.Ring(!S.Ringing));
        phoneCard.Controls.Add(Ui.Row(mirrorBtn, ringBtn));
        dnd = Ui.Check(tr("Do Not Disturb on the phone"), false, on => { if (!updatingDnd) S.SetPhoneDnd(on); });
        phoneCard.Controls.Add(dnd);
        phoneCard.MinimumSize = new Size(LogicalToDeviceUnits(300), 0);

        mediaCard = new CardPanel(tr("Now playing"), Glyph.Music);
        var mediaText = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, BackColor = Color.Transparent };
        mediaText.Controls.Add(mediaTitle); mediaText.Controls.Add(mediaSub);
        playBtn = Ui.Button(Glyph.Play, () => S.MediaCmd("toggle"));
        var prev = Ui.Button(Glyph.Prev, () => S.MediaCmd("prev"));
        var next = Ui.Button(Glyph.Next, () => S.MediaCmd("next"));
        foreach (var b in new[] { prev, playBtn, next }) b.Font = Ui.IconFont(10);
        mediaText.Controls.Add(Ui.Row(prev, playBtn, next));
        mediaCard.Controls.Add(Ui.Row(art, mediaText));

        pcCard = new CardPanel(Environment.MachineName, Glyph.Pc);
        pcCard.Controls.Add(pc);
        pcCard.MinimumSize = new Size(LogicalToDeviceUnits(260), 0);

        devicesCard = new CardPanel(tr("Devices"), Glyph.Network);
        devices.Width = LogicalToDeviceUnits(320);
        devicesCard.Controls.Add(devices);
        devicesCard.Controls.Add(Ui.Label(tr("Time to open a connection, every 5 s. Edit the list in Settings."), Ui.Small, Ui.Sub, LogicalToDeviceUnits(320)));

        flow.Controls.AddRange(new Control[] { phoneCard, mediaCard, pcCard, devicesCard });
        Refresh2();
    }

    public override void Shown() => Refresh2();
    public override void Changed(string what) { if (what is "status" or "media" or "pc" or "devices" or "settings") Refresh2(); }

    static readonly string[] Thermal = { "cool", "light", "moderate", "severe", "critical", "emergency", "shutdown" };

    void Refresh2()
    {
        var st = S.Status;
        phoneTitle.Text = S.Connected ? S.PhoneName : tr("Phone not connected");
        if (S.Connected)
        {
            phone.Set("Battery", (int?)st["battery"] is int b ? $"{b} %" + (((bool?)st["charging"] ?? false) ? tr(" · charging") : "") : null,
                (int?)st["battery"] is int b2 && b2 <= 15 ? Ui.Red : null);
            phone.Set("Battery temperature", st["batteryTemp"] is JsonNode t ? $"{(double)t:0.0} °C" : null, st["batteryTemp"] is JsonNode t2 && (double)t2 >= 42 ? Ui.Orange : null);
            int th = (int?)st["thermal"] ?? -1;
            phone.Set("Heat", th >= 0 ? tr(Thermal[Math.Clamp(th, 0, 6)]) : null, th >= 3 ? Ui.Red : th >= 2 ? Ui.Orange : null);
            var net = (string)st["net"];
            phone.Set("Network", net == null ? null : net + ((int?)st["rssi"] is int rs ? $" ({rs} dBm)" : ""));
            phone.Set("Free storage", st["freeGB"] is JsonNode f ? $"{(double)f:0.0} GB" : null);
            phone.Set("Link", S.Rtt >= 0 ? $"{S.Rtt:0} ms" : tr("connected"));
        }
        else
        {
            foreach (var k in new[] { "Battery", "Battery temperature", "Heat", "Network", "Free storage" }) phone.Set(k, null);
            phone.Set("Link", S.LinkState);
        }
        mirrorBtn.Enabled = ringBtn.Enabled = dnd.Enabled = S.Connected;
        mirrorBtn.Text = S.Link?.MirrorConnected == true ? tr("Show mirror") : tr("Mirror");
        ringBtn.Text = S.Ringing ? tr("Stop ringing") : tr("Find phone");
        updatingDnd = true; dnd.Checked = S.PhoneDnd; updatingDnd = false;

        mediaCard.Visible = S.Media != null;
        if (S.Media is JsonObject m)
        {
            mediaTitle.Text = (string)m["title"];
            mediaSub.Text = string.Join(" · ", new[] { (string)m["artist"], (string)m["app"] }.Where(x => !string.IsNullOrEmpty(x)));
            art.Image = S.Art; art.Visible = S.Art != null;
            playBtn.Text = ((bool?)m["playing"] ?? false) ? Glyph.Pause : Glyph.Play;
        }

        if (S.Pc is PcStats.Sample p)
        {
            pc.Set("Battery", p.Battery is int pb ? $"{pb} %" + (p.Charging ? tr(" · on power") : "") : tr("none (on power)"));
            pc.Set("CPU", p.Cpu is int c ? $"{c} %" : null, p.Cpu >= 90 ? Ui.Orange : null);
            pc.Set("Memory", p.Mem is int mm ? $"{mm} %" : null, p.Mem >= 90 ? Ui.Orange : null);
            pc.Set("Uptime", p.Uptime);
        }

        devicesCard.Visible = S.Devices.Count > 0;
        devices.SetRows(S.Devices.Select(d => new Row
        {
            Key = d.name, Title = d.name, Glyph = Glyph.Network, GlyphColor = d.ms != null ? Ui.Green : Ui.Sub,
            Right = d.ms is double ms ? $"{ms:0} ms" : tr("offline"), RightColor = d.ms != null ? Ui.Green : Ui.Sub,
        }));
        devices.Height = Math.Max(1, S.Devices.Count) * LogicalToDeviceUnits(44);
    }
}

// =====================================================================

sealed class MirrorSection : Section
{
    readonly Panel host = new() { Dock = DockStyle.Fill };
    public MirrorSection() { Controls.Add(host); }
    public override void Shown() => Build();
    public override void Changed(string what) { if (what is "status" or "recording" or "pc") Build(); }

    void Build()
    {
        host.Controls.Clear();
        if (!S.Connected) { host.Controls.Add(StateFor("mirror", "Mirror", "") ?? new Panel()); return; }
        bool up = S.Link.MirrorConnected;
        var title = up ? tr("The mirror is open") : S.PhoneCasting ? tr("The phone is sharing its screen") : tr("Mirror the phone");
        var text = up
            ? tr("Click or drag to touch, the wheel scrolls, right-click is Back. Ctrl+E edits the key map, Ctrl+G is mouse aiming, Ctrl+Shift+R records.")
            : tr("Shows the phone's screen in its own window, with sound. Control it with the mouse, keyboard or a game controller. The phone asks once to share its screen.");
        if (S.GamepadName != null) text += "\n\n" + tr("Controller: {0}", S.GamepadName);
        var ph = new Placeholder(Glyph.Mirror, title, text, up ? tr("Show mirror") : tr("Mirror"), () => S.Link.Mirror());
        host.Controls.Add(ph);
        if (up)
        {
            var rec = Ui.Button(S.Link.Recording ? tr("Stop recording") : tr("Record the mirror"), () => S.Link.ToggleRecording());
            rec.Dock = DockStyle.Bottom;
            var bar = new FlowLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, BackColor = Color.Transparent, FlowDirection = FlowDirection.RightToLeft };
            bar.Controls.Add(Ui.Button(tr("Open recordings"), () => Ui.Shell(Recorder.Folder)));
            bar.Controls.Add(Ui.Button(S.Link.Recording ? tr("Stop recording") : tr("Record the mirror"), () => S.Link.ToggleRecording(), primary: S.Link.Recording));
            host.Controls.Add(bar);
        }
    }
}

// =====================================================================

sealed class NotificationsSection : Section
{
    readonly RowList list = new();
    readonly Panel host = new() { Dock = DockStyle.Fill };
    readonly CheckBox mute;
    readonly Label quiet = Ui.Label("", Ui.Small, Ui.Orange);
    readonly CardPanel detail = new(null) { Dock = DockStyle.Bottom, AutoSize = true };
    bool setting;

    public NotificationsSection()
    {
        mute = Ui.Check(tr("Mute all"), S.MuteAll, on => { if (!setting) S.MuteAll = on; });
        var clear = Ui.Button(tr("Clear all"), () => S.ClearAll());
        Controls.Add(host);
        Controls.Add(Header(tr("Notifications"), quiet, mute, clear));
        list.Activated += r => ShowDetail((Store.Notif)r.Tag);
        list.Picked += r => ShowDetail((Store.Notif)r.Tag);
        list.Menu += (r, p) => MenuFor((Store.Notif)r.Tag).Show(list, p);
        detail.Margin = new Padding(0, 10, 0, 0);
        detail.Visible = false;
        Refresh2();
    }

    public override void Shown() => Refresh2();
    public override void Changed(string what) { if (what is "notifications" or "status" or "settings") Refresh2(); }

    void Refresh2()
    {
        setting = true; mute.Checked = S.MuteAll; setting = false;
        quiet.Text = S.MuteAll ? "" : S.FollowPhoneDnd && S.PhoneDnd ? tr("Do Not Disturb") : S.QuietNow ? tr("Quiet hours") : "";
        host.Controls.Clear();
        if (S.Notifs.Count == 0)
        {
            host.Controls.Add(S.Connected
                ? new Placeholder(Glyph.Bell, tr("No notifications"), tr("New notifications from the phone show up here and as banners. Allow notification access in the PhoneCast app on the phone."))
                : StateFor("notifications", "notifications", "notification access"));
            return;
        }
        var muted = S.MutedApps;
        list.SetRows(S.Notifs.Select(n => new Row
        {
            Key = n.Key, Icon = S.Icons.GetValueOrDefault(n.Pkg), Glyph = Glyph.Bell, Title = $"{n.App} · {n.Title}", Sub = n.Text,
            Right = Ui.Ago(n.When) + (muted.Contains(n.Pkg) ? " 🔕" : ""), Tag = n,
        }));
        host.Controls.Add(list);
        host.Controls.Add(detail);
        if (detail.Visible && detail.Tag is Store.Notif cur && !S.Notifs.Contains(cur)) detail.Visible = false;
    }

    void ShowDetail(Store.Notif n)
    {
        detail.Tag = n;
        detail.SuspendLayout();
        detail.Controls.Clear();
        int w = Math.Max(LogicalToDeviceUnits(300), host.Width - LogicalToDeviceUnits(40));
        detail.Controls.Add(Ui.Label($"{n.App} · {n.When:t}", Ui.Small, Ui.Sub));
        detail.Controls.Add(Ui.Label(n.Title, Ui.Bold, null, w));
        detail.Controls.Add(Ui.Label(n.Text, Ui.Body, null, w));
        var row = Ui.Row();
        if (n.CanReply)
        {
            var box = Ui.Input(tr("Reply…"));
            box.Width = LogicalToDeviceUnits(300);
            box.Margin = new Padding(0, 6, 8, 4);
            void Send() { if (box.Text.Trim() == "") return; S.ReplyTo(n, box.Text.Trim()); box.Text = ""; Banners.Info(tr("Reply sent"), n.Title); }
            box.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; Send(); } };
            row.Controls.Add(box);
            row.Controls.Add(Ui.Button(tr("Send"), Send, primary: true));
        }
        row.Controls.Add(Ui.Button(tr("Open on phone"), () => S.Open(n)));
        row.Controls.Add(Ui.Button(tr("Clear"), () => { S.Dismiss(n); detail.Visible = false; }));
        detail.Controls.Add(row);
        detail.ResumeLayout();
        detail.Visible = true;
    }

    ContextMenuStrip MenuFor(Store.Notif n)
    {
        var m = new ContextMenuStrip();
        if (n.CanReply) m.Items.Add(tr("Reply…"), null, (_, _) => ShowDetail(n));
        m.Items.Add(tr("Open on phone"), null, (_, _) => S.Open(n));
        m.Items.Add(tr("Clear"), null, (_, _) => S.Dismiss(n));
        m.Items.Add(new ToolStripSeparator());
        bool muted = S.MutedApps.Contains(n.Pkg);
        m.Items.Add(muted ? tr("Show banners from {0}", n.App) : tr("No banners from {0}", n.App), null, (_, _) => { S.SetAppMuted(n.Pkg, !muted); Refresh2(); });
        m.Items.Add(tr("Copy text"), null, (_, _) => { try { Clipboard.SetText(n.Title + "\n" + n.Text); } catch { } });
        return m;
    }
}

// =====================================================================

sealed class MessagesSection : Section
{
    readonly RowList threads = new();
    readonly BubbleList bubbles = new();
    readonly TextBox compose = Ui.Input(tr("Text message"), multiline: true);
    readonly Label convTitle = Ui.Label("", Ui.H2), convSub = Ui.Label("", Ui.Small, Ui.Sub);
    readonly Panel host = new() { Dock = DockStyle.Fill };
    readonly SplitContainer split = new() { Dock = DockStyle.Fill, BackColor = Ui.Line, SplitterWidth = 1, FixedPanel = FixedPanel.Panel1 };
    readonly Panel right = new() { Dock = DockStyle.Fill, BackColor = Ui.Card };
    readonly Placeholder pick;
    long? open;
    string openAddress;
    static string pendingTo;

    /// Open Messages with a new message to [number] (from Contacts or Calls).
    public static void ComposeTo(string number) { pendingTo = number; MainForm.Open("messages"); }

    public MessagesSection()
    {
        Controls.Add(host);
        Controls.Add(Header(tr("Messages"), Ui.Button(tr("New message"), () => NewMessage(null), primary: true), Ui.Button(tr("Refresh"), () => S.LoadThreads())));
        split.Panel1.BackColor = Ui.Card; split.Panel2.BackColor = Ui.Card;
        split.Panel1.Controls.Add(threads);
        pick = new Placeholder(Glyph.Message, tr("Messages"), tr("SMS from the phone. Pick a conversation or start a new one.\nChats in WhatsApp, Signal or RCS are answered from Notifications.")) { BackColor = Ui.Card };

        var top = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, FlowDirection = FlowDirection.TopDown, BackColor = Ui.Card, Padding = new Padding(14, 10, 14, 8) };
        top.Controls.Add(convTitle); top.Controls.Add(convSub);
        var bottom = new TableLayoutPanel { Dock = DockStyle.Bottom, ColumnCount = 2, AutoSize = true, BackColor = Ui.Card, Padding = new Padding(10) };
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        compose.Height = LogicalToDeviceUnits(54);
        compose.Dock = DockStyle.Fill;
        compose.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter && !e.Shift) { e.SuppressKeyPress = true; Send(); } };
        var send = Ui.Button(tr("Send"), Send, primary: true);
        send.Anchor = AnchorStyles.Bottom;
        bottom.Controls.Add(compose, 0, 0); bottom.Controls.Add(send, 1, 0);
        bubbles.PictureClick += o => S.Link.FetchFile("photo.get", new JsonObject { ["uri"] = (string)o["image"] }, false, Ui.Shell);
        right.Controls.Add(bubbles);
        right.Controls.Add(top);
        right.Controls.Add(bottom);
        split.Panel2.Controls.Add(pick);

        threads.Picked += r => OpenThread((JsonObject)r.Tag);
        threads.Menu += (r, p) =>
        {
            var o = (JsonObject)r.Tag;
            var m = new ContextMenuStrip();
            m.Items.Add(tr("Call"), null, (_, _) => S.Dial((string)o["address"]));
            m.Items.Add(tr("Copy number"), null, (_, _) => { try { Clipboard.SetText((string)o["address"]); } catch { } });
            m.Show(threads, p);
        };
        HandleCreated += (_, _) => { try { split.SplitterDistance = LogicalToDeviceUnits(300); } catch { } };
    }

    public override void Shown()
    {
        Refresh2();
        if (S.Connected && S.Threads.Count == 0) S.LoadThreads();
        if (pendingTo != null) { var to = pendingTo; pendingTo = null; BeginInvoke(() => NewMessage(to)); }
    }

    public override void Changed(string what)
    {
        if (what is "messages" or "status" or "contacts") Refresh2();
        if (what == "thread" && open is long id && S.Messages.TryGetValue(id, out var list)) bubbles.SetMessages(list);
    }

    void Refresh2()
    {
        var state = S.Threads.Count == 0 ? StateFor("messages", "messages", "SMS") : null;
        if (state == null && S.Threads.Count == 0)
            state = S.Loading.Contains("messages") ? new Placeholder(Glyph.Message, tr("Loading…"), "") : new Placeholder(Glyph.Message, tr("No messages"), tr("SMS conversations on the phone show up here."), tr("New message"), () => NewMessage(null));
        host.Controls.Clear();
        if (state != null) { host.Controls.Add(state); return; }
        host.Controls.Add(split);
        threads.SetRows(S.Threads.Select(t =>
        {
            var name = (string)t["name"];
            var addr = (string)t["address"] ?? "";
            int unread = (int?)t["unread"] ?? 0;
            return new Row
            {
                Key = ((long?)t["thread"] ?? 0).ToString(), Glyph = Glyph.Contact, Title = string.IsNullOrEmpty(name) ? addr : name,
                Sub = (((bool?)t["mine"] ?? false) ? tr("You: ") : "") + (string)t["snippet"], Right = Ui.Ago(Ui.FromMs((long?)t["date"] ?? 0)),
                Badge = unread, Bold = unread > 0, Tag = t,
            };
        }));
    }

    void OpenThread(JsonObject t)
    {
        long id = (long?)t["thread"] ?? 0;
        open = id;
        openAddress = (string)t["address"];
        var name = (string)t["name"];
        convTitle.Text = string.IsNullOrEmpty(name) ? openAddress : name;
        convSub.Text = string.IsNullOrEmpty(name) ? "" : openAddress;
        if (!split.Panel2.Controls.Contains(right)) { split.Panel2.Controls.Clear(); split.Panel2.Controls.Add(right); }
        bubbles.SetMessages(S.Messages.GetValueOrDefault(id));
        S.LoadThread(id);
        compose.Focus();
    }

    void Send()
    {
        var text = compose.Text.Trim();
        if (text == "" || openAddress == null) return;
        S.SendSms(openAddress, text, open);
        compose.Text = "";
    }

    void NewMessage(string to)
    {
        using var d = new Form
        {
            Text = tr("New message"), FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
            StartPosition = FormStartPosition.CenterParent, AutoScaleMode = AutoScaleMode.Dpi, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Ui.Card, ForeColor = Ui.Text, Font = Ui.Body,
        };
        Ui.Chrome(d);
        var flow = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Padding = new Padding(16), WrapContents = false, BackColor = Ui.Card };
        flow.Controls.Add(Ui.Label(tr("To (number or contact)")));
        var toBox = new ComboBox { Width = 380, Font = Ui.Body, BackColor = Ui.InputBg, ForeColor = Ui.Text, AutoCompleteMode = AutoCompleteMode.SuggestAppend, AutoCompleteSource = AutoCompleteSource.ListItems };
        var map = new Dictionary<string, string>();
        foreach (var c in S.Contacts)
            if (c["numbers"] is JsonArray nums)
                foreach (var n in nums.OfType<JsonObject>())
                {
                    var label = $"{(string)c["name"]} ({(string)n["n"]})";
                    if (map.TryAdd(label, (string)n["n"])) toBox.Items.Add(label);
                }
        toBox.Text = to ?? "";
        flow.Controls.Add(toBox);
        flow.Controls.Add(Ui.Label(tr("Message")));
        var text = Ui.Input("", multiline: true);
        text.Width = 380; text.Height = 110;
        flow.Controls.Add(text);
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Width = 380, BackColor = Ui.Card };
        var ok = Ui.Button(tr("Send"), null, primary: true); ok.DialogResult = DialogResult.OK;
        var cancel = Ui.Button(tr("Cancel"), null); cancel.DialogResult = DialogResult.Cancel;
        buttons.Controls.Add(ok); buttons.Controls.Add(cancel);
        flow.Controls.Add(buttons);
        d.Controls.Add(flow);
        d.AcceptButton = null; d.CancelButton = cancel;
        if (S.Contacts.Count == 0) S.LoadContacts();
        if (d.ShowDialog(FindForm()) != DialogResult.OK) return;
        var number = map.GetValueOrDefault(toBox.Text.Trim()) ?? toBox.Text.Trim();
        if (number == "" || text.Text.Trim() == "") return;
        S.SendSms(number, text.Text.Trim(), null);
        Banners.Info(tr("Message sent"), number);
    }
}

// =====================================================================

sealed class CallsSection : Section
{
    readonly RowList list = new();
    readonly Panel host = new() { Dock = DockStyle.Fill };
    readonly CardPanel current = new(tr("Current call"), Glyph.Phone) { Dock = DockStyle.Top };
    readonly TextBox dial = Ui.Input(tr("Number"));

    public CallsSection()
    {
        dial.Width = LogicalToDeviceUnits(180);
        dial.Margin = new Padding(0, 6, 8, 0);
        dial.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; Dial(); } };
        Controls.Add(host);
        Controls.Add(current);
        Controls.Add(Header(tr("Calls"), dial, Ui.Button(tr("Call"), Dial, primary: true), Ui.Button(tr("Refresh"), () => S.LoadCalls())));
        current.Visible = false;
        current.Margin = new Padding(0, 0, 0, 10);
        list.Activated += r => S.Dial((string)((JsonObject)r.Tag)["number"]);
        list.Menu += (r, p) =>
        {
            var o = (JsonObject)r.Tag;
            var num = (string)o["number"];
            var m = new ContextMenuStrip();
            m.Items.Add(tr("Call {0}", num), null, (_, _) => S.Dial(num));
            m.Items.Add(tr("Send a message"), null, (_, _) => MessagesSection.ComposeTo(num));
            m.Items.Add(tr("Copy number"), null, (_, _) => { try { Clipboard.SetText(num); } catch { } });
            m.Show(list, p);
        };
    }

    void Dial()
    {
        var n = dial.Text.Trim();
        if (n == "") return;
        S.Dial(n);
        dial.Text = "";
    }

    public override void Shown() { Refresh2(); if (S.Connected && S.Calls.Count == 0) S.LoadCalls(); }
    public override void Changed(string what) { if (what is "calls" or "status" or "call") Refresh2(); }

    void Refresh2()
    {
        current.Visible = S.Call != null;
        if (S.Call is Dictionary<string, string> c)
        {
            while (current.Controls.Count > 1) current.Controls.RemoveAt(1);
            var who = c.GetValueOrDefault("name") is string nm && nm != "" ? nm : c.GetValueOrDefault("number") ?? tr("Unknown");
            bool ringing = c.GetValueOrDefault("state") == "ringing";
            current.Controls.Add(Ui.Label(ringing ? tr("{0} is calling", who) : tr("On a call with {0}", who), Ui.Bold));
            var row = Ui.Row();
            if (ringing) { var a = Ui.Button(tr("Answer"), () => S.Answer()); a.BackColor = Ui.Green; a.ForeColor = Color.White; row.Controls.Add(a); }
            var d = Ui.Button(ringing ? tr("Decline") : tr("End"), () => S.HangUp()); d.BackColor = Ui.Red; d.ForeColor = Color.White;
            row.Controls.Add(d);
            current.Controls.Add(row);
            current.Controls.Add(Ui.Label(tr("Calls are placed and answered on the phone; talk with the phone or its headset."), Ui.Small, Ui.Sub));
        }
        host.Controls.Clear();
        var state = S.Calls.Count == 0 ? StateFor("calls", "calls", "the call log") : null;
        if (state == null && S.Calls.Count == 0) state = new Placeholder(Glyph.Phone, S.Loading.Contains("calls") ? tr("Loading…") : tr("No calls"), "");
        if (state != null) { host.Controls.Add(state); return; }
        list.SetRows(S.Calls.Select((o, i) =>
        {
            var type = (string)o["type"];
            var name = (string)o["name"];
            var num = (string)o["number"] ?? "";
            long dur = (long?)o["duration"] ?? 0;
            var (glyph, color, label) = type switch
            {
                "in" => ("", Ui.Green, tr("Incoming")),
                "out" => ("", Ui.Accent, tr("Outgoing")),
                "missed" => ("", Ui.Red, tr("Missed")),
                "rejected" => ("", Ui.Orange, tr("Declined")),
                _ => (Glyph.Phone, Ui.Sub, tr("Call")),
            };
            return new Row
            {
                Key = i + num, Glyph = glyph, GlyphColor = color, Title = string.IsNullOrEmpty(name) ? num : name,
                Sub = label + (dur > 0 ? $" · {dur / 60}:{dur % 60:00}" : "") + (string.IsNullOrEmpty(name) ? "" : " · " + num),
                Right = Ui.Ago(Ui.FromMs((long?)o["date"] ?? 0)), RightColor = type == "missed" ? Ui.Red : null, Tag = o,
            };
        }));
        host.Controls.Add(list);
    }
}
