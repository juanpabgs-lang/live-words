#!/bin/bash
# Build Live Words.          ./build.sh
# Build + install + launch. ./build.sh install
set -euo pipefail
cd "$(dirname "$0")"

APP=build/LiveWords.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -parse-as-library LiveWords.swift -o "$APP/Contents/MacOS/LiveWords"
codesign --force --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "install" ]; then
  DEST=/Applications
  [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
  pkill -x LiveWords 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST/LiveWords.app"
  cp -R "$APP" "$DEST/LiveWords.app"
  open "$DEST/LiveWords.app"
  echo "installed + launched $DEST/LiveWords.app"
fi
