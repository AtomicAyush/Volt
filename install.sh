#!/bin/bash
# Build Volt and install it to /Applications.
#
# The app is signed with a real Apple Development certificate rather than ad-hoc.
# That matters: macOS records Bluetooth permission against the code signature, and an
# ad-hoc signature gets a fresh hash on every build, so each rebuild looks like a brand
# new app and macOS asks for Bluetooth access again. A stable identity is granted once.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Prefer a real identity; fall back to ad-hoc so the script still works without one.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | awk '{print $2}')
if [ -z "$IDENTITY" ]; then
    echo "No Apple Development certificate found — signing ad-hoc."
    echo "macOS will ask for Bluetooth access again after each rebuild."
    IDENTITY="-"
fi

echo "Building…"
xcodebuild -project Volt.xcodeproj -scheme Volt -configuration Release build \
    -quiet CODE_SIGNING_ALLOWED=NO

APP=$(xcodebuild -project Volt.xcodeproj -scheme Volt -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Volt.app

echo "Signing with ${IDENTITY}…"
# The helper first, under its own identifier. --deep on the app would re-sign it
# under its file name, which the app's check on the helper would then reject.
if [ -f "$APP/Contents/MacOS/VoltHelper" ]; then
    codesign --force --sign "$IDENTITY" -i com.ayush.Volt.helper --options runtime \
        "$APP/Contents/MacOS/VoltHelper"
fi
codesign --force --sign "$IDENTITY" "$APP"

pkill -x Volt 2>/dev/null || true
sleep 1
rm -rf /Applications/Volt.app
cp -R "$APP" /Applications/

echo "Launching…"
open /Applications/Volt.app
codesign -dv --verbose=2 /Applications/Volt.app 2>&1 | grep -E "Authority|Signature|TeamIdentifier" || true
