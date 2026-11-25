#!/bin/bash
# Builds "build/Profile Switch.app" with the Command Line Tools alone (no Xcode project).
# "./build.sh install" also copies it to ~/Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Profile Switch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# Swift 5 mode: the app is single-threaded AppKit, and Swift 6's concurrency checks add nothing here.
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" Sources/*.swift -o "$APP/Contents/MacOS/Profile Switch"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "install" ]; then
  # ~/Applications: writable without admin rights, and macOS doesn't guard it the way it guards /Applications.
  DEST="$HOME/Applications"
  pkill -x "Profile Switch" || true
  mkdir -p "$DEST"
  rm -rf "$DEST/Profile Switch.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/Profile Switch.app"
  echo "installed and started $DEST/Profile Switch.app"
fi
