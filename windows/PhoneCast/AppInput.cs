namespace PhoneCast;

sealed unsafe partial class App
{
    /// Returns false to quit.
    bool HandleEvent(ref Sdl.Event e)
    {
        switch (e.type)
        {
            case Sdl.QUIT: return false;
            case Sdl.WINDOWEVENT:
                {
                    byte we = Sdl.U8(ref e, 12);
                    if (we == Sdl.WE_SIZE_CHANGED || we == Sdl.WE_EXPOSED || we == Sdl.WE_DISPLAY_CHANGED) { needRender = true; overlayDirty = true; }
                    if (we == Sdl.WE_FOCUS_LOST) { if (mode == Mode.Game) SetMode(Mode.Normal); else ReleaseAll(); }
                    if (we == Sdl.WE_CLOSE) return false;
                    break;
                }
            case 0x2000: case 0x2001: // render targets / device reset: our textures are gone
                videoTex = IntPtr.Zero; overlayTex = IntPtr.Zero; overlayBmp?.Dispose(); overlayBmp = null; overlayDirty = true; link?.Send(CT.Keyframe);
                break;
            case Sdl.SYSWMEVENT:
                {
                    byte* m = (byte*)Sdl.Ptr(ref e, 8);
                    if (m != null && *(uint*)(m + 16) == Win32.WM_COMMAND)
                    {
                        int id = (int)(*(ulong*)(m + 24) & 0xFFFF);
                        Post(() => MenuCommand(id));
                    }
                    break;
                }
            case Sdl.DROPFILE:
                {
                    // files dropped on the window go to the phone
                    var ptr = Sdl.Ptr(ref e, 8);
                    var path = System.Runtime.InteropServices.Marshal.PtrToStringUTF8(ptr);
                    Sdl.SDL_free(ptr);
                    if (!string.IsNullOrEmpty(path)) { dropped.Add(path); After(0.15, FlushDrops); }
                    break;
                }
            case Sdl.KEYDOWN: KeyDown(Sdl.I32(ref e, 16), Sdl.U8(ref e, 13) != 0, Sdl.U16(ref e, 24)); break;
            case Sdl.KEYUP: KeyUp(Sdl.I32(ref e, 16)); break;
            case Sdl.TEXTINPUT:
                if (mode == Mode.Normal && Now > suppressTextUntil && stateText == "Connected")
                {
                    var t = Sdl.Text(ref e, 12);
                    if (t.Length > 0 && t.All(c => c >= 32 && c != 127)) link?.Send(CT.Text, System.Text.Encoding.UTF8.GetBytes(t));
                }
                break;
            case Sdl.MOUSEMOTION:
                {
                    int x = Sdl.I32(ref e, 20), y = Sdl.I32(ref e, 24), xr = Sdl.I32(ref e, 28), yr = Sdl.I32(ref e, 32);
                    MouseMove(x, y, xr, yr);
                    break;
                }
            case Sdl.MOUSEBUTTONDOWN: MouseButton(Sdl.U8(ref e, 16), true, Sdl.I32(ref e, 20), Sdl.I32(ref e, 24)); break;
            case Sdl.MOUSEBUTTONUP: MouseButton(Sdl.U8(ref e, 16), false, Sdl.I32(ref e, 20), Sdl.I32(ref e, 24)); break;
            case Sdl.MOUSEWHEEL:
                {
                    float px = Sdl.F32(ref e, 28), py = Sdl.F32(ref e, 32);
                    if (Sdl.U32(ref e, 24) == 1) { px = -px; py = -py; } // flipped direction
                    Wheel(px, py, Sdl.I32(ref e, 36), Sdl.I32(ref e, 40));
                    break;
                }
        }
        return true;
    }

    void Send(byte a, byte id, NPoint p) => link?.Touch(a, id, p.x, p.y);

    readonly List<string> dropped = new();
    void FlushDrops()
    {
        if (dropped.Count == 0) return;
        var all = dropped.Distinct().ToArray(); dropped.Clear();
        SendFiles(all);
    }

    // ---------- modes ----------

