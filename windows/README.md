# PhoneCast for Windows

The Windows version of the PhoneCast viewer. It works with the same phone app as the Mac version:
screen, sound, mouse and keyboard, the key map and mouse aiming. It connects over Wi-Fi, Tailscale
or a USB cable (USB tethering).

## Install

1. Download `PhoneCast-windows-x64.zip` from the release and unzip it anywhere (for example to
   `C:\Users\you\PhoneCast`).
2. Start `PhoneCast.exe`. No .NET or other runtime is needed.
3. Open PhoneCast on the phone and tap **Start sharing**. In the Windows app, choose the phone
   (or type its IP) and enter the PIN shown on the phone.

Windows SmartScreen may warn the first time, because the app isn't signed. Click "More info",
then "Run anyway".

## USB cable (lowest delay)

The cable uses the phone's **USB tethering**, which works on every Windows PC with no driver:

1. Plug the phone into the PC.
2. On the phone, open Settings → Connections → Mobile Hotspot and Tethering → **USB tethering**.

PhoneCast finds the phone on the cable by itself and prefers it to Wi-Fi. The title bar says
"USB", and the delay is about 2 ms.

Windows gives the tethering connection the same priority as the PC's normal network, so part of
the PC's internet would go through the phone (mobile data). The first time, PhoneCast offers to
lower that priority, so the cable is used only for PhoneCast. This needs administrator
permission once.

(The Mac's cable mode, Android Open Accessory, doesn't work on Windows: Windows puts its own MTP
driver on the accessory interface. The code is still there and can be tried with
`PHONECAST_AOA=1` together with the UsbDk driver.)

## Shortcuts

Ctrl is used wherever the Mac version uses ⌘:

| Keys | What it does |
|---|---|
| F11 / Ctrl+F | Full screen |
| Ctrl+1 / 2 / 3 | Fit / Fill / Stretch |
| Ctrl+0 | Window size = phone |
| Ctrl+B / H / R / N | Back / Home / Recent apps / Notifications |
| Ctrl+E | Edit the key map (Esc when done) |
| Ctrl+G | Mouse aiming (game mode, Esc to leave) |
| Ctrl+T | Keys type text instead of pressing mapped buttons |
| Ctrl+= / Ctrl+- | Mouse aiming faster / slower |
| Ctrl+M / Ctrl+O | Mute / stats overlay |
| Ctrl+K / Ctrl+Shift+D | Connect / disconnect |
| Ctrl+I | List of shortcuts |

Mouse: a click is a tap, a drag is a swipe, and the wheel or touchpad scrolls. Right-click or
Esc is Back, and middle-click is Home. The mouse's side buttons can be bound in the key map.

In the key map editor, Alt-click places the movement joystick and Ctrl-click places the
mouse-look area.

## Build

From macOS, Linux or Windows, with the .NET 8+ SDK and the GitHub CLI installed:

```
windows/build.sh
```

The script downloads the native parts once into `windows/deps/`:

- FFmpeg 9.0 LGPL (H.264 decoding)
- SDL2 (window, rendering, sound)
- libusb 1.0.30 (only for the experimental `PHONECAST_AOA` cable mode)

It then publishes a self-contained `windows/out/PhoneCast.exe`.

Test switches go in a file `PhoneCast.test.env` next to the exe, or in environment variables:

- `PHONECAST_TEST_HOST=…` connects only to this address.
- `PHONECAST_NO_USB=1` turns off the cable mode.
- `PHONECAST_HW_DECODE=1` decodes on the graphics card (also in Quality → Decoding). On a Ryzen 7
  5800X + RX 6700 XT this was slower than the processor: 8–15 ms vs 3–4 ms per frame in a game,
  because the frame has to be copied back from the graphics card.

The log is in `%LOCALAPPDATA%\PhoneCast\phonecast.log` and the settings are in
`%APPDATA%\PhoneCast\settings.json`.
