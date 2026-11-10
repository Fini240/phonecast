using System.Drawing;
using System.Windows.Forms;

namespace PhoneCast;

sealed class ConnectDialog : Form
{
    readonly ComboBox phone = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 340 };
    readonly TextBox host = new() { Width = 340, PlaceholderText = "e.g. 192.168.1.57 (shown in the phone app)" };
    readonly TextBox pin = new() { Width = 340, PlaceholderText = "6-digit PIN from the phone app (not needed after QR pairing)" };
    readonly TextBox tail = new() { Width = 340, PlaceholderText = "optional, e.g. 100.64.0.10 — used when Wi-Fi can't reach it" };
    const string ByIp = "IP address below";

    public string Pin => pin.Text.Trim();
    public string Host => host.Text.Trim();
    public string Tailnet => tail.Text.Trim();
    public string Service => phone.SelectedItem as string is string s && s != ByIp ? s : null;

    public ConnectDialog(List<string> found)
    {
        Text = "Connect to your phone";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Font = new Font("Segoe UI", 9.5f);
        var flow = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Padding = new Padding(14), WrapContents = false };
        Label L(string t, bool bold = false) => new() { Text = t, AutoSize = true, Margin = new Padding(0, 8, 0, 2), Font = bold ? new Font(Font, FontStyle.Bold) : Font };
        flow.Controls.Add(L("Open PhoneCast on the phone and tap Start sharing. Phones on this Wi-Fi show up automatically;\na phone plugged in by USB cable is used first. Easier and safer than the PIN: Device → Pair with QR code (Ctrl+P).", false));
        flow.Controls.Add(L("Phone:"));
        foreach (var f in found) phone.Items.Add(f);
        phone.Items.Add(ByIp);
        var saved = Settings.Str("service");
        if (saved != null && found.Contains(saved)) phone.SelectedItem = saved;
        else if (found.Count > 0 && Settings.Str("host") == null) phone.SelectedIndex = 0;
        else phone.SelectedItem = ByIp;
        flow.Controls.Add(phone);
        flow.Controls.Add(L("IP address:")); host.Text = Settings.Str("host") ?? ""; flow.Controls.Add(host);
        flow.Controls.Add(L("PIN:")); pin.Text = Settings.Str("pin") ?? ""; flow.Controls.Add(pin);
        flow.Controls.Add(L("Tailscale address of the phone:")); tail.Text = Settings.Str("tailnetHost") ?? ""; flow.Controls.Add(tail);
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Width = 340, Margin = new Padding(0, 14, 0, 0) };
        var ok = new Button { Text = "Connect", DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.Add(ok); buttons.Controls.Add(cancel);
        flow.Controls.Add(buttons);
        Controls.Add(flow);
        AcceptButton = ok; CancelButton = cancel;
        Shown += (_, _) => { Activate(); (pin.Text == "" ? pin : (Control)ok).Focus(); };
    }
}
