#!/bin/sh
# Build universal release binaries and wrap the SwiftUI executable in a minimal .app bundle.
# Works with the Command Line Tools alone.
set -eu
cd "$(dirname "$0")/.."

VERSION="1.0.1"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

DIST="dist"
APP="$DIST/CayoteLink.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CayoteLinkApp" "$APP/Contents/MacOS/CayoteLink"
cp "$BIN/cayote" "$DIST/cayote"
ICON_KEY=""
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CayoteLink</string>
    <key>CFBundleDisplayName</key><string>CayoteLink</string>
    <key>CFBundleIdentifier</key><string>io.github.trelaf.CayoteLink</string>
    <key>CFBundleExecutable</key><string>CayoteLink</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>2</string>
    $ICON_KEY
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Cayote firmware</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key><array><string>grp</string><string>7z</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

touch "$APP"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: codesign failed; the app may still run"
codesign --force --sign - "$DIST/cayote" >/dev/null 2>&1 || true

echo "Built $APP and $DIST/cayote"
