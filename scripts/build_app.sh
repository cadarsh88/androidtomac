#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "Building release binary with SwiftPM..."
swift build -c release --product AndroidToMacApp

APP_BUNDLE="AndroidToMac.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

cp ".build/release/AndroidToMacApp" "$MACOS/AndroidToMacApp"
chmod +x "$MACOS/AndroidToMacApp"

cat << 'EOF' > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AndroidToMacApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.cadarsh88.androidtomac</string>
    <key>CFBundleName</key>
    <string>Android to Mac</string>
    <key>CFBundleDisplayName</key>
    <string>Android to Mac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Android to Mac needs local network access to discover and receive files from nearby Android devices via Quick Share.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_FC9F5ED42C8A._tcp</string>
    </array>
</dict>
</plist>
EOF

echo "APPL????" > "$CONTENTS/PkgInfo"

# Ad-hoc code sign the bundle with local network entitlements
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Successfully built $APP_BUNDLE!"
echo "To run: open AndroidToMac.app"
