#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p 'Parvanak.app/Contents/MacOS' 'Parvanak.app/Contents/Resources' .build/app-icon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/app-icon.png --out ".build/app-icon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/app-icon.png --out ".build/app-icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p .build/module-cache
parvanak_cache_path="$(cd .build/module-cache && pwd -P)"
xcrun swift -module-cache-path "$parvanak_cache_path" sources/icon.swift .build/app-icon.iconset 'Parvanak.app/Contents/Resources/app-icon.icns'
xcrun swiftc -target arm64-apple-macosx13.0 -module-cache-path "$parvanak_cache_path" -swift-version 5 -O -framework AppKit -framework IOKit sources/policy.swift sources/main.swift -o 'Parvanak.app/Contents/MacOS/parvanak'
cat > 'Parvanak.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>parvanak</string>
<key>CFBundleIdentifier</key><string>local.parvanak</string>
<key>CFBundleName</key><string>Parvanak</string>
<key>CFBundleDisplayName</key><string>Parvanak</string>
<key>CFBundleIconFile</key><string>app-icon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - 'Parvanak.app'
echo 'Built Parvanak.app'