    void SetMode(Mode m)
    {
        if (mode == m) return;
        if (mode == Mode.Game) ReleaseAll();
        mode = m;
        pending = null;
        if (m == Mode.Game) { Sdl.SDL_StopTextInput(); Sdl.SDL_SetRelativeMouseMode(1); }
        else
        {
            Sdl.SDL_SetRelativeMouseMode(0);
            if (m == Mode.Normal) Sdl.SDL_StartTextInput(); else Sdl.SDL_StopTextInput();
        }
        overlayDirty = true;
        RefreshMenu(); UpdateTitle();
    }

    void ReleaseAll()
    {
        link?.Touch(TouchA.CancelAll, 0, 0, 0);
        held.Clear(); freeIds.Clear(); freeIds.AddRange(new byte[] { 2, 3, 4, 5, 6, 7, 8 });
        joyKeys.Clear(); joyDown = false;
        lookDown = false; lookFlushPending = false;
        scrolling = false; leftDown = false;
    }

    // ---------- mouse ----------

    static string ButtonName(int b) => b switch { 1 => "m0", 3 => "m1", 2 => "m2", 4 => "m3", 5 => "m4", _ => null };

    void MouseButton(int button, bool down, int x, int y)
    {
        var name = ButtonName(button);
        if (name == null) return;
        switch (mode)
        {
            case Mode.Normal:
                if (button == 1)
                {
                    if (down) { leftDown = true; Send(TouchA.Down, MouseId, Norm(x, y)); }
                    else if (leftDown) { leftDown = false; Send(TouchA.Up, MouseId, Norm(x, y)); }
                }
                else if (button >= 4 && !typing && map.binds.ContainsKey(name)) { if (down) Press(name); else Release(name); } // mapped side buttons
                else if (down && button == 3) link?.Send(CT.Global, new[] { GlobalA.Back });
                else if (down && button == 2) link?.Send(CT.Global, new[] { GlobalA.Home });
                break;
            case Mode.Game:
                if (down) Press(name); else Release(name);
                break;
            case Mode.Edit:
                if (!down) { if (dragging != null) { dragging = null; map.Save(); } break; }
                var mods = Sdl.SDL_GetModState();
                var p = Norm(x, y);
                if (button == 1 && pending == null && (mods & (Sdl.KMOD_ALT | Sdl.KMOD_CTRL)) == 0 && NearestMarker(p, 0.035) is string k) { dragging = k; break; }
                EditClick(p, button, mods);
                break;
        }
    }

    void MouseMove(int x, int y, int xr, int yr)
    {
        switch (mode)
        {
            case Mode.Normal: if (leftDown) Send(TouchA.Move, MouseId, Norm(x, y)); break;
            case Mode.Game: Look(xr, yr); break;
            case Mode.Edit:
                hover = Norm(x, y);
                if (dragging != null) MoveMarker(dragging, hover);
                break;
        }
    }

    void Wheel(float dx, float dy, int mx, int my)
    {
        if (mode == Mode.Edit) { map.joyR = Math.Clamp(map.joyR + dy * 0.01, 0.04, 0.3); map.Save(); overlayDirty = true; return; }
        if (mode != Mode.Normal) return;
        // a real finger drag that follows the wheel / touchpad; the phone does its own fling
        var r = VideoRectPx();
        double k = 70 * Dpi;
        if (!scrolling)
        {
            scrolling = true;
            scrollPos = Norm(mx, my);
            Send(TouchA.Down, ScrollId, scrollPos);
        }
        scrollPos = new NPoint(Math.Clamp(scrollPos.x - dx * k / r.Width, 0, 1), Math.Clamp(scrollPos.y + dy * k / r.Height, 0, 1));
        Send(TouchA.Move, ScrollId, scrollPos);
        scrollLastAt = Now;
    }

    // ---------- keyboard ----------

    bool IsMapped(int sc) => map.binds.ContainsKey("k" + sc) || (map.joy != null && Wasd.ContainsKey(sc));

