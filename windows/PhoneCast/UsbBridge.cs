using System.Net;
using System.Net.Sockets;
using System.Text;

namespace PhoneCast;

/// Cable link without USB debugging: switches the phone into Android Open Accessory mode with libusb
/// (UsbDk backend, so Windows needs no per-device driver), then exposes the USB bulk pipe as a local
/// TCP port so Link works unchanged.
sealed unsafe class UsbBridge
{
    public static readonly UsbBridge Shared = new();

    IntPtr ctx, handle, switchHandle;
    byte epIn, epOut;
    int iface;
    TcpListener listener;
    Socket client;
    readonly object usbLock = new(), stopLock = new();
    Thread inThread, outThread;
    volatile bool running, gone;
    public int Port { get; private set; }
    /// UsbDk (the driver libusb needs to talk to a phone on Windows) is installed.
    public bool HaveUsbDk { get; private set; }
    public bool Loaded { get; private set; }
    public bool HeldByOtherApp { get; private set; }
    public string LastError = "";

    static readonly HashSet<ushort> AndroidVendors = new() { 0x04E8, 0x18D1, 0x22B8, 0x2717, 0x12D1, 0x2A70, 0x0BB4, 0x1004, 0x054C, 0x0FCE, 0x2D95, 0x05C6, 0x1949, 0x0E8D };
    static bool IsAccessory(ushort vid, ushort pid) => vid == 0x18D1 && pid >= 0x2D00 && pid <= 0x2D05;

    UsbBridge() { Init(); }

    /// (Re)loads libusb, e.g. after UsbDk was installed.
    public void Init()
    {
        lock (usbLock)
        {
            try
            {
                if (ctx != IntPtr.Zero) { Usb.libusb_exit(ctx); ctx = IntPtr.Zero; }
                if (Usb.libusb_init(out ctx) != 0) { ctx = IntPtr.Zero; return; }
                HaveUsbDk = Usb.libusb_set_option(ctx, Usb.OPTION_USE_USBDK) == 0;
                Loaded = true;
            }
            catch (Exception e) { Loaded = false; LastError = e.Message; }
        }
    }

    readonly record struct Dev(IntPtr P, ushort Vid, ushort Pid);

    List<Dev> Devices(out IntPtr* list)
    {
        var outList = new List<Dev>();
        list = null;
        if (ctx == IntPtr.Zero) return outList;
        nint n = Usb.libusb_get_device_list(ctx, out list);
        byte* d = stackalloc byte[18];
        for (int i = 0; i < n; i++)
        {
            if (Usb.libusb_get_device_descriptor(list[i], d) == 0)
                outList.Add(new Dev(list[i], *(ushort*)(d + 8), *(ushort*)(d + 10)));
        }
        return outList;
    }

    bool lastPresent;
    /// Is an Android phone plugged in? Never blocks while start() is busy.
    public bool PhonePresent()
    {
        if (!Loaded) return false;
        if (!Monitor.TryEnter(usbLock)) return lastPresent;
        try
        {
            var devs = Devices(out var list);
            lastPresent = devs.Any(d => AndroidVendors.Contains(d.Vid));
            if (list != null) Usb.libusb_free_device_list(list, 1);
            return lastPresent;
        }
        finally { Monitor.Exit(usbLock); }
    }

    /// Switches the phone to accessory mode, opens the pipe and returns a local port. Blocking (~1–3 s).
    public int? Start()
    {
        lock (usbLock)
        {
            App.Log("usb: start");
            Stop();
            HeldByOtherApp = false;
            LastError = "";
            // 1. Still an accessory from an earlier run: reset so both sides start clean.
            var acc = FindAccessory();
            if (acc != IntPtr.Zero)
            {
                App.Log("usb: still an accessory, resetting");
                if (Usb.libusb_open(acc, out var h) == 0) { Usb.libusb_reset_device(h); Usb.libusb_close(h); }
                App.Log("usb: reset done");
                Usb.libusb_unref_device(acc);
                Thread.Sleep(1500);
            }
            // 2. Ask the phone to become our accessory.
            acc = FindAccessory();
            if (acc == IntPtr.Zero)
            {
                App.Log("usb: asking the phone for accessory mode");
                if (!SwitchToAccessory()) { if (LastError == "") LastError = "the phone didn't accept accessory mode"; return null; }
                for (int i = 0; i < 48 && acc == IntPtr.Zero; i++)
                {
                    Thread.Sleep(250); acc = FindAccessory();
                    if (i % 8 == 7) App.Log("usb: waiting, devices: " + string.Join(" ", DeviceIds()));
                }
            }
            if (switchHandle != IntPtr.Zero) { Usb.libusb_close(switchHandle); switchHandle = IntPtr.Zero; }
            if (acc == IntPtr.Zero) { LastError = "the phone never came back as an accessory"; return null; }
            gone = false;
            App.Log("usb: accessory found, opening");
            bool ok = OpenAccessory(acc);
            Usb.libusb_unref_device(acc);
            if (!ok) return null;
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start(1);
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            running = true;
            new Thread(AcceptLoop) { IsBackground = true, Name = "usb-accept" }.Start();
            return Port;
        }
    }

