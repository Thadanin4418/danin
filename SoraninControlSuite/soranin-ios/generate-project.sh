#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLING_DIR="$PROJECT_DIR/.tooling"
XCODEGEN_BIN="$TOOLING_DIR/xcodegen/xcodegen/bin/xcodegen"

if [ ! -x "$XCODEGEN_BIN" ]; then
  mkdir -p "$TOOLING_DIR"
  cd "$TOOLING_DIR"
  rm -rf xcodegen xcodegen.zip
  curl -L --fail -o xcodegen.zip "https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip"
  unzip -q xcodegen.zip -d xcodegen
  chmod +x "$XCODEGEN_BIN"
fi

cd "$PROJECT_DIR"
"$XCODEGEN_BIN" generate
