#!/bin/zsh
# Build + install the phone app, re-enable the accessibility service, restart sharing (USB debugging on).
set -e
cd "${0:A:h}/../android"
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew -q assembleRelease 2>&1 | grep -E "^e:" && exit 1
adb install -r app/build/outputs/apk/release/app-release.apk | tail -1
S=$(adb shell settings get secure enabled_accessibility_services)
adb shell settings put secure enabled_accessibility_services "${S/de.finn.phonecast\/de.finn.phonecast.InputService:/}"
sleep 1; adb shell settings put secure enabled_accessibility_services "$S"
adb shell am start -n de.finn.phonecast/.MainActivity >/dev/null; sleep 5
tap() { # tap the centre of the first node whose text is $1
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null
  local b=$(adb shell cat /sdcard/ui.xml | grep -oE "text=\"$1\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" | head -1 | grep -oE '[0-9]+' | tail -4 | tr '\n' ' ')
  [[ -z "$b" ]] && { echo "not found: $1"; return 1; }
  local a=(${=b}); adb shell input tap $(( (a[1]+a[3])/2 )) $(( (a[2]+a[4])/2 )); sleep 2
}
tap "Start sharing"; tap "Share one app"; tap "Share entire screen"; tap "Share screen"
adb shell dumpsys activity services de.finn.phonecast | grep -c ServiceRecord
