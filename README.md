# PhoneCast

Connects an Android phone and a Mac, similar to LinkMyDroid or Phone Link:

- **Mirror** the phone on the Mac and control it with mouse and keyboard (USB cable or Wi-Fi, with sound),
  and **control the Mac from the phone**.
- **Notifications** from the phone as Mac banners, with reply, clear and open-on-phone.
- **Messages (SMS), calls, contacts, photos, phone files and apps** in one Mac window.
- **Files** both ways (folders as .zip), **clipboard** both ways (copy on the phone lands on the Mac by itself) and links.
- **Monitor**: battery, heat and link latency of the phone and the Mac, plus your other machines.

No developer options or USB debugging needed.

**Needs:** a Mac with Apple Silicon and an Android 11+ phone. The release was built and tested on macOS 27.3. Older versions down to macOS 14 are untested and may fail; if so, try building from source.

> **Tested on one setup only:** a Galaxy Z Fold7 (Android 17) with a MacBook on Apple Silicon. Other
> phones should work, but expect rough edges. Please open an issue if something breaks.

## Install

Download both files from the [latest release](https://github.com/Fini240/phonecast/releases/latest).

**Mac:**
1. Unzip `PhoneCast-mac-arm64.zip` and move `PhoneCast.app` to Applications.
2. The app isn't notarized by Apple, so macOS will block it at first. Allow it once in Terminal:

       xattr -dr com.apple.quarantine /Applications/PhoneCast.app

**Phone:**
1. Copy `PhoneCast.apk` to the phone and open it. Android will ask you to allow installing from that app.
   If **Google Play Protect** says "App blocked to protect your device" (with only a "Got it" button):
   Android blocks apps from outside the Play Store that ask for Accessibility access, which PhoneCast
   needs for mouse and keyboard. To install anyway, open the **Play Store** → your profile picture →
   **Play Protect** → ⚙️ → turn off **Scan apps with Play Protect**, install the APK, then turn scanning
   back on. Or install from a computer with USB debugging: `adb install PhoneCast.apk`.
2. Open PhoneCast and tap **Start sharing**. If the dialog offers it, choose **Share entire screen**.

## Connect

- **USB cable:** plug the phone into the Mac with a data cable and open PhoneCast on the Mac. Allow
  PhoneCast on the phone when it asks about the USB accessory.
- **Wi-Fi:** put both on the same trusted network, open PhoneCast on the Mac, pick the phone, and enter
  the PIN shown in the phone app.
- **Other networks:** the phone gets a new IP on every Wi-Fi, so the Mac doesn't rely on the saved one: it
  tries the phone it finds on the current network first, then the saved IP. Where the network keeps devices
  apart (some school or hotel Wi-Fi), install [Tailscale](https://tailscale.com) on both and enter the
  phone's Tailscale address in the Connect dialog (⌘K); PhoneCast falls back to it when nothing else answers.

## The PhoneCast window

The Mac app opens a window with a sidebar and keeps running in the menu bar (phone battery next to the
icon) after you close it. Turn on **Open PhoneCast at login** in Settings so it's always connected.

| Section | What it does |
|---|---|
| Overview | Phone and Mac battery, heat, CPU, memory, link latency; other machines (edit the list in Settings) |
| Mirror | Asks the phone to share its screen and opens the mirror window |
| Notifications | History of phone notifications; reply, clear, open on phone; right-click to silence an app |
| Messages | SMS conversations: read, reply, start new ones. WhatsApp/Signal/RCS chats are answered from Notifications |
| Calls | Call log, dial a number, answer/decline incoming calls (the call itself stays on the phone) |
| Contacts | Search, call, text |
| Photos | Photo and video grid; click for Quick Look, ⌘-click to select, save to Downloads |
| Files | Browse the phone's storage, Quick Look, download (folders as .zip), drop files to upload, delete |
| Apps | Opens an app on the phone and shows it in the mirror |
| Transfers | Drop files to send; list of everything sent and received |
| Settings | Pairing, banners, sound, quiet hours, per-app banners, clipboard, devices, Mac permissions |

**On the phone** (PhoneCast app → *Phone features on the Mac*): allow messages, calls, contacts and photos,
"All files access" for the file browser, and notification access. Sideloaded apps may first need
App info → ⋮ → **Allow restricted settings**.

- **Quick Settings tiles:** *Cast to Mac* (one tap to mirror; the Mac opens the window by itself) and
  *Clipboard to Mac*.
- **Copy on the phone → Mac clipboard automatically** (like LinkMyDroid): Android only lets the app in
  front read the clipboard, so when the Accessibility service sees a copy ("Copy" button, "Copied" toast,
  the clipboard preview), an invisible PhoneCast screen comes to the front for a moment, reads it and closes.
  Passwords marked sensitive are skipped. Turn it off in the phone app.
- **Share → "PhoneCast to Mac"** from any app: files go to `~/Downloads/PhoneCast`, text and links to the Mac's clipboard.
- **Control the Mac from this phone:** tap = click, drag = drag, long press or two-finger tap = right click,
  two fingers = scroll; the top bar has a keyboard, Esc, Tab, arrows and ⌘ ⌥ ⌃ ⇧. The Mac needs
  **Screen Recording** and **Accessibility** for PhoneCast (Settings shows both).

Banners are PhoneCast's own (top right), so reply and Answer/Decline work without macOS notification
permission. Mute them all, per app, or during quiet hours.

### The bar under the mirror

Back, Home, Recents, notifications, quick settings, volume, mute, lock, flashlight, open an app, send files,
send clipboard, typing mode, mouse aiming, key map, stats, screenshot to the Desktop and full screen. In a
narrow window the less used buttons move into **⋯** (which always lists everything, plus power menu,
split screen, phone screenshot, screen shape and quality). Full screen hides the bar.

## Mouse and keyboard

1. In the phone app, tap **Turn on mouse & keyboard** and enable PhoneCast in Accessibility settings.
2. If Android says "Restricted setting": App info → ⋮ → **Allow restricted settings**, then try again.

Normal controls: click or drag to touch, two-finger scroll to swipe, right-click or Esc for Back,
middle-click for Home. Typing goes into the focused text field.

### Games

1. **⌘E** opens the key map. Click a button on the phone screen, then press the key or mouse button for it.
   - Movement: click the middle of the joystick, then press W (scroll to resize).
   - Mouse look: ⌃-click the area you drag to look around.
   - ⌫ over a marker deletes it. Esc finishes.
2. **⌘G** starts mouse aiming, which captures the mouse. Esc leaves it. **⌘+ / ⌘−** change the speed.
3. For aiming without mouse acceleration, allow PhoneCast under System Settings → Privacy & Security →
   **Input Monitoring**, then reopen the app. Without it, PhoneCast falls back to accelerated mouse movement.

## Fitting your screen

- **⌘F** is full screen and covers the whole display, including the area around the notch.
- **⌘0** fits the window to the phone.

### Phone screen shape (optional)

The aspect-ratio toolbar button (also under Quality) changes the phone's screen shape to fit your Mac.
Android only allows this with a system permission, which has to be granted once from a computer. This
needs USB debugging for that one step and the [Android platform tools](https://developer.android.com/tools/releases/platform-tools):

    adb shell pm grant de.finn.phonecast android.permission.WRITE_SECURE_SETTINGS

It's a powerful permission, so skip this if you don't need the feature. "Phone's normal shape" in the
same menu undoes the change. Without the Mac, the phone app's **Screen shape** section has
**Back to normal shape** (for when you unplug) and **Fit the Mac again**. To remove the shape change from a computer: `adb shell wm size reset`.

**Sharpness:** the same menu can render the phone at more pixels than its screen has (Sharp = 2560 px wide, Sharpest = 3200 px), so the picture isn't blurry on a Retina display. Android allows up to 2× the panel. More pixels means more GPU work and heat; games may still draw their 3D world at a lower resolution (Fortnite: *3D Resolution* in its graphics settings).

## PC menu (streaming a PC)

The Mac app's **PC** menu opens Moonlight streams of the PC *my-pc* (Linux or Windows, dual boot).
Sunshine streams only one monitor, so each OS runs a second Sunshine for monitor 2: it shows up in
Moonlight as its own PC, "my-pc (<OS>) Monitor 2", on port 48089. The menu offers Monitor 1,
Monitor 2 or both side by side, and says which OS is running if you pick the other one.
`pc/linux-monitor2.sh` sets up the Linux side. On a phone, use the Moonlight app and pick the
"Monitor 2" PC for the second screen. Needs Moonlight in /Applications, paired with each host.
Away from home (the Mac isn't on 192.168.1.x) the menu streams at 1080p60 with 15 Mbit/s: over a phone
hotspot that measured ~45 ms and no lost frames, while the full home quality (~34 Mbit/s) gave 200 ms and
lost over half the frames. On the phone's Moonlight, set about 15–20 Mbit/s when you're on mobile data.

## Before you use it

- **Online games:** using a mouse and keyboard through injected touches may break a game's rules, and
  anti-cheat systems could flag it. **Your account could be penalised or banned.** This is untested,
  so use it at your own risk and check the game's terms first.
- **Encryption:** the link (notifications, messages, files, clipboard, Mac control) uses TLS 1.3 with a
  key that stays in the phone's keystore; the Mac pins it at the first pairing (compare the key shown in
  the phone app and in the Mac's Settings once). The mirror proves itself with a 256-bit key it received
  over that link, so the PIN isn't sent in the clear, and 5 wrong PINs lock both for 5 minutes.
  **The mirror's video and touches are not encrypted**, to keep game latency as low as possible: on the
  cable that's local anyway; away from home use Tailscale, which encrypts everything.
- **Wi-Fi (mirror):** someone on the same network could watch the unencrypted picture while you share.
  Use networks you trust (or the cable / Tailscale) and stop sharing when you're done.
- **Permissions & Play Protect:** the phone features ask for messages, calls, contacts, photos and all-files
  access. Together with Accessibility that makes Google Play Protect even stricter about a sideloaded APK
  (see Install). Only allow the features you use. The Mac keeps the PIN and keys in its app settings.
- **PC page:** only appears once you enter a Hermes dashboard address in
  Settings; it shows that PC's stats and passes on wake / sleep / boot / lights requests to the dashboard.
- **Accessibility access:** this permission lets PhoneCast tap and type on your phone, so only install
  builds you trust.

## Troubleshooting

**Touches stop working until a reboot:** Android can get stuck thinking a finger is still down. Rebooting
clears it. With USB debugging on, you can also read the stuck IDs and clear them with the included tool:

    adb shell dumpsys input | grep -A1 "Filter verifier"
    adb push tools/unstick/unstick.dex /data/local/tmp/
    adb shell CLASSPATH=/data/local/tmp/unstick.dex app_process / Unstick <ids>

**Reinstalled the app and input stopped:** turn its Accessibility service off and on again.

**Wi-Fi video over UDP:** on Wi-Fi the video goes over UDP like Moonlight/Parsec: lost pieces are rebuilt from repair data or re-sent within one round trip instead of stalling the whole stream (TCP). The title shows "Wi-Fi UDP" when it's active. It falls back to TCP by itself if UDP is blocked (firewall) or the network is very lossy. Taps, keys and audio stay on the reliable connection. The cable doesn't need it.

**Key maps per screen layout:** each phone screen size (inner/cover screen, shape, sharpness) keeps its own key map. A new layout starts from a copy of the last one; fix it with ⌘E by dragging the markers.

**Stats overlay:** ⌘O (View menu) shows FPS, delay, battery temperature/power, CPU/GPU temperature (on phones that allow reading it, e.g. Galaxy Z Fold7) and the phone's heat level in the top-left corner while you play. The game's own FPS can't be read without root.

**Lag:** the title bar shows FPS, delay and skipped video, and gaps are logged in
`~/Library/Logs/PhoneCast-lag.log`. A hot phone can also lower the frame rate.

## Build from source

Needs Xcode command line tools, [Homebrew](https://brew.sh) `libusb`, and Android Studio or a JDK with the Android SDK.

    brew install libusb
    mac/build.sh            # installs /Applications/PhoneCast.app (NO_INSTALL=1 only builds)

    cd android
    JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleRelease
    # android/app/build/outputs/apk/release/app-release.apk, signed with your debug key

An APK you build yourself has a different signature from the release, so uninstall the old one first.

## How it works

- `android/`: Kotlin phone app. Screen via MediaProjection and hardware H.264, audio via
  AudioPlaybackCapture, TCP on port 27183, Bonjour `_phonecast._tcp`, cable via Android Open Accessory.
  Touches come from an Accessibility service using continued-stroke gestures.
- The link (notifications, messages, files, monitor, Mac control) is a second, always-on TCP connection
  on port 27185 (`_phonecasthub._tcp`, same PIN): `HubService`, `NotifListener` and `Features` on the
  phone, `Hub.swift`/`Store.swift` on the Mac. It runs over Wi-Fi or Tailscale, not the cable.
- `mac/`: Swift/AppKit + SwiftUI app without an Xcode project. Uses VideoToolbox, ScreenCaptureKit, AVAudioEngine, libusb and raw HID mouse input.
- `tools/`: `touchtest.py` drives the input service over TCP, `unstick` clears stuck pointers.

## License

MIT, see [LICENSE](LICENSE). Third-party: the Mac app statically links
[libusb](https://libusb.info) (LGPL-2.1, rebuild against your own copy with `mac/build.sh`), and the phone app
uses [AndroidHiddenApiBypass](https://github.com/LSPosed/AndroidHiddenApiBypass) (Apache-2.0).
