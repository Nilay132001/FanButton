#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
rm -rf FanButton.app
mkdir -p FanButton.app/Contents/MacOS FanButton.app/Contents/Resources
swiftc -O -parse-as-library *.swift -o FanButton.app/Contents/MacOS/FanButton

iconset="$(mktemp -d)/AppIcon.iconset"
swift tools/make-icon.swift "$iconset"
iconutil -c icns "$iconset" -o FanButton.app/Contents/Resources/AppIcon.icns

cat > FanButton.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.fanbutton</string>
<key>CFBundleName</key><string>FanButton</string>
<key>CFBundleDisplayName</key><string>FanButton</string>
<key>CFBundleExecutable</key><string>FanButton</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Copy into Applications so Spotlight and Launchpad can find it after you quit.
rm -rf /Applications/FanButton.app
cp -R FanButton.app /Applications/
echo "Installed FanButton in Applications. Open it from Spotlight, Launchpad or Finder."
