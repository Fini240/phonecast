namespace PhoneCast;

/// Game controllers (Xbox, PlayStation, Switch Pro… anything SDL knows) play phone games through the key map:
///  - left stick  = the movement joystick (analog: half a push = half the throw)
///  - right stick = mouse-look (the look area)
///  - buttons / triggers / d-pad = mapped buttons, bound in the key map editor like keys ("gA", "gRT", …)
/// Works while the mirror window has the focus (SDL only reports controllers to the window in front).
sealed unsafe partial class App
{
    readonly Dictionary<int, IntPtr> pads = new();   // instance id -> SDL_GameController*
    string padName;
    double padLX, padLY, padRX, padRY;
    bool stickDown, padLT, padRT;
    int padLookIdle;
    const double DeadZone = 0.18;

    // SDL_GameControllerButton -> key-map name and label (same names as the Mac)
    static readonly (string key, string label)[] PadButtons =
    {
        ("gA", "A"), ("gB", "B"), ("gX", "X"), ("gY", "Y"), ("gView", "⧉"), ("gGuide", "Guide"), ("gMenu", "☰"),
        ("gL3", "L3"), ("gR3", "R3"), ("gLB", "LB"), ("gRB", "RB"), ("gUp", "D↑"), ("gDown", "D↓"), ("gLeft", "D←"), ("gRight", "D→"),
    };

    void PadDevices()
    {
        int n = Sdl.SDL_NumJoysticks();
        var seen = new HashSet<int>();
        for (int i = 0; i < n; i++)
        {
            if (Sdl.SDL_IsGameController(i) == 0) continue;
            int id = Sdl.SDL_JoystickGetDeviceInstanceID(i);
            seen.Add(id);
            if (!pads.ContainsKey(id)) { var c = Sdl.SDL_GameControllerOpen(i); if (c != IntPtr.Zero) pads[id] = c; }
        }
        foreach (var id in pads.Keys.Where(k => !seen.Contains(k)).ToList()) { Sdl.SDL_GameControllerClose(pads[id]); pads.Remove(id); }
        var name = pads.Count > 0 ? Sdl.ControllerName(pads.Values.First()) : null;
        if (name != padName)
        {
            if (padName != null && name == null) PadRelease();
            padName = name;
            Log($"controller: {name ?? "none"}");
            var nm = name;
            Ui.Post(() => { Store.Shared.GamepadName = nm; Store.Shared.Fire("pc"); });
            if (name != null && stateText == "Connected") { SetMessage(tr("Controller connected: {0}\nBind its buttons in the key map (Ctrl+E).", name)); After(3, () => { if (stateText == "Connected") SetMessage(null); }); }
        }
    }

    void PadButton(int b, bool down)
    {
        if (b < 0 || b >= PadButtons.Length) return;
        var (key, label) = PadButtons[b];
        PadKey(key, label, down);
    }

    void PadKey(string key, string label, bool down)
    {
        switch (mode)
        {
            case Mode.Edit:
                if (down && pending != null) { Bind(key, label); overlayDirty = true; }
                break;
            default:
                if (typing || stateText != "Connected") return;
                if (down) Press(key); else Release(key);
                break;
        }
    }

    /// 120 Hz: sticks (and triggers as buttons).
    void PadTick()
    {
        if (pads.Count == 0) return;
        var c = pads.Values.First();
        double Ax(int a) { int v = Sdl.SDL_GameControllerGetAxis(c, a); return Math.Clamp(v / 32767.0, -1, 1); }
        padLX = Ax(0); padLY = -Ax(1); padRX = Ax(2); padRY = -Ax(3);   // y up, like the Mac
        bool lt = Ax(4) > 0.5, rt = Ax(5) > 0.5;
        if (lt != padLT) { padLT = lt; PadKey("gLT", "LT", lt); }
        if (rt != padRT) { padRT = rt; PadKey("gRT", "RT", rt); }
        PadSticks();
    }