    void KeyDown(int sc, bool repeat, ushort mods)
    {
        bool ctrl = (mods & Sdl.KMOD_CTRL) != 0 && (mods & Sdl.KMOD_ALT) == 0;
        bool shift = (mods & Sdl.KMOD_SHIFT) != 0;
        if (sc == 68) { if (!repeat) ToggleFullScreen(); return; } // F11
        switch (mode)
        {
            case Mode.Normal:
                if (ctrl && !repeat && Shortcut(sc, shift)) { suppressTextUntil = Now + 0.05; return; }
                if (!typing && IsMapped(sc)) { suppressTextUntil = Now + 0.05; if (!repeat) KeyPress(sc); return; }
                if (stateText != "Connected") return;
                switch (sc)
                {
                    case 41: link?.Send(CT.Global, new[] { GlobalA.Back }); break;      // Esc
                    case 42: link?.Send(CT.Key, new byte[] { 1 }); break;               // Backspace
                    case 40: case 88: link?.Send(CT.Key, new byte[] { 2 }); break;      // Enter
                }
                break;
            case Mode.Game:
                if (sc == 41) { SetMode(Mode.Normal); return; }
                // only harmless shortcuts in game mode (Ctrl is often a game key)
                if (ctrl && !repeat && (sc == 10 || sc == 18 || sc == 16 || sc == 46 || sc == 45 || sc == 87 || sc == 86) && Shortcut(sc, shift)) return;
                if (repeat) return;
                KeyPress(sc);
                break;
            case Mode.Edit:
                EditKey(sc, repeat, ctrl, shift);
                break;
        }
    }

    void KeyUp(int sc)
    {
        if (mode == Mode.Game || (mode == Mode.Normal && !typing)) KeyRelease(sc);
    }

    /// Ctrl shortcuts (the Mac's ⌘ ones). Returns true if handled.
    bool Shortcut(int sc, bool shift)
    {
        switch (sc)
        {
            case 14: ShowConnect(); return true;                                     // K
            case 19: ShowPairing(); return true;                                     // P
            case 7: if (shift) { Disconnect(); return true; } return false;          // Shift+D
            case 6: if (shift) { SendClipboard(); return true; } return false;       // Shift+C
            case 5: link?.Send(CT.Global, new[] { GlobalA.Back }); return true;      // B
            case 11: link?.Send(CT.Global, new[] { GlobalA.Home }); return true;     // H
            case 21: link?.Send(CT.Global, new[] { GlobalA.Recents }); return true;  // R
            case 17: link?.Send(CT.Global, new[] { GlobalA.Notifications }); return true; // N
            case 10: ToggleGame(); return true;                                      // G
            case 23: typing = !typing; if (typing) ReleaseAll(); RefreshMenu(); UpdateTitle(); return true; // T
            case 8: SetMode(mode == Mode.Edit ? Mode.Normal : Mode.Edit); return true; // E
            case 13: showMarkers = !showMarkers; overlayDirty = true; RefreshMenu(); return true; // J
            case 46: case 87: SensUp(); return true;                                 // = / keypad +
            case 45: case 86: SensDown(); return true;                               // - / keypad -
            case 16: audio.Muted = !audio.Muted; if (audio.Muted) audio.Stop(); RefreshMenu(); return true; // M
            case 18: ToggleStats(); return true;                                     // O
            case 30: SetScale(Scale.Fit); return true;                               // 1
            case 31: SetScale(Scale.Fill); return true;                              // 2
            case 32: SetScale(Scale.Stretch); return true;                           // 3
            case 39: FitWindow(); return true;                                       // 0
            case 9: ToggleFullScreen(); return true;                                 // F
            case 12: ShowShortcuts(); return true;                                   // I
            case 82: link?.Send(CT.Global, new[] { GlobalA.VolUp }); return true;    // Up
            case 81: link?.Send(CT.Global, new[] { GlobalA.VolDown }); return true;  // Down
        }
        return false;
    }

    void SetScale(Scale s) { scale = s; Settings.Set("scale", (int)s); overlayDirty = true; needRender = true; RefreshMenu(); }
    void ToggleStats() { showStats = !showStats; Settings.Set("statsOverlay", showStats); overlayDirty = true; RefreshMenu(); }
    void SensUp() { map.sens = Math.Min(5, map.sens * 1.12); map.Save(); UpdateTitle(); }
    void SensDown() { map.sens = Math.Max(0.1, map.sens / 1.12); map.Save(); UpdateTitle(); }

    void ToggleGame()
    {
        if (mode != Mode.Game && map.look == null)
        {
            map.look = new NPoint(0.62, 0.28);
            map.Save();
            SetMessage("Mouse aiming on — the mouse now turns the camera.\nEsc to stop. To move the aiming area: Ctrl+E, then Ctrl-click.");
            After(3.5, () => SetMessage(null));
        }
        SetMode(mode == Mode.Game ? Mode.Normal : Mode.Game);
    }

    // ---------- game input ----------

