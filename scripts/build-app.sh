#!/bin/zsh
# Builds Stechuhr.app (release) into ./dist and optionally installs it to /Applications.
#   scripts/build-app.sh            -> dist/Stechuhr.app
#   scripts/build-app.sh --install  -> additionally copies to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Stechuhr
swift build -c release --product stechuhr-hook
BIN=$(swift build -c release --show-bin-path)

APP=dist/Stechuhr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Stechuhr" "$APP/Contents/MacOS/Stechuhr"
cp "$BIN/stechuhr-hook" "$APP/Contents/Resources/stechuhr-hook"

# App icon from Resources/AppIcon-1024.png (regenerate with: swift scripts/make-icon.swift Resources/AppIcon-1024.png)
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Stechuhr</string>
  <key>CFBundleDisplayName</key><string>Stechuhr</string>
  <key>CFBundleIdentifier</key><string>local.stechuhr</string>
  <key>CFBundleExecutable</key><string>Stechuhr</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>NSAppleEventsUsageDescription</key><string>Stechuhr liest URL und Titel des aktiven Browser-Tabs, um Zeit nach Domain und Seite zuordnen zu können. Die Daten bleiben auf diesem Mac.</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Gebaut: $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Stechuhr 2>/dev/null || true
  rm -rf /Applications/Stechuhr.app
  cp -R "$APP" /Applications/Stechuhr.app
  echo "Installiert: /Applications/Stechuhr.app"
fi
