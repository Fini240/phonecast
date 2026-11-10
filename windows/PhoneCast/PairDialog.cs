using System.Drawing;
using System.Windows.Forms;
using QRCoder;

namespace PhoneCast;

/// Shows this PC's pairing QR code; the phone scans it (PhoneCast → Settings → Scan computer's QR code).
sealed class PairDialog : Form
{
    public PairDialog(string code)
    {
        Text = "Pair this PC with your phone";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Font = new Font("Segoe UI", 9.5f);
        BackColor = Color.White;
        var flow = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Padding = new Padding(16), WrapContents = false };
        flow.Controls.Add(new Label
        {
            AutoSize = true, MaximumSize = new Size(380, 0),
            Text = "On the phone: open PhoneCast → Settings → Scan computer's QR code, and point the camera at this code. " +
                   "Then click Done. No PIN needed afterwards, and both sides check each other.",
        });
        using var gen = new QRCodeGenerator();
        using var data = gen.CreateQrCode(code, QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(8, new byte[] { 0, 0, 0 }, new byte[] { 255, 255, 255 }, true);
        var img = Image.FromStream(new MemoryStream(png));
        flow.Controls.Add(new PictureBox { Image = img, SizeMode = PictureBoxSizeMode.Zoom, Width = 340, Height = 340, Margin = new Padding(20, 12, 20, 12) });
        flow.Controls.Add(new Label { AutoSize = true, ForeColor = Color.DimGray, Text = "Keep this code private: it works like a password for this PC." });
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Width = 380, Margin = new Padding(0, 12, 0, 0) };
        var ok = new Button { Text = "Done", DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.Add(ok); buttons.Controls.Add(cancel);
        flow.Controls.Add(buttons);
        Controls.Add(flow);
        AcceptButton = ok; CancelButton = cancel;
    }
}
