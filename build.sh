#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p 'parvanak.app/Contents/MacOS'
mkdir -p .build/module-cache
parvanak_cache_path="$(cd .build/module-cache && pwd -P)"
xcrun swiftc -module-cache-path "$parvanak_cache_path" -swift-version 5 -O -framework AppKit -framework IOKit sources/main.swift -o 'parvanak.app/Contents/MacOS/parvanak'
cat > 'parvanak.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>parvanak</string>
<key>CFBundleIdentifier</key><string>local.parvanak</string>
<key>CFBundleName</key><string>parvanak</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - 'parvanak.app'
echo 'Built parvanak.app'