    void KeyPress(int sc)
    {
        sc = Canonical.GetValueOrDefault(sc, sc);
        if (map.joy != null && Wasd.ContainsKey(sc)) { joyKeys.Add(sc); UpdateJoy(); return; }
        if (map.binds.ContainsKey("k" + sc)) Press("k" + sc);
    }

    void KeyRelease(int sc)
    {
        sc = Canonical.GetValueOrDefault(sc, sc);
        if (joyKeys.Remove(sc)) { UpdateJoy(); return; }
        if (held.ContainsKey("k" + sc)) Release("k" + sc);
    }

    void Press(string name)
    {
        if (!map.binds.TryGetValue(name, out var b) || held.ContainsKey(name) || freeIds.Count == 0) return;
        byte id = freeIds[0]; freeIds.RemoveAt(0);
        held[name] = id;
        pressedAt[name] = Now;
        Send(TouchA.Down, id, new NPoint(b.x, b.y));
    }

    void Release(string name)
    {
        if (!held.TryGetValue(name, out var id) || !map.binds.TryGetValue(name, out var b)) return;
        double elapsed = Now - pressedAt.GetValueOrDefault(name);
        if (elapsed < MinPress) { After(MinPress - elapsed, () => Release(name)); return; } // 30-fps games miss shorter taps
        held.Remove(name);
        Send(TouchA.Up, id, new NPoint(b.x, b.y));
        freeIds.Add(id);
        // a touch on the fire button takes the camera from the look finger: press look again
        if (name.StartsWith("m") && lookDown) RecentreLook();
    }

    void RecentreLook()
    {
        if (map.look == null) return;
        lookFlushPending = false;
        Send(TouchA.Up, LookId, lookPos);
        lookPos = new NPoint(map.look.x, map.look.y);
        Send(TouchA.Down, LookId, lookPos);
        lookHoldUntil = Now + 0.025;
    }

    (double, double) Offset(double dx, double dy)
    {
        double s = Math.Min(videoW, videoH);
        return (dx * s / videoW, dy * s / videoH);
    }

    void UpdateJoy()
    {
        var c = map.joy;
        if (c == null) return;
        double dx = 0, dy = 0;
        foreach (var k in joyKeys) if (Wasd.TryGetValue(k, out var v)) { dx += v.Item1; dy += v.Item2; }
        double len = Math.Sqrt(dx * dx + dy * dy);
        if (len == 0) { if (joyDown) { Send(TouchA.Up, JoyId, c); joyDown = false; } return; }
        var (ox, oy) = Offset(dx / len * map.joyR, dy / len * map.joyR);
        var target = new NPoint(c.x + ox, c.y + oy);
        if (!joyDown)
        {
            // thumb down, let the game register it, then slide
            Send(TouchA.Down, JoyId, c);
            joyDown = true; joyTarget = target;
            After(0.03, () => { if (joyDown && joyTarget != null) Send(TouchA.Move, JoyId, joyTarget); });
            return;
        }
        joyTarget = target;
        Send(TouchA.Move, JoyId, target);
    }

    void Look(double dx, double dy)
    {
        var a = map.look;
        if (a == null || (dx == 0 && dy == 0)) return;
        if (!lookDown)
        {
            lookPos = new NPoint(a.x, a.y);
            Send(TouchA.Down, LookId, lookPos);
            lookDown = true;
            lookHoldUntil = Now + 0.025;
        }
        var (ox, oy) = Offset(dx * map.sens * 0.0004, dy * map.sens * 0.0004);
        lookPos = new NPoint(lookPos.x + ox, lookPos.y + oy);
        double s = Math.Min(videoW, videoH);
        double dist = Math.Sqrt(Math.Pow((lookPos.x - a.x) * videoW / s, 2) + Math.Pow((lookPos.y - a.y) * videoH / s, 2));
        if (dist > map.lookR || lookPos.x <= 0.01 || lookPos.x >= 0.99 || lookPos.y <= 0.01 || lookPos.y >= 0.99) { RecentreLook(); return; }
        double wait = lookHoldUntil - Now;
        if (wait > 0)
        {
            // the game hasn't registered the new touch yet: send the collected movement afterwards
            if (!lookFlushPending)
            {
                lookFlushPending = true;
                After(wait, () => { if (lookFlushPending && lookDown) Send(TouchA.Move, LookId, lookPos); lookFlushPending = false; });
            }
            return;
        }
        Send(TouchA.Move, LookId, lookPos);
    }

