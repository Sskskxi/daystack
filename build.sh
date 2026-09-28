#!/bin/bash
# Usage: ./build.sh            build build/DayStack.app and the installer build/DayStack.dmg
#        ./build.sh --publish  also copy both into the shared iCloud group folder (Update button + installer for new friends)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(tr -d '[:space:]' < VERSION)

swift build -c release

APP=build/DayStack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/DayStack "$APP/Contents/MacOS/DayStack"
cp .build/release/daystack-mcp "$APP/Contents/MacOS/daystack-mcp"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DayStack</string>
    <key>CFBundleIdentifier</key><string>com.seokhoon.daystack</string>
    <key>CFBundleExecutable</key><string>DayStack</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSRemindersUsageDescription</key><string>DayStack syncs your to-dos with a "DayStack" list in Reminders.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>DayStack syncs your to-dos with a "DayStack" list in Reminders.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP/Contents/MacOS/daystack-mcp"
codesign --force --sign - "$APP"
echo "Built $APP (v$VERSION)"

DMG=build/DayStack.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to install.txt" <<'EOF'
How to install DayStack

1. Drag DayStack onto the Applications folder in this window.
2. Open your Applications folder and double-click DayStack.
3. If macOS says it can't verify the app:
   open System Settings → Privacy & Security, scroll down,
   click "Open Anyway" next to DayStack, and confirm.
   (You only need to do this once.)
4. Look for the calendar icon in the menu bar at the top-right of your screen.
5. To join your friends: click the icon → the people button → enter the invite code.

Tip: to skip step 3 entirely, install from Terminal instead:
   curl -fsSL https://raw.githubusercontent.com/Sskskxi/toy-calendar/main/install.sh | bash
EOF
hdiutil create -quiet -volname "DayStack" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Built $DMG"

if [[ "${1:-}" == "--publish" ]]; then
    GROUP=$(defaults read com.seokhoon.daystack groupPath 2>/dev/null) || {
        echo "No group yet: create or join a group in the app first." >&2
        exit 1
    }
    mkdir -p "$GROUP/updates"
    rm -f "$GROUP/updates/DayStack.zip"
    ditto -c -k --keepParent "$APP" "$GROUP/updates/DayStack.zip"
    # Written last so friends never see a version whose zip isn't there yet.
    printf '{"version":"%s"}\n' "$VERSION" > "$GROUP/updates/version.json"
    cp "$DMG" "$GROUP/Install DayStack.dmg"
    echo "Published v$VERSION to $GROUP (updates/ and Install DayStack.dmg)"
fi
