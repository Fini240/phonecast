using System.Runtime.InteropServices;
using System.Text;

namespace PhoneCast;

/// The small part of SDL2 we use: window, renderer, events, audio.
static unsafe class Sdl
{
    const string L = "SDL2";
    public const uint INIT_VIDEO = 0x20, INIT_AUDIO = 0x10, INIT_EVENTS = 0x4000;
    public const uint WINDOW_RESIZABLE = 0x20, WINDOW_HIDDEN = 0x8, WINDOW_FULLSCREEN_DESKTOP = 0x1001, WINDOW_ALLOW_HIGHDPI = 0x2000;
    public const int WINDOWPOS_CENTERED = 0x2FFF0000;
    public const uint RENDERER_ACCELERATED = 2, RENDERER_PRESENTVSYNC = 4;
    public const uint PIXELFORMAT_NV12 = 0x3231564E, PIXELFORMAT_IYUV = 0x56555949, PIXELFORMAT_ARGB8888 = 0x16362004;
    public const int TEXTUREACCESS_STREAMING = 1;
    public const int BLENDMODE_BLEND = 1;

    // events
    public const uint QUIT = 0x100, WINDOWEVENT = 0x200, SYSWMEVENT = 0x201, KEYDOWN = 0x300, KEYUP = 0x301, TEXTINPUT = 0x303,
        MOUSEMOTION = 0x400, MOUSEBUTTONDOWN = 0x401, MOUSEBUTTONUP = 0x402, MOUSEWHEEL = 0x403;
    public const byte WE_SIZE_CHANGED = 6, WE_FOCUS_GAINED = 12, WE_FOCUS_LOST = 13, WE_CLOSE = 14, WE_DISPLAY_CHANGED = 18, WE_EXPOSED = 3, WE_MOVED = 4;
    public const ushort KMOD_SHIFT = 0x3, KMOD_CTRL = 0xC0, KMOD_ALT = 0x300, KMOD_GUI = 0xC00;

    [StructLayout(LayoutKind.Sequential)]
    public struct AudioSpec
    {
        public int freq; public ushort format; public byte channels; public byte silence;
        public ushort samples; public ushort padding; public uint size; public IntPtr callback; public IntPtr userdata;
    }

