#!/bin/bash
# Builds build/LiveZoom.app and signs it with a stable identity, so macOS keeps the
# Accessibility and Screen Recording grants across rebuilds.
#   scripts/build-app.sh               release build
#   scripts/build-app.sh debug         debug build
#   scripts/build-app.sh --install     build and install to /Applications/LiveZoom.app
#   CODESIGN_IDENTITY="..." scripts/build-app.sh
#   CODESIGN_IDENTITY="Developer ID Application: ..." also enables the hardened runtime (for notarization)
#   ARCH=x86_64 scripts/build-app.sh   build for one architecture (arm64 or x86_64)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=true ;;
    *)
      echo "Usage: $0 [debug|release] [--install]" >&2
      exit 1
      ;;
  esac
done

ARCH_FLAGS=()
if [ -n "${ARCH:-}" ]; then ARCH_FLAGS=(--arch "$ARCH"); fi
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/LiveZoom"

APP=build/LiveZoom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiveZoom"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

identities="$(security find-identity -v -p codesigning)"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  if [ "$CODESIGN_IDENTITY" = "-" ]; then
    identity="-"
  else
    identity="$(awk -F'"' -v p="$CODESIGN_IDENTITY" 'index($2, p) == 1 { print $2; exit }' <<< "$identities")"
    if [ -z "$identity" ]; then
      # Also allow passing a 40-char SHA-1 identity hash directly.
      identity="$(awk -v h="$CODESIGN_IDENTITY" '$2 == h { print $2; exit }' <<< "$identities")"
    fi
    if [ -z "$identity" ]; then
      echo "error: CODESIGN_IDENTITY '$CODESIGN_IDENTITY' did not match any codesigning identity." >&2
      exit 1
    fi
  fi
else
  identity="$(awk -F'"' -v p="Apple Development: Relakkes Yang" 'index($2, p) == 1 { print $2; exit }' <<< "$identities")"
  if [ -z "$identity" ]; then
    identity="$(awk -F'"' '/Apple Development/ { print $2; exit }' <<< "$identities")"
  fi
  if [ -z "$identity" ]; then
    identity="-"
    echo "warning: no Apple Development identity found; signing ad-hoc, so permissions reset on every build" >&2
  fi
fi

sign_args=(--force --sign "$identity")
# Developer ID builds get the hardened runtime and a secure timestamp, which notarization requires.
if [[ "$identity" == "Developer ID Application:"* ]]; then
  sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: $identity)"

if [ "$INSTALL" = true ]; then
  if [ ! -w /Applications ]; then
    echo "error: /Applications is not writable by $(id -un). Drag $APP to Applications manually or run with sufficient permissions." >&2
    exit 1
  fi

  # Stop any running LiveZoom cleanly before replacing the installed bundle.
  if pgrep -x LiveZoom >/dev/null 2>&1; then
    osascript -e 'tell application id "com.relakkes.livezoom" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      pgrep -x LiveZoom >/dev/null 2>&1 || break
      sleep 0.1
    done
    if pgrep -x LiveZoom >/dev/null 2>&1; then
      pkill -x LiveZoom >/dev/null 2>&1 || true
      sleep 0.2
    fi
  fi

  DEST="/Applications/LiveZoom.app"
  STAGED="/Applications/.LiveZoom.app.installing-$$"
  BACKUP="/Applications/.LiveZoom.app.backup-$$"
  MOVED_BACKUP=false

  cleanup_install() {
    rm -rf "$STAGED" 2>/dev/null || true
    if [ "$MOVED_BACKUP" = true ] && [ ! -e "$DEST" ] && [ -e "$BACKUP" ]; then
      mv "$BACKUP" "$DEST" 2>/dev/null || true
    fi
  }
  trap cleanup_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  rm -rf "$STAGED" "$BACKUP"
  ditto --noqtn "$APP" "$STAGED"
  if [ -e "$DEST" ]; then
    mv "$DEST" "$BACKUP"
    MOVED_BACKUP=true
  fi
  mv "$STAGED" "$DEST"
  if [ "$MOVED_BACKUP" = true ]; then
    rm -rf "$BACKUP"
    MOVED_BACKUP=false
  fi
  trap - EXIT INT TERM HUP
  echo "Installed $DEST"
fi
