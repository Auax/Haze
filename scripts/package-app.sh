#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP_DIR="$ROOT/Build/FocusRecorder.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
rm -rf "$CLANG_MODULE_CACHE_PATH"
find "$ROOT/.build" -type d -name ModuleCache -prune -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build ${CONFIG:+--configuration "$CONFIG"} -Xcc "-fmodules-cache-path=$CLANG_MODULE_CACHE_PATH"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"
cp "$ROOT/.build/$CONFIG/FocusRecorder" "$BIN_DIR/FocusRecorder"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>FocusRecorder</string>
  <key>CFBundleIdentifier</key>
  <string>local.focusrecorder.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Focus Recorder</string>
  <key>CFBundleDisplayName</key>
  <string>Focus Recorder</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Personal tool</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Focus Recorder uses the microphone when microphone recording is enabled.</string>
</dict>
</plist>
PLIST

codesign \
  --force \
  --deep \
  --sign "$SIGN_IDENTITY" \
  --identifier "local.focusrecorder.app" \
  --requirements '=designated => identifier "local.focusrecorder.app"' \
  "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null

echo "$APP_DIR"
