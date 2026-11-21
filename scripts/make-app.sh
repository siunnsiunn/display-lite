#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"
APP_PATH="$ROOT_DIR/dist/DisplayLite.app"

# Never remove anything outside this exact app bundle.
if [[ -z "$APP_PATH" || "$APP_PATH" != */dist/DisplayLite.app ]]; then
    printf 'Refusing to remove unexpected app path: %s\n' "$APP_PATH" >&2
    exit 1
fi
rm -rf -- "$APP_PATH"

# Optional arguments support the README's repository-local cache workaround.
swift build -c release --product DisplayLite "$@"
BIN_DIR="$(swift build -c release --show-bin-path "$@")"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BIN_DIR/DisplayLite" "$APP_PATH/Contents/MacOS/DisplayLite"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.jung.displaylite</string>
    <key>CFBundleName</key><string>DisplayLite</string>
    <key>CFBundleDisplayName</key><string>DisplayLite</string>
    <key>CFBundleExecutable</key><string>DisplayLite</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.jung.displaylite "$APP_PATH"
codesign --verify --verbose "$APP_PATH"
printf '%s\n' "$APP_PATH"
