#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p FanButton.app/Contents/MacOS
swiftc -O FanButton.swift -o FanButton.app/Contents/MacOS/FanButton
cat > FanButton.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.fanbutton</string>
<key>CFBundleName</key><string>FanButton</string>
<key>CFBundleExecutable</key><string>FanButton</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
echo "Built FanButton.app. Open it to see the fan icon in the menu bar."