    // ---------- key map editing ----------

    void EditClick(NPoint p, int button, ushort mods)
    {
        if ((mods & Sdl.KMOD_ALT) != 0) { map.joy = p; map.Save(); pending = null; }
        else if ((mods & Sdl.KMOD_CTRL) != 0) { map.look = p; map.Save(); pending = null; }
        else if (pending != null) { var n = ButtonName(button); if (n != null) Bind(n, button switch { 1 => "LMB", 3 => "RMB", 2 => "MMB", 4 => "M4", _ => "M5" }); }
        else if (button == 1) pending = p;
        overlayDirty = true;
    }

    void EditKey(int sc, bool repeat, bool ctrl, bool shift)
    {
        if (ctrl && !repeat && pending == null && (sc == 8 || sc == 14 || sc == 9 || sc == 18) && Shortcut(sc, shift)) return;
        switch (sc)
        {
            case 41: if (pending != null) pending = null; else SetMode(Mode.Normal); break;
            case 42: case 76: DeleteNearest(pending ?? hover); pending = null; break;
            default:
                if (pending == null || repeat) break;
                if (Wasd.ContainsKey(sc))
                {
                    map.joy = pending;
                    foreach (var k in WasdKeys) map.binds.Remove("k" + k);
                    map.Save(); pending = null;
                }
                else { sc = Canonical.GetValueOrDefault(sc, sc); Bind("k" + sc, KeyName(sc)); }
                break;
        }
        overlayDirty = true;
    }

    void Bind(string name, string label)
    {
        if (pending == null) return;
        map.binds[name] = new Bind { x = pending.x, y = pending.y, label = label };
        map.Save();
        pending = null;
        overlayDirty = true;
    }

    string NearestMarker(NPoint p, double within = 0.06)
    {
        double D(double x, double y) => Math.Sqrt(Math.Pow(x - p.x, 2) + Math.Pow((y - p.y) * videoH / videoW, 2));
        string best = null; double bd = within;
        foreach (var (k, b) in map.binds) { double d = D(b.x, b.y); if (d < bd) { best = k; bd = d; } }
        if (map.joy != null && D(map.joy.x, map.joy.y) < bd) { best = "joy"; bd = D(map.joy.x, map.joy.y); }
        if (map.look != null && D(map.look.x, map.look.y) < bd) { best = "look"; }
        return best;
    }

    void DeleteNearest(NPoint p)
    {
        if (p == null || NearestMarker(p) is not string k) return;
        if (k == "joy") map.joy = null; else if (k == "look") map.look = null; else map.binds.Remove(k);
        map.Save();
    }

    void MoveMarker(string k, NPoint p)
    {
        if (k == "joy") map.joy = p; else if (k == "look") map.look = p;
        else if (map.binds.TryGetValue(k, out var b)) { b.x = p.x; b.y = p.y; }
        overlayDirty = true;
    }

    static string KeyName(int sc)
    {
        switch (sc)
        {
            case 44: return "Space"; case 43: return "Tab"; case 40: return "Ret"; case 225: return "Shift"; case 224: return "Ctrl";
            case 226: return "Alt"; case 57: return "Caps"; case 80: return "←"; case 79: return "→"; case 81: return "↓"; case 82: return "↑";
        }
        var n = Sdl.ScancodeName(sc);
        return n.Length > 6 ? n[..6] : n.ToUpperInvariant();
    }

    void SwitchKeyLayout(int w, int h)
    {
        string layout = $"{w}x{h}";
        if (layout == KeyMap.Layout) return;
        bool first = KeyMap.Layout == "";
        if (mode == Mode.Game) SetMode(Mode.Normal);
        KeyMap.Layout = layout;
        var (m, copied) = KeyMap.Load(layout);
        map = m;
        overlayDirty = true;
        if (!(w > h) || !(copied || !first) || (m.binds.Count == 0 && m.joy == null && m.look == null)) return;
        SetMessage(copied
            ? $"New screen layout ({w}×{h}): the game's buttons moved.\nYour last key map was copied — check it with Ctrl+E and drag the markers into place."
            : $"Key map for {w}×{h} loaded");
        After(copied ? 6 : 2.5, () => { if (stateText == "Connected") SetMessage(null); });
    }
}
