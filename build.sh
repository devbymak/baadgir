#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p 'Baadgir.app/Contents/MacOS' 'Baadgir.app/Contents/Resources' .build/app-icon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/app-icon.png --out ".build/app-icon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/app-icon.png --out ".build/app-icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p .build/module-cache
baadgir_cache_path="$(cd .build/module-cache && pwd -P)"
xcrun swift -module-cache-path "$baadgir_cache_path" sources/icon.swift .build/app-icon.iconset 'Baadgir.app/Contents/Resources/app-icon.icns'
xcrun swiftc -target arm64-apple-macosx13.0 -module-cache-path "$baadgir_cache_path" -swift-version 5 -O -framework AppKit -framework IOKit -framework ServiceManagement sources/policy.swift sources/main.swift -o 'Baadgir.app/Contents/MacOS/baadgir'
cat > 'Baadgir.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>baadgir</string>
<key>CFBundleIdentifier</key><string>local.baadgir</string>
<key>CFBundleName</key><string>Baadgir</string>
<key>CFBundleDisplayName</key><string>Baadgir</string>
<key>CFBundleIconFile</key><string>app-icon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - 'Baadgir.app'
echo 'Built Baadgir.app'
