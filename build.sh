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
xcrun swiftc -target arm64-apple-macosx13.0 -module-cache-path "$baadgir_cache_path" -swift-version 5 -O -framework AppKit -framework IOKit -framework ServiceManagement -framework UserNotifications -framework Carbon sources/policy.swift sources/graph.swift sources/main.swift -o 'Baadgir.app/Contents/MacOS/baadgir'
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
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>local.baadgir</string>
<key>CFBundleURLSchemes</key><array><string>baadgir</string></array>
</dict></array>
</dict></plist>
PLIST
# Hardened runtime: no injected libraries or debugger attachment, including in the root helper.
codesign --force --sign - --options runtime 'Baadgir.app'
echo 'Built Baadgir.app'
if [[ "${1:-}" == "--install" ]]; then
  # Replace only an earlier Baadgir, never another app with the same name. Checked before anything is installed.
  if [[ -e '/Applications/Baadgir.app' && "$(plutil -extract CFBundleIdentifier raw -o - '/Applications/Baadgir.app/Contents/Info.plist' 2>/dev/null || true)" != local.baadgir ]]; then
    echo '/Applications/Baadgir.app is not Baadgir; leaving it in place.' >&2; exit 1
  fi
  # Fan control runs as root only from this root-owned copy, which apps running as you cannot replace.
  # Installed first, so a cancelled password prompt leaves the running app untouched.
  sudo mkdir -p /Library/PrivilegedHelperTools
  sudo install -o root -g wheel -m 755 'Baadgir.app/Contents/MacOS/baadgir' /Library/PrivilegedHelperTools/local.baadgir.helper
  # Quit every running copy first, wherever it was started; it restores automatic cooling before exiting. Matched by
  # bundle ID, like the app's own one-copy check, so a copy still running would also make the new one quit at launch.
  running() { [[ -n "$(lsappinfo find bundleid=local.baadgir)" ]] }
  # A refused quit request (such as a declined Automation prompt) is caught by the check below.
  if running; then osascript -e 'tell application id "local.baadgir" to quit' >/dev/null 2>&1 || true; fi
  for _ in {1..50}; do running || break; sleep 0.2; done
  if running; then echo 'Baadgir is still running; quit it, then run ./build.sh --install again.' >&2; exit 1; fi
  rm -rf '/Applications/Baadgir.app'
  ditto 'Baadgir.app' '/Applications/Baadgir.app'
  # Only the installed copy should handle baadgir:// links and Launch at Login.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/Baadgir.app" 2>/dev/null || true  # Fails when it was never registered.
  open '/Applications/Baadgir.app'
  echo 'Installed and opened /Applications/Baadgir.app'
fi
