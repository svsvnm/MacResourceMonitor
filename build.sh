#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_DIR="$SCRIPT_DIR/Mac资源监控.app"
CONTENTS_DIR="$APP_DIR/Contents"
EXECUTABLE_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$RESOURCES_DIR/Helpers"
WHATCABLE_ASSETS="$SCRIPT_DIR/Assets/WhatCableHelper"

rm -rf "$APP_DIR"
mkdir -p "$EXECUTABLE_DIR" "$RESOURCES_DIR" "$HELPERS_DIR"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
cp "$SCRIPT_DIR/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$WHATCABLE_ASSETS/whatcable-cli" "$HELPERS_DIR/whatcable-cli"
chmod 755 "$HELPERS_DIR/whatcable-cli"
ditto "$WHATCABLE_ASSETS/WhatCable_WhatCableCore.bundle" "$RESOURCES_DIR/WhatCable_WhatCableCore.bundle"

xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  -O \
  -target arm64-apple-macos26.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework IOKit \
  -framework SystemConfiguration \
  "$SCRIPT_DIR/Sources/CommandRunner.swift" \
  "$SCRIPT_DIR/Sources/StorageManager.swift" \
  "$SCRIPT_DIR/Sources/CableMonitor.swift" \
  "$SCRIPT_DIR/Sources/MacResourceMonitor.swift" \
  -o "$EXECUTABLE_DIR/MacResourceMonitor"

codesign --force --sign - "$HELPERS_DIR/whatcable-cli"
codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
