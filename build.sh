#!/bin/zsh
# Builds "Agent Mode.app" into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Agent Mode.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

VERSION="${VERSION:-1.2}"

# Universal binary: Apple Silicon + Intel
TMP="build/obj"
mkdir -p "$TMP"
for ARCH in arm64 x86_64; do
    swiftc -O -target "$ARCH-apple-macos13.0" -o "$TMP/AgentMode-$ARCH" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/AgentMode" "$TMP/AgentMode-arm64" "$TMP/AgentMode-x86_64"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Agent Mode</string>
    <key>CFBundleDisplayName</key><string>Agent Mode</string>
    <key>CFBundleIdentifier</key><string>io.github.ovedaydin.agentmode</string>
    <key>CFBundleExecutable</key><string>AgentMode</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
(cd build && rm -f Agent-Mode.zip && ditto -c -k --keepParent "Agent Mode.app" Agent-Mode.zip)

# Drag-to-install disk image
DMG_STAGE="build/dmg"
rm -rf "$DMG_STAGE" build/Agent-Mode.dmg
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "Agent Mode" -srcfolder "$DMG_STAGE" -ov -format UDZO build/Agent-Mode.dmg
rm -rf "$DMG_STAGE"
echo "Built $APP (v$VERSION), build/Agent-Mode.zip and build/Agent-Mode.dmg"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x AgentMode 2>/dev/null || true
    rm -rf "/Applications/Agent Mode.app"
    cp -R "$APP" /Applications/
    open "/Applications/Agent Mode.app"
    echo "Installed to /Applications and launched"
fi
