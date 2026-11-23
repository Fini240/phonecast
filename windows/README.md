# PhoneCast for Windows

The Windows version of PhoneCast. It works with the same phone app as the Mac version and, since 0.10, does
what the Mac app does: a PhoneCast window with Overview, Mirror, Notifications, Messages, Calls, Contacts,
Photos, Files, Apps, Transfers and Settings; the mirror with sound, mouse and keyboard, key map, mouse aiming,
game controllers and recording; and the phone controlling this PC. It connects over Wi-Fi, Tailscale, the
internet relay or a USB cable (USB tethering).

## What it does

- **The PhoneCast window** (tray icon → Open PhoneCast; closing it keeps PhoneCast running in the tray):
  phone battery, heat, network and storage, this PC's battery/CPU/memory, now playing, Find phone, and the other
  machines you watch; notification history with reply/open/dismiss and per-app banners; SMS and MMS
  conversations (read, reply, new message); call log, dial, answer/decline; contacts; photo and video grid
  (save to Downloads); the phone's files (open, download, upload, delete); apps (open on the phone); transfers.
- **Control this PC from the phone**: on the phone's Mac tab (pick this PC at the top when a Mac is linked
  too) → "Open the PC's screen" (the screen, encoded on the graphics card: NVENC, AMD AMF, Quick Sync, else
  Media Foundation) or "Trackpad & keyboard only"; plus volume, media keys, lock, screen off, screenshot (lands
  on the phone) and "Browser tab here". ⌘ = Ctrl, ⌥ = Alt, ⌃ = Windows key; ⌘Tab = Alt+Tab, ⌘Q = Alt+F4.
  Turn it off in Settings → Control this PC from the phone.
- **Stay awake**: the PC doesn't sleep, and a laptop's lid does nothing, for 1, 2 or 8 hours or until turned
  off (tray, Overview, Settings or the phone's Mac tab). Turns itself off on battery at 20 % and when PhoneCast
  quits; if PhoneCast crashes, a helper puts the lid setting back.
- **Continue the phone's website here**: Overview shows the page the phone's browser has open, with **Open on
  PC** (Ctrl+Shift+O, also in the tray). In Samsung Internet the phone reads the full address from the address bar
  the moment you press it.
- **Browser tab to the phone**: the page open in Chrome, Edge, Brave, Vivaldi, Opera or Firefox opens on the
  phone (tray, or the phone's "Browser tab here").
- **Phone in File Explorer**: the phone's storage as a drive letter (Files → Open in File Explorer, or the tray).
  PhoneCast relays Windows' WebDAV client to the phone on 127.0.0.1, so no registry change or admin rights.
- **Send to → PhoneCast (phone)** in Explorer's right-click menu sends files to the phone's Downloads.
- **Phone in a browser** (Settings, off by default): notifications and text messages at
  `http://<this PC>:27190/phone` for an iPad or a school laptop, with a 6-digit code.
- **Record the mirror** (Ctrl+Shift+R) to `Videos\PhoneCast` as .mp4 (the phone's H.264 as is, sound as AAC).
- **Advanced (USB debugging)**, with scrcpy installed (`winget install Genymobile.scrcpy`): phone apps in their
  own windows (right-click an app in Apps), the phone's camera as a window, its microphone, and the phone's
  screen really off while it's mirrored.
- **Lock this PC when the phone leaves** (optional), **Do Not Disturb** follows the phone, quiet hours,
  **clipboard both ways**, **files both ways**, **calls**, **links** shared from the phone open here,
  **updates in the app**, English and German.

Mac-only: the AI agents page (Claude Code and Codex chats run in tmux on the Mac) and Mac Shortcuts.

## Install

1. Download `PhoneCast-windows-x64.zip` from the release and unzip it anywhere (for example to
   `C:\Users\you\PhoneCast`).
2. Start `PhoneCast.exe`. No .NET or other runtime is needed.
3. Pair once: **Device → Pair with QR code** (Ctrl+P) shows a code; on the phone open PhoneCast →
   Settings → **Scan computer's QR code**, then click Done. (Or use the PIN from the phone app in the
   Connect dialog, Ctrl+K.)
4. Open PhoneCast on the phone and tap **Start sharing**. The PC connects by itself.

Windows SmartScreen may warn the first time, because the app isn't signed. Click "More info",
then "Run anyway".

## The link: notifications, clipboard, files

Besides the mirror, the PC stays linked to the phone over Wi-Fi or Tailscale (the same pairing):

- **Notifications** from the phone pop up on the PC; click one to reply, open it on the phone or dismiss it.
- **The tray icon** lists recent notifications and shows what the phone is playing, with play/pause and
  skip, plus **Ring phone** to find it.
- **Clipboard both ways**, text and pictures (Ctrl+Shift+C sends the PC's clipboard).
- **Files both ways:** drop files on the window or use Link → Send files; files from the phone land in
  `Downloads\PhoneCast`. New screenshots on the phone arrive by themselves (and go on the clipboard).
- **Calls:** answer or decline from the PC (the call itself stays on the phone).
- **Web links** shared from the phone ("PhoneCast to Mac") open in the PC's browser.

The phone can be linked to a Mac and a PC at the same time.

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
| Ctrl+K / Ctrl+P / Ctrl+Shift+D | Connect / pair with QR code / disconnect |
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

- FFmpeg 9.0 LGPL (H.264 decoding, recording, encoding this PC's screen for the phone)
- SDL2 (window, rendering, sound)
- libusb 1.0.30 (only for the experimental `PHONECAST_AOA` cable mode)

It then publishes a self-contained `windows/out/PhoneCast.exe`.

Test switches go in a file `PhoneCast.test.env` next to the exe, or in environment variables:

- `PHONECAST_TEST_HOST=…` connects only to this address.
- `PHONECAST_NO_USB=1` turns off the cable mode.
- `PHONECAST_SELFTEST=1` encodes 3 s of the screen to `selftest.h264`, reads the browser tab and switches
  Stay awake on and off (log only, nothing goes to the phone); `=drive` maps the phone drive without opening
  Explorer; `=panes` opens every section once.
- `PHONECAST_PANE=settings` opens the window at that section. `PHONECAST_LANG=de` / `en` overrides the language.
- `PHONECAST_HW_DECODE=1` decodes on the graphics card (also in Quality → Decoding). On a Ryzen 7
  5800X + RX 6700 XT this was slower than the processor: 8–15 ms vs 3–4 ms per frame in a game,
  because the frame has to be copied back from the graphics card.

The log is in `%LOCALAPPDATA%\PhoneCast\phonecast.log` and the settings are in
`%APPDATA%\PhoneCast\settings.json`.