    /// SDL_Event is a 56-byte union; we read fields by offset.
    [StructLayout(LayoutKind.Explicit, Size = 64)]
    public struct Event
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(0)] public fixed byte raw[64];
    }

    [DllImport(L)] public static extern int SDL_Init(uint flags);
    [DllImport(L)] public static extern void SDL_Quit();
    [DllImport(L)] public static extern IntPtr SDL_GetError();
    public static string Error => Marshal.PtrToStringUTF8(SDL_GetError()) ?? "";
    [DllImport(L)] static extern int SDL_SetHint(byte[] name, byte[] value);
    public static void Hint(string n, string v) => SDL_SetHint(Z(n), Z(v));
    [DllImport(L)] static extern IntPtr SDL_CreateWindow(byte[] title, int x, int y, int w, int h, uint flags);
    public static IntPtr CreateWindow(string t, int x, int y, int w, int h, uint f) => SDL_CreateWindow(Z(t), x, y, w, h, f);
    [DllImport(L)] static extern void SDL_SetWindowTitle(IntPtr w, byte[] t);
    public static void SetTitle(IntPtr w, string t) => SDL_SetWindowTitle(w, Z(t));
    [DllImport(L)] public static extern void SDL_GetWindowSize(IntPtr w, out int x, out int y);
    [DllImport(L)] public static extern void SDL_SetWindowSize(IntPtr w, int x, int y);
    [DllImport(L)] public static extern void SDL_GetWindowPosition(IntPtr w, out int x, out int y);
    [DllImport(L)] public static extern void SDL_SetWindowPosition(IntPtr w, int x, int y);
    [DllImport(L)] public static extern void SDL_SetWindowMinimumSize(IntPtr w, int x, int y);
    [DllImport(L)] public static extern int SDL_SetWindowFullscreen(IntPtr w, uint flags);
    [DllImport(L)] public static extern uint SDL_GetWindowFlags(IntPtr w);
    [DllImport(L)] public static extern void SDL_ShowWindow(IntPtr w);
    [DllImport(L)] public static extern void SDL_RaiseWindow(IntPtr w);
    [DllImport(L)] public static extern int SDL_GetWindowDisplayIndex(IntPtr w);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int x, y, w, h; }
    [DllImport(L)] public static extern int SDL_GetDisplayBounds(int i, out Rect r);
    [DllImport(L)] public static extern int SDL_GetDisplayUsableBounds(int i, out Rect r);
    [DllImport(L)] static extern int SDL_GetWindowWMInfo(IntPtr w, byte* info);
    public static IntPtr Hwnd(IntPtr w)
    {
        byte* b = stackalloc byte[256];
        for (int i = 0; i < 256; i++) b[i] = 0;
        b[0] = 2; b[1] = 0; b[2] = 18; // SDL_VERSION (any 2.0.18+ is fine)
        if (SDL_GetWindowWMInfo(w, b) == 0) return IntPtr.Zero;
        return *(IntPtr*)(b + 8);
    }

    [DllImport(L)] public static extern IntPtr SDL_CreateRenderer(IntPtr w, int index, uint flags);
    [DllImport(L)] public static extern void SDL_DestroyRenderer(IntPtr r);
    [DllImport(L)] public static extern int SDL_GetRendererOutputSize(IntPtr r, out int w, out int h);
    [DllImport(L)] public static extern IntPtr SDL_CreateTexture(IntPtr r, uint format, int access, int w, int h);
    [DllImport(L)] public static extern void SDL_DestroyTexture(IntPtr t);
    [DllImport(L)] public static extern int SDL_UpdateNVTexture(IntPtr t, Rect* r, byte* y, int yPitch, byte* uv, int uvPitch);
    [DllImport(L)] public static extern int SDL_UpdateYUVTexture(IntPtr t, Rect* r, byte* y, int yp, byte* u, int up, byte* v, int vp);
    [DllImport(L)] public static extern int SDL_UpdateTexture(IntPtr t, Rect* r, void* pixels, int pitch);
    [DllImport(L)] public static extern int SDL_SetTextureBlendMode(IntPtr t, int mode);
    [DllImport(L)] public static extern int SDL_SetRenderDrawColor(IntPtr r, byte R, byte G, byte B, byte A);
    [DllImport(L)] public static extern int SDL_RenderClear(IntPtr r);
    [DllImport(L)] public static extern int SDL_RenderCopy(IntPtr r, IntPtr t, Rect* src, Rect* dst);
    [DllImport(L)] public static extern void SDL_RenderPresent(IntPtr r);
    [DllImport(L)] public static extern int SDL_RenderSetVSync(IntPtr r, int vsync);
    [DllImport(L)] public static extern void SDL_SetYUVConversionMode(int mode);

    [DllImport(L)] public static extern int SDL_WaitEventTimeout(out Event e, int ms);
    [DllImport(L)] public static extern int SDL_PollEvent(out Event e);
    [DllImport(L)] public static extern int SDL_PushEvent(ref Event e);
    [DllImport(L)] public static extern uint SDL_RegisterEvents(int n);
    [DllImport(L)] public static extern byte SDL_EventState(uint type, int state);
    [DllImport(L)] public static extern void SDL_StartTextInput();
    [DllImport(L)] public static extern void SDL_StopTextInput();
    [DllImport(L)] public static extern int SDL_SetRelativeMouseMode(int on);
    [DllImport(L)] public static extern int SDL_ShowCursor(int toggle);
    [DllImport(L)] public static extern ushort SDL_GetModState();
    [DllImport(L)] static extern IntPtr SDL_GetScancodeName(int sc);
    public static string ScancodeName(int sc) => Marshal.PtrToStringUTF8(SDL_GetScancodeName(sc)) ?? "?";
    [DllImport(L)] public static extern void SDL_WarpMouseInWindow(IntPtr w, int x, int y);

    [DllImport(L)] public static extern uint SDL_OpenAudioDevice(IntPtr device, int iscapture, ref AudioSpec want, out AudioSpec have, int allowedChanges);
    [DllImport(L)] public static extern void SDL_PauseAudioDevice(uint dev, int pause);
    [DllImport(L)] public static extern int SDL_QueueAudio(uint dev, byte* data, uint len);
    [DllImport(L)] public static extern uint SDL_GetQueuedAudioSize(uint dev);
    [DllImport(L)] public static extern void SDL_ClearQueuedAudio(uint dev);
    [DllImport(L)] public static extern void SDL_CloseAudioDevice(uint dev);

    static byte[] Z(string s) { var b = Encoding.UTF8.GetBytes(s); Array.Resize(ref b, b.Length + 1); return b; }

    // event field readers
    public static int I32(ref Event e, int off) { fixed (byte* p = e.raw) return *(int*)(p + off); }
    public static uint U32(ref Event e, int off) { fixed (byte* p = e.raw) return *(uint*)(p + off); }
    public static ushort U16(ref Event e, int off) { fixed (byte* p = e.raw) return *(ushort*)(p + off); }
    public static byte U8(ref Event e, int off) { fixed (byte* p = e.raw) return p[off]; }
    public static float F32(ref Event e, int off) { fixed (byte* p = e.raw) return *(float*)(p + off); }
    public static IntPtr Ptr(ref Event e, int off) { fixed (byte* p = e.raw) return *(IntPtr*)(p + off); }
    public static string Text(ref Event e, int off)
    {
        fixed (byte* p = e.raw)
        {
            int n = 0; while (n < 32 && p[off + n] != 0) n++;
            return Encoding.UTF8.GetString(p + off, n);
        }
    }
}

