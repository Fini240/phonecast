using System.Windows.Forms;

namespace PhoneCast;

static class Program
{
    [STAThread]
    static void Main()
    {
        // test switches can also come from a file next to the exe (PHONECAST_TEST_HOST=…, one per line)
        var envFile = Path.Combine(AppContext.BaseDirectory, "PhoneCast.test.env");
        if (File.Exists(envFile))
            foreach (var line in File.ReadAllLines(envFile))
                if (line.Split('=', 2) is { Length: 2 } kv && kv[0].Trim() != "") Environment.SetEnvironmentVariable(kv[0].Trim(), kv[1].Trim());
        Application.EnableVisualStyles();
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => App.Log("CRASH: " + e.ExceptionObject);
        try { new App().Run(); }
        catch (Exception e)
        {
            App.Log("CRASH: " + e);
            MessageBox.Show(e.Message, "PhoneCast crashed");
        }
    }
}
