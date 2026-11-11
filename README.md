# PhoneCast

Connects an Android phone and a Mac, similar to LinkMyDroid or Phone Link:

- **Mirror** the phone on the Mac and control it with mouse and keyboard (USB cable or Wi-Fi, with sound),
  and **control the Mac from the phone**.
- **Notifications** from the phone as Mac banners, with reply, clear and open-on-phone.
- **Messages (SMS, and MMS pictures), calls, contacts, photos, phone files and apps** in one Mac window.
- **Files** both ways (folders as .zip), **clipboard** both ways, text and pictures (copy on the phone lands on
  the Mac by itself), and links (a link shared from the phone opens in the Mac's browser).
- **Monitor**: battery, heat and link latency of the phone and the Mac, plus your other machines.
- **Now playing**: the phone's music or video with play/pause and skip, in the menu bar and on Overview.
- **Find my phone**: rings the phone at full volume, even on silent, or shows where it is in Maps.
- **Browser tab to the phone**: the page open in Safari, Chrome, Arc, Brave or Edge opens on the phone (menu bar,
  Overview, or from the phone's Mac tab).
- **Mac Shortcuts on the phone**: your Shortcuts from the Mac's Shortcuts app as buttons on the phone's Mac tab.
- **Drop an app on the mirror**: an `.apk` dropped on the phone's picture opens Android's installer.
- **Dim while shown**: the phone goes dark while the Mac shows it (battery, heat, privacy); the Mac's picture stays bright.
- **Game controllers**: an Xbox, PlayStation or Switch Pro controller on the Mac plays phone games.
- **New screenshots** on the phone land on the Mac (Downloads and clipboard) by themselves.
- **Record the mirror** to a video (⇧⌘R or the record button under the mirror), saved in Movies/PhoneCast.
- **Phone as trackpad & keyboard** for the Mac, without video (saves battery).
- **Do Not Disturb**: when the phone is on Do Not Disturb, the Mac stays quiet too; switch it from the menu bar.
- **Lock the Mac when the phone leaves** (optional, only when nobody is using the Mac).
- **Updates in the app**: "Install update" on the Mac and the phone, Help → Check for updates on Windows.
- **AI agents**: your Claude Code and Codex chats on the Mac in an Agents tab on the phone (and an
  Agents page on the Mac): reply (it interrupts a running turn, like typing in the terminal), send photos,
  stop, answer permission questions, start new chats with the models your CLIs offer, and get notified when
  an agent is done, fails or needs you, with reply and approve right in the notification.
- **Windows too**: the Windows app mirrors and links (notifications, clipboard, files, now playing, ring);
  the phone can be linked to a Mac and a PC at the same time.
- **English and German**: the apps follow the device's language.
- **The app icon shows the link**: the little phone's screen is lit while the phone and the computer are
  connected, dark when not (Mac Dock and menu bar, Android home screen, Windows taskbar).

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

**Windows (x64):** unzip `PhoneCast-windows-x64.zip` anywhere and start `PhoneCast.exe`. See
[windows/README.md](windows/README.md) for the cable (USB tethering) and the Ctrl shortcuts.

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
- **Pair once with a QR code (recommended):** the Mac (PhoneCast → Settings) or Windows PC (Device →
  Pair with QR code, Ctrl+P) shows a QR code; on the phone open PhoneCast → Settings → **Scan computer's
  QR code**. No PIN afterwards: on every connection the computer and the phone prove to each other that
  they know the code's secret, so nobody can pretend to be either of them. Remove computers in the
  phone's Settings.
- **Wi-Fi:** put both on the same trusted network, open PhoneCast on the Mac, pick the phone, and (if
  you didn't pair with the QR code) enter the PIN shown in the phone app.
- **Other networks:** the phone gets a new IP on every Wi-Fi, so the Mac doesn't rely on the saved one: it
  tries the phone it finds on the current network first, then the saved IP. Where the network keeps devices
  apart (some school or hotel Wi-Fi), install [Tailscale](https://tailscale.com) on both and enter the
  phone's Tailscale address in the Connect dialog (⌘K); PhoneCast falls back to it when nothing else answers.

## The PhoneCast window

The Mac app opens a window with a sidebar and keeps running in the menu bar (phone battery next to the
icon) after you close it. Turn on **Open PhoneCast at login** in Settings so it's always connected.

| Section | What it does |
|---|---|
| Overview | Phone and Mac battery, heat, CPU, memory, link latency; now playing; **Find phone**; other machines (edit the list in Settings) |
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
- **Share → "PhoneCast to Mac"** from any app: files go to `~/Downloads/PhoneCast`, web links open in the
  Mac's browser, other text goes to the Mac's clipboard.
- **New screenshots** go to the Mac by themselves (`~/Downloads/PhoneCast` and the clipboard, ready to paste).
  Turn it off in the phone app → Settings.
- **Menu bar:** what the phone is playing with ⏮ ⏯ ⏭, and **Ring phone** to find it (it rings on silent too;
  stop it from the Mac or the phone's notification; it stops by itself after a minute).
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

Normal controls: click or drag to touch, two-finger scroll to swipe, pinch on the trackpad to zoom,
right-click or Esc for Back, middle-click for Home. Typing goes into the focused text field.
**⌘[ / ⌘]** turn the picture (an app stuck in portrait, a video on its side) without turning the phone.

### Games

1. **⌘E** opens the key map. Click a button on the phone screen, then press the key or mouse button for it.
   - Movement: click the middle of the joystick, then press W (scroll to resize).
   - Mouse look: ⌃-click the area you drag to look around.
   - ⌫ over a marker deletes it. Esc finishes.
   - **⌥T** over a marker makes it a **turbo** key: while held it taps 8 times a second, ⌥T again 15, then off.
   - **Game → Export / Import key map** saves the map as a `.phonecast-keys.json` file to share or keep; an
     imported map keeps your own mouse speed. Positions are fractions of the screen, so check them with ⌘E.
2. **⌘G** starts mouse aiming, which captures the mouse. Esc leaves it. **⌘+ / ⌘−** change the speed.
3. For aiming without mouse acceleration, allow PhoneCast under System Settings → Privacy & Security →
   **Input Monitoring**, then reopen the app. Without it, PhoneCast falls back to accelerated mouse movement.

**Game controller** (Xbox, PlayStation, Switch Pro, any MFi controller connected to the Mac): the left stick
is the movement joystick (half a push = walk), the right stick looks around (needs the look area), and
buttons, triggers and the d-pad are bound like keys: in the key map (⌘E) click a spot, then press the
controller button (purple markers). With a spot picked, pushing a stick sets the joystick or the look area
there. The controller works while PhoneCast is the front app.

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

## PC menu (streaming a dual-boot PC)

The Mac app can open Moonlight streams of a PC that runs Sunshine on Linux and Windows (dual boot).
Nothing is built in; set the PC up in Terminal, and the menu (named after the PC) appears:

    defaults write de.finn.phonecast.mac pcName "my-pc"
    defaults write de.finn.phonecast.mac pcLinuxAddress 100.64.0.20
    defaults write de.finn.phonecast.mac pcWindowsAddress 100.64.0.21
    defaults write de.finn.phonecast.mac homeNetworkPrefix "192.168.1."   # optional

`pcName` is the Sunshine name without " (Linux)" / " (Windows)". Use Tailscale addresses so it also works
away from home. Sunshine streams only one monitor, so each OS runs a second Sunshine for monitor 2: it
shows up in Moonlight as its own PC, "<pcName> (<OS>) Monitor 2", on port 48089. The menu offers
Monitor 1, Monitor 2 or both side by side, and says which OS is running if you pick the other one.
`pc-stream/linux-monitor2.sh` sets up the Linux side. On a phone, use the Moonlight app and pick the
"Monitor 2" PC for the second screen. Needs Moonlight in /Applications, paired with each host.
When `homeNetworkPrefix` is set and the Mac isn't on that network, the menu streams at 1080p60 with
15 Mbit/s: over a phone hotspot that measured ~45 ms and no lost frames, while full quality
(~34 Mbit/s) gave 200 ms and lost over half the frames. On the phone's Moonlight, set about
15–20 Mbit/s when you're on mobile data.

## Agents (Claude Code and Codex)

The Mac app watches the Claude Code and Codex chats on the Mac (read-only: their transcripts in
`~/.claude` and `~/.codex`, and Codex's local status socket) and shows them on the phone's **Agents** tab,
with subagents grouped under their chat. Everything goes over the PhoneCast link, so it works wherever the
link works (Wi-Fi, Tailscale); there is no server and no cloud push.

To answer a chat from the phone, it has to run in a terminal PhoneCast can type into. Turn on
**Agents → Terminal integration** on the Mac: it adds a small block to `~/.zshrc`, and from then on
`claude` and `codex` in a new terminal open inside a private tmux session
(`~/.phonecast/agents/tmux.sock`, needs `brew install tmux`). The terminal looks and works as before;
the phone sees the same session. Other commands (`claude -p`, `codex exec`, `--version`…) are untouched.
Bypass once with `PHONECAST_AGENTS_OFF=1 claude` or `command claude`.

- **Reply**: waits until the prompt is ready; if the agent is working, it presses Esc once to stop the
  current turn first (never Ctrl-C), then pastes your text and confirms it was sent.
- **Finished chats** are reopened on the Mac (`claude --resume` / `codex resume`) when you reply.
- **Questions** (permissions, trust folder…) show as buttons in the chat and in the notification.
- **Voice**: the microphone button dictates (when the message field is empty). **Read answers aloud** per chat
  (⋯ in the chat), or **Read finished answers aloud** for all chats (⋯ in the Agents list) for hands-free use.
- **Changes**: the ⇅ button shows what the agent changed in the chat's git repository, with a diff per file,
  and Commit, Push, Pull and Create pull request (needs the GitHub CLI `gh` on the Mac), or "Let the agent commit".
- **Commands** (the / button): switch model and effort, cycle Claude's permission mode (the chip under the title:
  ask before edits → auto-accept edits → plan mode), compact, clear, `/usage`, `/context`, or any other command.
- **Usage**: context used, tokens in and out, and, after turning on **Cost & plan limits** (⋯ in the Agents list),
  the chat's cost and your 5-hour / 7-day plan limits. PhoneCast wraps your Claude statusline for this; it keeps
  showing the same thing, and `~/.claude/settings.json` is backed up first. Codex reports its limits by itself.
  Tap the line for details and a **budget** per chat (dollars or tokens), with a notification or an automatic stop.
- **Usage left**: the top of the Agents tab shows how much of each plan window is left (Claude's 5 hours and
  7 days, Codex's limit) and when it resets; the widget shows Claude's 5-hour figure too. With several Claude
  accounts, each gets its own block, labelled with the chats that use it (chats of one account share its weekly
  reset time). Each chat's own usage line always shows the limits of the account that chat runs on.
- **Live terminal**: the terminal button shows the agent's screen with its colours, live; what you type there goes
  in as keystrokes, with keys for arrows, Enter, Esc, Tab, Backspace and Ctrl-C.
- **Files**: browse and read the project's files (⋯ → Files); type `@` in a message for file suggestions; attach any
  file (not just photos), it lands on the Mac and the agent gets its path.
- **Own worktree**: a new chat can start in its own git worktree (a new `agent/…` branch in
  `<repo>-worktrees/`), so several agents can work on one project without touching the same files.
- **Fork** a chat (a copy that continues on its own), **rename** a Claude chat, **share** a chat as Markdown.
- **Recovery**: when a chat stops at a usage limit, PhoneCast can send "continue" a minute after the limit resets
  (all chats or per chat), and it tells you when an agent seems stuck (no progress for 10 minutes, adjustable).
- **Offline**: messages written while the Mac is away wait on the phone and go out when it's back.
- **More agents**: Gemini CLI, OpenCode and Kimi run the same way (started from the phone or a terminal: `gemini`,
  `opencode`); their chat is the live terminal.
- **Dev servers**: ⋯ → Open dev server opens a server the agent started on the Mac (localhost) in the phone's browser.
  PhoneCast forwards just that port, only to your phone, for an hour.
- **Other machines**: add SSH targets (`user@host`, key login from the Mac, tmux and the agent installed there) in
  ⋯ → Other machines on the phone or the server button on the Mac. New chats can then start there; they show in
  the same list and open in the live terminal.
  While an agent there works, PhoneCast keeps that machine from going to sleep (Linux: `systemd-inhibit`; your
  user may need a polkit rule allowing `org.freedesktop.login1.inhibit-block-sleep` over SSH).
- **Live status**: an ongoing notification while agents work (Android 16 shows it as a live update), an **Agents**
  Quick Settings tile and a home-screen **widget**.
- **`pa`** in a terminal lists the running sessions and attaches to one; `pa notify "title" "text"` from
  inside a session sends a phone notification.
- While an agent works, the Mac doesn't go to sleep (the display still may).

Chats started outside the integration (another terminal, an IDE) are shown read-only.

### Agents in a browser (iPad, school laptop, any computer)

No app needed: the Mac serves the same Agents screens on port 27190. Open `http://<the Mac's address>:27190`
(shown at the top of the Mac's Agents page) on a device on the same Wi-Fi or on Tailscale and sign in once with
the 6-digit code shown there (also in `~/.phonecast/agents/web-code`). Everything works there too: replies,
questions, live terminal, changes and git, files, commands, usage and budgets, new chats, other machines. The Mac's
own Agents page is the same view. Only home-network and Tailscale addresses are served; wrong codes lock sign-in
for five minutes; "Sign out all browsers" on the Mac revokes every sign-in.

## Before you use it

- **Online games:** using a mouse and keyboard through injected touches may break a game's rules, and
  anti-cheat systems could flag it. **Your account could be penalised or banned.** This is untested,
  so use it at your own risk and check the game's terms first.
- **Encryption:** the link (notifications, messages, files, clipboard, Mac control) uses TLS 1.3 with a
  key that stays in the phone's keystore. With QR pairing the Mac checks that key by itself (both sides
  prove the code's secret, bound to that key); with the PIN, compare the key shown in the phone app and in
  the Mac's Settings once. Failed QR logins don't use up the PIN tries. The mirror proves itself with a 256-bit key it received
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
  Since 0.3.1 it also has the dashboard's own Chat, Builder and Studio pages as tabs (phone and Mac), drawn
  in PhoneCast's colours. They need a dashboard with the `?embed=` views (hermes-dashboard 5eaabc3 or newer).
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
