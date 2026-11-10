#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"
swift build -c release

dist_dir="$project_dir/dist"
app="$dist_dir/My Hub.app"
dmg="$dist_dir/My Hub.dmg"
mkdir -p "$dist_dir"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/WidgetDesk "$app/Contents/MacOS/MyHub"
cp Assets/MyHub.icns "$app/Contents/Resources/MyHub.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>My Hub</string>
    <key>CFBundleExecutable</key><string>MyHub</string>
    <key>CFBundleIconFile</key><string>MyHub</string>
    <key>CFBundleIdentifier</key><string>com.codex.myhub</string>
    <key>CFBundleName</key><string>My Hub</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.9.27</string>
    <key>CFBundleVersion</key><string>55</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R -X "$app" "$stage/My Hub.app"
ln -s /Applications "$stage/Programme"
hdiutil create -volname 'My Hub' -srcfolder "$stage" -ov -format UDZO "$dmg"
hdiutil verify "$dmg"
print "Fertig: $dmg"
