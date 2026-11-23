using System.IO.Pipes;
using System.Text;

namespace PhoneCast;

/// One PhoneCast at a time. A second start (from Explorer's "Send to → PhoneCast", or a double-click while it runs)
/// hands its files to the running one over a named pipe and quits.
static class Single
{
    const string Name = "PhoneCast.Single.v1";
    static Mutex mutex;

    /// True when this is the first PhoneCast; otherwise the request went to the running one.
    public static bool Claim(string[] args)
    {
        mutex = new Mutex(true, @"Local\" + Name, out bool first);
        if (first) return true;
        try
        {
            using var c = new NamedPipeClientStream(".", Name, PipeDirection.Out);
            c.Connect(3000);
            var msg = Encoding.UTF8.GetBytes(string.Join("\n", args.Length > 0 ? args : new[] { "--show" }));
            c.Write(msg);
        }
        catch { }
        return false;
    }

    /// In the first PhoneCast: take requests from later starts.
    public static void Listen()
    {
        new Thread(() =>
        {
            while (true)
            {
                try
                {
                    using var s = new NamedPipeServerStream(Name, PipeDirection.In, 1, PipeTransmissionMode.Byte);
                    s.WaitForConnection();
                    using var ms = new MemoryStream();
                    s.CopyTo(ms);
                    var args = Encoding.UTF8.GetString(ms.ToArray()).Split('\n', StringSplitOptions.RemoveEmptyEntries);
                    Ui.Post(() => Handle(args));
                }
                catch (Exception e) { App.Log("single: " + e.Message); Thread.Sleep(500); }
            }
        }) { IsBackground = true, Name = "single" }.Start();
    }

    /// UI thread.
    public static void Handle(string[] args)
    {
        var files = args.Where(a => !a.StartsWith("--") && (File.Exists(a) || Directory.Exists(a))).ToArray();
        if (args.Contains("--send") || files.Length > 0)
        {
            if (files.Length == 0) return;
            if (!Store.Shared.Connected) { Banners.Info(tr("The phone isn't linked"), tr("Open PhoneCast on the phone; the link connects by itself.")); return; }
            Store.Shared.Link.SendFiles(files);
            return;
        }
        if (!args.Contains("--tray")) MainForm.Open();
    }

    /// Explorer's right-click → Send to → PhoneCast (a shortcut in the user's SendTo folder).
    public static void InstallSendTo()
    {
        try
        {
            var dir = Environment.GetFolderPath(Environment.SpecialFolder.SendTo);
            var lnk = Path.Combine(dir, "PhoneCast (phone).lnk");
            var exe = Environment.ProcessPath;
            if (exe == null || File.Exists(lnk) && Settings.Str("sendToTarget") == exe) return;
            var t = Type.GetTypeFromProgID("WScript.Shell");
            if (t == null) return;
            dynamic sh = Activator.CreateInstance(t);
            dynamic sc = sh.CreateShortcut(lnk);
            sc.TargetPath = exe;
            sc.Arguments = "--send";
            sc.IconLocation = Path.Combine(AppContext.BaseDirectory, "phonecast_on.ico");
            sc.Description = "Send to the phone with PhoneCast";
            sc.Save();
            Settings.Set("sendToTarget", exe);
            App.Log("send to: shortcut installed");
        }
        catch (Exception e) { App.Log("send to: " + e.Message); }
    }
}