/// libusb-1.0 (with the UsbDk backend, so the phone needs no special driver).
static unsafe class Usb
{
    const string L = "libusb-1.0";
    public const int ERROR_IO = -1, ERROR_ACCESS = -3, ERROR_NO_DEVICE = -4, ERROR_NOT_FOUND = -5, ERROR_BUSY = -6, ERROR_TIMEOUT = -7, ERROR_NOT_SUPPORTED = -12;
    public const int OPTION_USE_USBDK = 1;
    [DllImport(L)] public static extern int libusb_init(out IntPtr ctx);
    [DllImport(L)] public static extern void libusb_exit(IntPtr ctx);
    [DllImport(L)] public static extern int libusb_set_option(IntPtr ctx, int option);
    [DllImport(L)] public static extern nint libusb_get_device_list(IntPtr ctx, out IntPtr* list);
    [DllImport(L)] public static extern void libusb_free_device_list(IntPtr* list, int unref);
    [DllImport(L)] public static extern int libusb_get_device_descriptor(IntPtr dev, byte* desc);
    [DllImport(L)] public static extern IntPtr libusb_ref_device(IntPtr dev);
    [DllImport(L)] public static extern void libusb_unref_device(IntPtr dev);
    [DllImport(L)] public static extern int libusb_open(IntPtr dev, out IntPtr handle);
    [DllImport(L)] public static extern void libusb_close(IntPtr handle);
    [DllImport(L)] public static extern IntPtr libusb_get_device(IntPtr handle);
    [DllImport(L)] public static extern int libusb_reset_device(IntPtr handle);
    [DllImport(L)] public static extern int libusb_control_transfer(IntPtr h, byte reqType, byte req, ushort value, ushort index, byte* data, ushort len, uint timeout);
    [DllImport(L)] public static extern int libusb_get_active_config_descriptor(IntPtr dev, out byte* cfg);
    [DllImport(L)] public static extern void libusb_free_config_descriptor(byte* cfg);
    [DllImport(L)] public static extern int libusb_claim_interface(IntPtr h, int iface);
    [DllImport(L)] public static extern int libusb_release_interface(IntPtr h, int iface);
    [DllImport(L)] public static extern int libusb_bulk_transfer(IntPtr h, byte ep, byte* data, int len, out int transferred, uint timeout);
}

/// Win32 menus and a few helpers.
static class Win32
{
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern IntPtr LoadImageW(IntPtr inst, string name, uint type, int cx, int cy, uint flags);
    [DllImport("user32")] public static extern IntPtr SendMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32")] public static extern int GetSystemMetrics(int index);
    public const uint MF_STRING = 0, MF_POPUP = 0x10, MF_SEPARATOR = 0x800, MF_CHECKED = 0x8, MF_UNCHECKED = 0, MF_GRAYED = 1, MF_BYCOMMAND = 0;
    public const uint WM_COMMAND = 0x0111;
    [DllImport("user32")] public static extern IntPtr CreateMenu();
    [DllImport("user32")] public static extern IntPtr CreatePopupMenu();
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern bool AppendMenuW(IntPtr menu, uint flags, nint id, string text);
    [DllImport("user32")] public static extern bool SetMenu(IntPtr hwnd, IntPtr menu);
    [DllImport("user32")] public static extern uint CheckMenuItem(IntPtr menu, uint id, uint flags);
    [DllImport("user32")] public static extern bool DrawMenuBar(IntPtr hwnd);
    [DllImport("user32")] public static extern int TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int r, IntPtr hwnd, IntPtr rect);
    [DllImport("user32")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32")] public static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32")] public static extern bool DeleteMenu(IntPtr menu, uint pos, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
    public const uint TPM_RETURNCMD = 0x100, TPM_NONOTIFY = 0x80;
    [DllImport("winmm")] public static extern uint timeBeginPeriod(uint ms);
}

public sealed class HwndOwner : System.Windows.Forms.IWin32Window
{
    public HwndOwner(IntPtr h) { Handle = h; }
    public IntPtr Handle { get; }
}
