#!/bin/zsh
# Builds Whisperly.app from the Swift package.
set -e
cd "$(dirname "$0")"

echo "Building (release)…"
swift build -c release

APP="Whisperly.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Whisperly "$APP/Contents/MacOS/Whisperly"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Whisperly</string>
    <key>CFBundleDisplayName</key>
    <string>Whisperly</string>
    <key>CFBundleIdentifier</key>
    <string>com.ryangiang.whisperly</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>Whisperly</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Whisperly records your voice while you hold the Fn key so it can transcribe it on-device.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Code signing. A stable identity lets macOS keep the Microphone and
# Accessibility grants across rebuilds. Set one with WHISPERLY_SIGN_IDENTITY
# or put its name in a .signing-identity file; otherwise sign ad-hoc
# (works fine, but you'll re-grant permissions after each rebuild).
SIGN_ID="${WHISPERLY_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" && -f .signing-identity ]]; then
    SIGN_ID="$(head -n1 .signing-identity)"
fi
codesign --force --deep --sign "${SIGN_ID:--}" "$APP"

# Install into /Applications (replacing any older copy) and drop the local build.
pkill -x Whisperly 2>/dev/null || true
rm -rf "/Applications/$APP"
ditto "$APP" "/Applications/$APP"
rm -rf "$APP"

echo "Done: /Applications/$APP"
echo "Open with: open /Applications/$APP"
