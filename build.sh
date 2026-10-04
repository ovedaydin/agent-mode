#!/bin/zsh
# Builds "Agent Mode.app" into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Agent Mode.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/AgentMode" Sources/AgentMode.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Agent Mode</string>
    <key>CFBundleDisplayName</key><string>Agent Mode</string>
    <key>CFBundleIdentifier</key><string>io.github.ovedaydin.agentmode</string>
    <key>CFBundleExecutable</key><string>AgentMode</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x AgentMode 2>/dev/null || true
    rm -rf "/Applications/Agent Mode.app"
    cp -R "$APP" /Applications/
    open "/Applications/Agent Mode.app"
    echo "Installed to /Applications and launched"
fi
