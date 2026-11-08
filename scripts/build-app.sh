#!/bin/bash
# Builds build/LiveZoom.app and signs it with a stable identity, so macOS keeps the
# Accessibility and Screen Recording grants across rebuilds.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
#   CODESIGN_IDENTITY="..." scripts/build-app.sh
#   CODESIGN_IDENTITY="Developer ID Application: ..." also enables the hardened runtime (for notarization)
#   ARCH=x86_64 scripts/build-app.sh   build for one architecture (arm64 or x86_64)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH_FLAGS=()
if [ -n "${ARCH:-}" ]; then ARCH_FLAGS=(--arch "$ARCH"); fi
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/LiveZoom"

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
sign_args=(--force --sign "$identity")
# Developer ID builds get the hardened runtime and a secure timestamp, which notarization requires.
if [[ "$identity" == "Developer ID Application:"* ]]; then
  sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $identity)"
