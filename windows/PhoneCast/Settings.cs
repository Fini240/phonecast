using System.Text.Json;
using System.Text.Json.Nodes;

namespace PhoneCast;

/// Small JSON settings file in %APPDATA%\PhoneCast (the Windows twin of the Mac's UserDefaults).
static class Settings
{
    /// PHONECAST_SETTINGS_DIR: a separate settings folder (tests), else %APPDATA%\PhoneCast.
    static readonly string Dir = Environment.GetEnvironmentVariable("PHONECAST_SETTINGS_DIR") is string d && d != ""
        ? d : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PhoneCast");
    static readonly string FilePath = Path.Combine(Dir, "settings.json");
    static JsonObject root = Load();

    static JsonObject Load()
    {
        try { return JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject ?? new JsonObject(); }
        catch { return new JsonObject(); }
    }

    static void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath + ".tmp", root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(FilePath + ".tmp", FilePath, true);
        }
        catch { }
    }

    public static string Str(string k) => root[k]?.GetValue<string>();
    public static int Int(string k, int def = 0) { try { return root[k]?.GetValue<int>() ?? def; } catch { return def; } }
    public static double Dbl(string k, double def = 0) { try { return root[k]?.GetValue<double>() ?? def; } catch { return def; } }
    public static bool Bool(string k, bool def = false) { try { return root[k]?.GetValue<bool>() ?? def; } catch { return def; } }
    public static bool Has(string k) => root[k] != null;
    public static void Set(string k, string v) { if (v == null) root.Remove(k); else root[k] = v; Save(); }
    public static void Set(string k, int v) { root[k] = v; Save(); }
    public static void Set(string k, double v) { root[k] = v; Save(); }
    public static void Set(string k, bool v) { root[k] = v; Save(); }
    public static void Remove(string k) { root.Remove(k); Save(); }
    public static string LogDir { get { var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PhoneCast"); Directory.CreateDirectory(d); return d; } }
}

public sealed class NPoint { public double x { get; set; } public double y { get; set; } public NPoint() { } public NPoint(double x, double y) { this.x = x; this.y = y; } }
public sealed class Bind
{
    public double x { get; set; } public double y { get; set; } public string label { get; set; } = "";
    /// Turbo: taps per second while held (null = a normal press). Same JSON as the Mac's key maps.
    public double? turbo { get; set; }
    /// Macro: one key taps these spots one after another.
    public List<NPoint> steps { get; set; }
    public double? stepMs { get; set; }
}

/// Key map: which key/mouse button taps where, plus the WASD joystick and the mouse-look area.
/// Keys are named "k<SDL scancode>", mouse buttons "m0"/"m1"/"m2".
public sealed class KeyMap
{
    public Dictionary<string, Bind> binds { get; set; } = new();
    public NPoint joy { get; set; }
    public double joyR { get; set; } = 0.11;
    public NPoint look { get; set; }
    public double lookR { get; set; } = 0.16;
    public double sens { get; set; } = 1.0;

    /// The phone's current screen layout ("2560x1664"); each layout keeps its own map.
    public static string Layout = "";

    public static (KeyMap map, bool copied) Load(string layout)
    {
        bool copied = false;
        string data = layout == "" ? null : Settings.Str("keymap." + layout);
        if (data == null) { data = Settings.Str("keymap"); copied = layout != "" && data != null; }
        KeyMap m = null;
        try { if (data != null) m = JsonSerializer.Deserialize<KeyMap>(data); } catch { }
        if (m == null) return (new KeyMap(), false);
        m.binds ??= new();
        if (Settings.Has("lookSens")) m.sens = Settings.Dbl("lookSens", 1);
        return (m, copied);
    }

    static readonly JsonSerializerOptions Quiet = new() { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };

    /// A key map file to share ("Fortnite.phonecast-keys.json"); the Mac reads and writes the same format.
    public string Export(string game) => JsonSerializer.Serialize(new JsonObjectFile { game = game, layout = Layout, map = this },
        new JsonSerializerOptions(Quiet) { WriteIndented = true });

    public static KeyMap Import(string json)
    {
        try { var f = JsonSerializer.Deserialize<JsonObjectFile>(json); if (f?.map != null) { f.map.binds ??= new(); return f.map; } } catch { }
        try { var m = JsonSerializer.Deserialize<KeyMap>(json); if (m != null && (m.binds?.Count > 0 || m.joy != null || m.look != null)) { m.binds ??= new(); return m; } } catch { }
        return null;
    }

    public sealed class JsonObjectFile { public int phonecastKeyMap { get; set; } = 1; public string game { get; set; } = ""; public string layout { get; set; } = ""; public KeyMap map { get; set; } }

    public void Save()
    {
        var data = JsonSerializer.Serialize(this, Quiet);
        Settings.Set("keymap", data);
        if (Layout != "") Settings.Set("keymap." + Layout, data);
        Settings.Set("lookSens", sens);
    }
}
