#!/bin/sh
# Builds build/ClaudeClip.app (menu bar only, no Dock icon) and runs the self-test.
set -e
cd "$(dirname "$0")"
APP=build/ClaudeClip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.claudeclip</string>
  <key>CFBundleName</key><string>ClaudeClip</string>
  <key>CFBundleExecutable</key><string>ClaudeClip</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
swiftc -O -swift-version 5 -target arm64-apple-macos13 main.swift -o "$APP/Contents/MacOS/ClaudeClip"
"$APP/Contents/MacOS/ClaudeClip" --selftest
codesign --force -s - "$APP"
echo "Built $APP"
