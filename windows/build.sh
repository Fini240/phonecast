#!/bin/bash
# Builds PhoneCast for Windows (x64) from macOS/Linux/Windows with the .NET 8+ SDK.
# Downloads the native parts once into deps/: FFmpeg 9.0 LGPL (H.264 decoding), SDL2 (window,
# rendering, audio), libusb (experimental accessory cable mode). Output: windows/out/.
set -euo pipefail
cd "$(dirname "$0")"
DOTNET=${DOTNET:-$(command -v dotnet || echo ~/.dotnet/dotnet)}
mkdir -p deps/dl
fetch() { [ -f "deps/dl/$2" ] || gh release download "$3" -R "$1" -p "$2" -D deps/dl; }
if [ ! -f deps/avcodec-63.dll ]; then
  fetch BtbN/FFmpeg-Builds ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip latest
  unzip -q -o deps/dl/ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip -d deps/dl/ff
  cp deps/dl/ff/*/bin/{avcodec-63,avutil-61,swresample-7}.dll deps/
fi
if [ ! -f deps/SDL2.dll ]; then
  fetch libsdl-org/SDL SDL2-2.32.10-win32-x64.zip release-2.32.10
  unzip -q -o deps/dl/SDL2-2.32.10-win32-x64.zip -d deps/dl/sdl && cp deps/dl/sdl/SDL2.dll deps/
fi
if [ ! -f deps/libusb-1.0.dll ]; then
  fetch libusb/libusb libusb-1.0.30.7z v1.0.30
  mkdir -p deps/dl/usb && bsdtar -xf deps/dl/libusb-1.0.30.7z -C deps/dl/usb && cp deps/dl/usb/VS2022/MS64/dll/libusb-1.0.dll deps/
fi
rm -rf out
"$DOTNET" publish PhoneCast -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -o out -v q
rm -f out/*.pdb
echo "built: $(pwd)/out"