    List<string> DeviceIds()
    {
        var devs = Devices(out var list);
        var ids = devs.Where(d => AndroidVendors.Contains(d.Vid)).Select(d => $"{d.Vid:X4}:{d.Pid:X4}").ToList();
        if (list != null) Usb.libusb_free_device_list(list, 1);
        return ids;
    }

    IntPtr FindAccessory()
    {
        var devs = Devices(out var list);
        IntPtr found = IntPtr.Zero;
        foreach (var d in devs) if (IsAccessory(d.Vid, d.Pid)) { found = Usb.libusb_ref_device(d.P); break; }
        if (list != null) Usb.libusb_free_device_list(list, 1);
        return found;
    }

    bool SwitchToAccessory()
    {
        var devs = Devices(out var list);
        try
        {
            foreach (var d in devs)
            {
                if (!AndroidVendors.Contains(d.Vid) || IsAccessory(d.Vid, d.Pid)) continue;
                int o = Usb.libusb_open(d.P, out var h);
                if (o != 0) { LastError = o == Usb.ERROR_NOT_SUPPORTED || o == Usb.ERROR_ACCESS ? "Windows won't let PhoneCast talk to the phone (USB driver UsbDk missing?)" : $"open failed ({o})"; continue; }
                try
                {
                    byte* ver = stackalloc byte[2];
                    int r = Usb.libusb_control_transfer(h, 0xC0, 51, 0, 0, ver, 2, 1000);
                    if (r != 2 || (ver[0] | ver[1] << 8) < 1) { LastError = "the phone doesn't support accessory mode"; continue; }
                    string[] strings = { "Finn", "PhoneCast", "PhoneCast Windows viewer", "1.0", "https://github.com/Fini240", "phonecast" };
                    for (int i = 0; i < strings.Length; i++)
                    {
                        var bytes = Encoding.UTF8.GetBytes(strings[i] + "\0");
                        fixed (byte* p = bytes) Usb.libusb_control_transfer(h, 0x40, 52, 0, (ushort)i, p, (ushort)bytes.Length, 1000);
                    }
                    Usb.libusb_control_transfer(h, 0x40, 53, 0, 0, null, 0, 1000);
                    // Don't close yet: with UsbDk, closing hands the device back to Windows with a USB
                    // reset, and that reset knocks the phone straight out of the accessory mode it is
                    // switching into. Closed once the accessory has shown up (the old device is gone then).
                    switchHandle = h; h = IntPtr.Zero;
                    return true;
                }
                finally { if (h != IntPtr.Zero) Usb.libusb_close(h); }
            }
            return false;
        }
        finally { if (list != null) Usb.libusb_free_device_list(list, 1); }
    }

