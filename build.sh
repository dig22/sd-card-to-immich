#!/bin/bash
# Builds "SD to Immich.app" (universal: Apple Silicon + Intel) into build/.
# Needs Xcode or the Command Line Tools (swiftc). Usage: ./build.sh [version]
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"
APP="build/SD to Immich.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" \
    -o "build/obj/SDToImmich-$arch" App/Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/SDToImmich" build/obj/SDToImmich-arm64 build/obj/SDToImmich-x86_64

sed "s/__VERSION__/$VERSION/g" App/Info.plist > "$APP/Contents/Info.plist"
cp sd2immich.py "$APP/Contents/Resources/"

# Icon: render once, then build the .icns from it.
ICONSET=build/AppIcon.iconset && mkdir -p "$ICONSET"
swift tools/make-icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"   # ad-hoc signature (no Apple developer ID)
(cd build && ditto -c -k --keepParent "SD to Immich.app" "SD-to-Immich-$VERSION.zip")
echo "Built $APP and build/SD-to-Immich-$VERSION.zip"
