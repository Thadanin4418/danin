#!/bin/zsh
set -euo pipefail

APP_NAME="Soranin"
APP_DIR="/Users/nin/Desktop/${APP_NAME}.app"
LEGACY_APP_DIR="/Users/nin/Desktop/Reels Control.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SRC="/Users/nin/Downloads/ReelsNativeApp/App.swift"
BIN="${MACOS_DIR}/Soranin"

if [[ -d "${LEGACY_APP_DIR}" && ! -d "${APP_DIR}" ]]; then
  mv "${LEGACY_APP_DIR}" "${APP_DIR}"
fi

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

swiftc \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  "${SRC}" \
  -o "${BIN}"

cat > "${CONTENTS_DIR}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Soranin</string>
  <key>CFBundleIdentifier</key>
  <string>local.nin.soranin</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Soranin</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSQuitAlwaysKeepsWindows</key>
  <false/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Soranin controls Google Chrome, Finder, and System Events to automate Facebook Reels workflows.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Soranin uses the microphone for Gemini Live voice chat.</string>
</dict>
</plist>
EOF

touch "${APP_DIR}"
echo "Built ${APP_DIR}"
