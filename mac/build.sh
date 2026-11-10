#!/bin/zsh
# Builds PhoneCast.app and installs it to /Applications.
#   PHONECAST_SIGN_ID=<identity>  code-signing identity; otherwise the one in mac/.sign-id (gitignored,
#                                 keeps macOS permissions across rebuilds), otherwise ad-hoc signing
#   NO_INSTALL=1                  only build, into mac/build/
set -e
cd "$(dirname "$0")"
LIBUSB=$(brew --prefix libusb 2>/dev/null) || { echo "Needs libusb: brew install libusb"; exit 1; }
APP=build/PhoneCast.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Shim/shim.h -Xcc -I"$LIBUSB/include/libusb-1.0" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework Network \
  -framework IOKit -framework CoreFoundation -framework Security \
  -framework ScreenCaptureKit -framework VideoToolbox -framework UserNotifications -framework ServiceManagement -framework Carbon -framework SwiftUI -framework Quartz -framework Combine -framework GameController -framework WebKit \
  "$LIBUSB/lib/libusb-1.0.a" \
  Sources/*.swift -o "$APP/Contents/MacOS/PhoneCast"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Resources/ "$APP/Contents/Resources/"   # icons: AppIcon.icns, Dock on/off, menu bar glyph
SIGN_ID=${PHONECAST_SIGN_ID:-$(cat .sign-id 2>/dev/null)}
codesign --force --deep -s "${SIGN_ID:--}" "$APP" 2>/dev/null || codesign --force --deep -s - "$APP"
if [ -n "$NO_INSTALL" ]; then echo "Built $APP"; exit 0; fi
rm -rf /Applications/PhoneCast.app
cp -R "$APP" /Applications/
echo "Installed /Applications/PhoneCast.app"