    bool OpenAccessory(IntPtr dev)
    {
        int o = Usb.libusb_open(dev, out var h);
        if (o != 0) { LastError = $"couldn't open the accessory ({o})"; return false; }
        if (Usb.libusb_get_active_config_descriptor(dev, out var cfg) != 0) { LastError = "no config descriptor"; Usb.libusb_close(h); return false; }
        try
        {
            // libusb_config_descriptor: interface* at +16; libusb_interface: altsetting* at +0;
            // libusb_interface_descriptor: bInterfaceNumber +2, bNumEndpoints +4, endpoint* +16;
            // libusb_endpoint_descriptor (32 bytes): bEndpointAddress +2, bmAttributes +3
            byte* ifc = *(byte**)(cfg + 16);
            byte* alt = *(byte**)ifc;
            iface = alt[2];
            int nEp = alt[4];
            byte* eps = *(byte**)(alt + 16);
            epIn = 0; epOut = 0;
            for (int i = 0; i < nEp; i++)
            {
                byte* ep = eps + i * 32;
                if ((ep[3] & 3) != 2) continue;
                if ((ep[2] & 0x80) != 0) epIn = ep[2]; else epOut = ep[2];
            }
        }
        finally { Usb.libusb_free_config_descriptor(cfg); }
        if (epIn == 0 || epOut == 0) { LastError = "no bulk endpoints"; Usb.libusb_close(h); return false; }
        int c = Usb.libusb_claim_interface(h, iface);
        HeldByOtherApp = c == Usb.ERROR_ACCESS || c == Usb.ERROR_BUSY;
        if (c != 0) { LastError = HeldByOtherApp ? "another app is using the phone's USB connection" : $"claim failed ({c})"; Usb.libusb_close(h); return false; }
        handle = h;
        return true;
    }

    void AcceptLoop()
    {
        Socket s;
        try { s = listener.AcceptSocket(); } catch { Stop(); return; }
        s.NoDelay = true;
        client = s;
        inThread = new Thread(UsbToSocket) { IsBackground = true, Name = "usb-in", Priority = ThreadPriority.Highest };
        outThread = new Thread(SocketToUsb) { IsBackground = true, Name = "usb-out" };
        inThread.Start(); outThread.Start();
    }

    void SocketToUsb()
    {
        var buf = new byte[16384];
        try
        {
            while (running)
            {
                int n = client.Receive(buf);
                if (n <= 0) break;
                // a transfer that is an exact multiple of 512 bytes has no short packet at the end
                var chunks = n % 512 == 0 && n > 1 ? new[] { (0, n - 1), (n - 1, 1) } : new[] { (0, n) };
                foreach (var (start, len) in chunks)
                {
                    int off = 0;
                    while (off < len)
                    {
                        int r, sent;
                        fixed (byte* p = buf) r = Usb.libusb_bulk_transfer(handle, epOut, p + start + off, len - off, out sent, 0);
                        if (r != 0) { if (r == Usb.ERROR_NO_DEVICE) gone = true; Stop(); return; }
                        off += sent;
                    }
                }
            }
        }
        catch { }
        Stop();
    }

    void UsbToSocket()
    {
        var buf = new byte[65536];
        try
        {
            while (running)
            {
                int r, got;
                // No timeout (a timed-out read can lose bytes and desync the stream); Stop() resets the device.
                fixed (byte* p = buf) r = Usb.libusb_bulk_transfer(handle, epIn, p, buf.Length, out got, 0);
                if (r != 0) { if (r == Usb.ERROR_NO_DEVICE) gone = true; break; }
                int off = 0;
                while (off < got) { int w = client.Send(buf, off, got - off, SocketFlags.None); if (w <= 0) { Stop(); return; } off += w; }
            }
        }
        catch { }
        Stop();
    }

    /// Closes everything and resets the phone out of accessory mode so the next start is clean.
    public void Stop()
    {
        IntPtr h;
        bool wasRunning;
        lock (stopLock)
        {
            wasRunning = running;
            running = false;
            try { client?.Close(); } catch { }
            client = null;
            try { listener?.Stop(); } catch { }
            listener = null;
            h = handle; handle = IntPtr.Zero;
        }
        if (h == IntPtr.Zero) return;
        bool skipReset = gone;
        var me = Thread.CurrentThread;
        var threads = new[] { inThread, outThread };
        new Thread(() =>
        {
            lock (usbLock)
            {
                App.Log($"usb: stopping (reset={wasRunning && !skipReset})");
                if (wasRunning && !skipReset) { Usb.libusb_release_interface(h, iface); Usb.libusb_reset_device(h); }
                App.Log("usb: reset sent, waiting for the pipe threads");
                // the bulk threads end once the device is reset; only then free the handle
                foreach (var t in threads) if (t != null && t != me) t.Join(2000);
                Usb.libusb_close(h);
                App.Log("usb: stopped");
            }
        }) { IsBackground = true }.Start();
    }
}
