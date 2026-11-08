# PhoneCast

Shows an Android phone on your Mac and controls it with the Mac's mouse and keyboard. It works over
a USB cable or Wi-Fi, without developer options or USB debugging, and plays the phone's audio on the Mac.

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

## Before you use it

- **Online games:** using a mouse and keyboard through injected touches may break a game's rules, and
  anti-cheat systems could flag it. **Your account could be penalised or banned.** This is untested,
  so use it at your own risk and check the game's terms first.
- **Wi-Fi security:** the stream isn't encrypted, and anyone on the network who gets the 6-digit PIN can
  see and control the phone. There is no limit on PIN attempts. Use only on networks you trust,
  or use the cable. Stop sharing when you're done.
- **Accessibility access:** this permission lets PhoneCast tap and type on your phone, so only install
  builds you trust.

## Troubleshooting

**Touches stop working until a reboot:** Android can get stuck thinking a finger is still down. Rebooting
clears it. With USB debugging on, you can also read the stuck IDs and clear them with the included tool:

    adb shell dumpsys input | grep -A1 "Filter verifier"
    adb push tools/unstick/unstick.dex /data/local/tmp/
    adb shell CLASSPATH=/data/local/tmp/unstick.dex app_process / Unstick <ids>

**Reinstalled the app and input stopped:** turn its Accessibility service off and on again.

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
- `mac/`: Swift/AppKit viewer without an Xcode project. Uses VideoToolbox, AVAudioEngine, libusb and raw HID mouse input.
- `tools/`: `touchtest.py` drives the input service over TCP, `unstick` clears stuck pointers.

## License

MIT, see [LICENSE](LICENSE). Third-party: the Mac app statically links
[libusb](https://libusb.info) (LGPL-2.1, rebuild against your own copy with `mac/build.sh`), and the phone app
uses [AndroidHiddenApiBypass](https://github.com/LSPosed/AndroidHiddenApiBypass) (Apache-2.0).
