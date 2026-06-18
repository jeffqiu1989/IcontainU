#!/bin/bash
#===----------------------------------------------------------------------===//
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===//
#
# Package the container-ui SPM executable into a double-clickable .app bundle
# with an ad-hoc code signature. Output: build/IcontainU.app
#
# Usage: ./scripts/package-app.sh

set -euo pipefail

APP_NAME="IcontainU"
EXECUTABLE="container-ui"
BUNDLE_ID="com.35ers.IcontainU"
VERSION="1.0.0"
MIN_MACOS="26.0"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "==> Building release binary"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$EXECUTABLE"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE"

echo ""
echo "==> Done: $APP_BUNDLE"
echo "    Run locally:  open \"$APP_BUNDLE\""
echo "    Distribute:   zip -r -y IcontainU.zip \"$APP_BUNDLE\"  (see DISTRIBUTION.md)"
