#!/bin/zsh
# Builds PhoneCast.app and installs it to /Applications.
#   PHONECAST_SIGN_ID=<identity>  code-signing identity (falls back to ad-hoc signing)
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
  "$LIBUSB/lib/libusb-1.0.a" \
  Sources/*.swift -o "$APP/Contents/MacOS/PhoneCast"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep -s "${PHONECAST_SIGN_ID:-My Signing Cert}" "$APP" 2>/dev/null || codesign --force --deep -s - "$APP"
if [ -n "$NO_INSTALL" ]; then echo "Built $APP"; exit 0; fi
rm -rf /Applications/PhoneCast.app
cp -R "$APP" /Applications/
echo "Installed /Applications/PhoneCast.app"
