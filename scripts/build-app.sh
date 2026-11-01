#!/bin/bash
# Builds build/LiveZoom.app and signs it with a stable identity, so macOS keeps the
# Accessibility and Screen Recording grants across rebuilds.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
#   CODESIGN_IDENTITY="..." scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LiveZoom"

APP=build/LiveZoom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/LiveZoom"
cp Resources/Info.plist "$APP/Contents/Info.plist"

identities="$(security find-identity -v -p codesigning)"
preferred="${CODESIGN_IDENTITY:-Apple Development: Relakkes Yang}"
identity="$(awk -F'"' -v p="$preferred" 'index($2, p) == 1 { print $2; exit }' <<< "$identities")"
if [ -z "$identity" ]; then
  identity="$(awk -F'"' '/Apple Development/ { print $2; exit }' <<< "$identities")"
fi
if [ -z "$identity" ]; then
  identity="-"
  echo "warning: no Apple Development identity found; signing ad-hoc, so permissions reset on every build" >&2
fi
codesign --force --sign "$identity" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $identity)"
