#!/bin/sh
# build.sh: Plugin Assistant (Mantra).app. Run by GitHub Actions only (SIGN=- NO_INSTALL=1); never on the Mac.
set -e
cd "$(dirname "$0")"
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="Plugin Assistant (Mantra)"
APP="build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreAudioKit -framework AppKit -framework Network -o "$APP/Contents/MacOS/PluginAssistant" app/*.swift
cp icon/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>community.auroville.pluginassistant</string>
<key>CFBundleExecutable</key><string>PluginAssistant</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Plugin Assistant processes the microphone you choose with your Audio Unit plug-ins.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PL
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
if [ -z "$NO_INSTALL" ]; then rm -rf "/Applications/$NAME.app"; cp -R "$APP" /Applications/; fi
echo "built $APP (v$V)"
