#!/bin/zsh
set -euo pipefail

APP_NAME="Soranin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/scripts"
APP_DIR="${SORANIN_APP_DIR:-${HOME}/Desktop/${APP_NAME}.app}"
LEGACY_APP_DIR="${HOME}/Desktop/Reels Control.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SRC="${SCRIPT_DIR}/App.swift"
BIN="${MACOS_DIR}/Soranin"
RUNTIME_DIR="${SORANIN_RUNTIME_DIR:-${HOME}/.soranin}"
LEGACY_PACKAGES_ROOT="$(cd "${REPO_ROOT}/.." && pwd)/Soranin"

if [[ -n "${SORANIN_PACKAGES_ROOT:-}" ]]; then
  PACKAGES_ROOT="${SORANIN_PACKAGES_ROOT}"
elif [[ -d "${LEGACY_PACKAGES_ROOT}" ]]; then
  PACKAGES_ROOT="${LEGACY_PACKAGES_ROOT}"
else
  PACKAGES_ROOT="${RUNTIME_DIR}/Soranin"
fi

if [[ -d "${LEGACY_APP_DIR}" && ! -d "${APP_DIR}" ]]; then
  mv "${LEGACY_APP_DIR}" "${APP_DIR}"
fi

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
mkdir -p "${RUNTIME_DIR}" "${PACKAGES_ROOT}"

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

REPO_ROOT="${REPO_ROOT}" \
SCRIPTS_DIR="${SCRIPTS_DIR}" \
RUNTIME_DIR="${RUNTIME_DIR}" \
PACKAGES_ROOT="${PACKAGES_ROOT}" \
RESOURCES_DIR="${RESOURCES_DIR}" \
python3 - <<'PY'
import json
import os
from pathlib import Path

payload = {
    "repoRoot": os.environ["REPO_ROOT"],
    "scriptsDir": os.environ["SCRIPTS_DIR"],
    "runtimeDir": os.environ["RUNTIME_DIR"],
    "packagesRoot": os.environ["PACKAGES_ROOT"],
}
Path(os.environ["RESOURCES_DIR"], "runtime_paths.json").write_text(
    json.dumps(payload, indent=2),
    encoding="utf-8",
)
PY

touch "${APP_DIR}"
echo "Built ${APP_DIR}"