    void PadSticks()
    {
        double lm = Math.Sqrt(padLX * padLX + padLY * padLY), rm = Math.Sqrt(padRX * padRX + padRY * padRY);
        if (mode == Mode.Edit)
        {
            // with a spot picked: push the left stick = joystick here, right stick = look area here
            if (pending == null) return;
            if (lm > 0.6) { map.joy = pending; foreach (var k in WasdKeys) map.binds.Remove("k" + k); }
            else if (rm > 0.6) map.look = pending;
            else return;
            map.Save(); pending = null; overlayDirty = true;
            return;
        }
        bool focused = (Sdl.SDL_GetWindowFlags(win) & 0x200) != 0;   // SDL_WINDOW_INPUT_FOCUS
        if (!focused || typing || stateText != "Connected")
        {
            if (stickDown && map.joy != null) { Send(TouchA.Up, JoyId, map.joy); stickDown = false; joyDown = false; }
            return;
        }
        // left stick -> movement joystick, analog
        if (map.joy is NPoint jc && joyKeys.Count == 0)
        {
            if (lm < DeadZone)
            {
                if (stickDown) { Send(TouchA.Up, JoyId, jc); stickDown = false; joyDown = false; }
            }
            else
            {
                double k = Math.Min(1, (lm - DeadZone) / (1 - DeadZone)) / lm;
                var (ox, oy) = Offset(padLX * k * map.joyR, -padLY * k * map.joyR);
                var target = new NPoint(jc.x + ox, jc.y + oy);
                if (!stickDown)
                {
                    Send(TouchA.Down, JoyId, jc); stickDown = true; joyDown = true; joyTarget = target;
                    After(0.03, () => { if (stickDown && joyTarget != null) Send(TouchA.Move, JoyId, joyTarget); });
                }
                else if (joyTarget == null || Math.Abs(joyTarget.x - target.x) > 1e-4 || Math.Abs(joyTarget.y - target.y) > 1e-4)
                {
                    joyTarget = target;
                    Send(TouchA.Move, JoyId, target);
                }
            }
        }
        // right stick -> look; speed grows with the push (fine aim near the centre)
        if (map.look != null)
        {
            if (rm >= DeadZone)
            {
                padLookIdle = 0;
                double v = Math.Pow((Math.Min(1, rm) - DeadZone) / (1 - DeadZone), 1.6) * 24;
                Look(padRX / rm * v, -padRY / rm * v);
            }
            else if (lookDown && mode == Mode.Normal)
            {
                // stick let go: lift the look finger after a moment (mouse aiming keeps it down)
                if (++padLookIdle == 18) { Send(TouchA.Up, LookId, lookPos); lookDown = false; }
            }
        }
    }

    void PadRelease()
    {
        foreach (var (key, _) in PadButtons) if (held.ContainsKey(key)) Release(key);
        if (held.ContainsKey("gLT")) Release("gLT");
        if (held.ContainsKey("gRT")) Release("gRT");
        padLX = padLY = padRX = padRY = 0; padLT = padRT = false;
        if (stickDown && map.joy != null) { Send(TouchA.Up, JoyId, map.joy); stickDown = false; joyDown = false; }
    }

    // ---------- recording ----------

    void ToggleRecord()
    {
        if (Recorder.Shared.Recording) { Recorder.Shared.Stop(); }
        else
        {
            if (stateText != "Connected") { Banners.Info(tr("Nothing to record"), tr("Open the mirror first.")); return; }
            Recorder.Shared.Start(videoW, videoH);
            link?.Send(CT.Keyframe);   // a file starts on a key frame
            SetMessage(tr("● Recording (Ctrl+Shift+R to stop)"));
            After(2, () => { if (stateText == "Connected") SetMessage(null); });
        }
        RefreshMenu();
        UpdateTitle();
        Ui.Post(() => Store.Shared.Fire("recording"));
    }
}
