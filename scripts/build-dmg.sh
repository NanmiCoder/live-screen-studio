#!/bin/bash
# Packages build/LiveZoom.app into a drag-to-Applications macOS DMG installer.
#   scripts/build-dmg.sh                     builds build/LiveZoom-<version>-<arch>.dmg
#   scripts/build-dmg.sh path/to/out.dmg     writes to an explicit output path
#   APP_PATH=... scripts/build-dmg.sh        uses a custom .app bundle path
#   REQUIRE_FINDER_LAYOUT=1 scripts/build-dmg.sh   fail if Finder layout/.DS_Store cannot be written
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/build-dmg.sh  signs the DMG
set -euo pipefail

CALLER_PWD="$PWD"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$CALLER_PWD" "$1" ;;
  esac
}

if [ -n "${APP_PATH:-}" ]; then
  APP_PATH="$(resolve_path "$APP_PATH")"
else
  APP_PATH="$REPO_ROOT/build/LiveZoom.app"
fi

RAW_DMG_ARG="${1:-}"
cd "$REPO_ROOT"

VOLUME_NAME="${VOLUME_NAME:-LiveZoom}"
REQUIRE_FINDER_LAYOUT="${REQUIRE_FINDER_LAYOUT:-0}"

if [ ! -d "$APP_PATH" ] || [ ! -f "$APP_PATH/Contents/Info.plist" ]; then
  echo "error: $APP_PATH not found. Run scripts/build-app.sh first." >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE")"
case "$ARCHS" in
  arm64) ARCH_LABEL="macos-apple-silicon" ;;
  x86_64) ARCH_LABEL="macos-intel" ;;
  *) ARCH_LABEL="macos-universal" ;;
esac

if [ -n "$RAW_DMG_ARG" ]; then
  DMG_PATH="$(resolve_path "$RAW_DMG_ARG")"
else
  DMG_PATH="$REPO_ROOT/build/LiveZoom-${VERSION}-${ARCH_LABEL}.dmg"
fi
if [[ "$DMG_PATH" != *.dmg ]]; then
  echo "error: output path must end with .dmg (got: $DMG_PATH)" >&2
  exit 1
fi

if [ -e "/Volumes/$VOLUME_NAME" ]; then
  echo "error: /Volumes/$VOLUME_NAME is already mounted. Eject it first (e.g. hdiutil detach \"/Volumes/$VOLUME_NAME\")." >&2
  exit 1
fi

WORK="$(mktemp -d)"
MOUNT_DEVICE=""
cleanup() {
  if [ -n "$MOUNT_DEVICE" ]; then
    hdiutil detach "$MOUNT_DEVICE" -quiet 2>/dev/null || hdiutil detach "$MOUNT_DEVICE" -force -quiet 2>/dev/null || true
    MOUNT_DEVICE=""
  fi
  rm -rf "$WORK"
}
# macOS /bin/bash 3.2 does not run EXIT traps on INT/TERM/HUP unless they exit explicitly.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
touch "$STAGE/.metadata_never_index"
ditto "$APP_PATH" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

# Render 1x and 2x Finder background images (600x360 pt) and combine into a HiDPI TIFF.
BG_1X="$WORK/bg.png"
BG_2X="$WORK/bg@2x.png"
BG_TIFF="$STAGE/.background/background.tiff"
swift - "$BG_1X" "$BG_2X" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func render(scale: CGFloat, to path: String) throws {
    let width = Int(600 * scale)
    let height = Int(360 * scale)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw NSError(domain: "dmg-bg", code: 1)
    }

    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // Subtle vertical light neutral gradient (Finder renders black icon labels on custom backgrounds).
    let top = CGColor(srgbRed: 0.975, green: 0.980, blue: 0.990, alpha: 1)
    let bottom = CGColor(srgbRed: 0.935, green: 0.945, blue: 0.962, alpha: 1)
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 360), end: CGPoint(x: 0, y: 0), options: [])
    }

    // Subtle dashed drop target frame around the Applications icon + label on the right (Finder {435, 165}).
    let dropRect = CGRect(x: 365, y: 108, width: 140, height: 150)
    let dropPath = CGPath(roundedRect: dropRect, cornerWidth: 24, cornerHeight: 24, transform: nil)
    ctx.saveGState()
    ctx.addPath(dropPath)
    ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.45, blue: 0.95, alpha: 0.045))
    ctx.fillPath()
    ctx.addPath(dropPath)
    ctx.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.48, blue: 0.92, alpha: 0.26))
    ctx.setLineWidth(1.5)
    ctx.setLineDash(phase: 0, lengths: [6, 5])
    ctx.strokePath()
    ctx.restoreGState()

    // Centered sleek right arrow between LiveZoom.app (x=165) and Applications (x=435) at CG y=195.
    let arrowY: CGFloat = 195
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(srgbRed: 0.38, green: 0.44, blue: 0.54, alpha: 0.65))
    ctx.setLineWidth(2.6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 266, y: arrowY))
    ctx.addLine(to: CGPoint(x: 332, y: arrowY))
    ctx.move(to: CGPoint(x: 318, y: arrowY + 12))
    ctx.addLine(to: CGPoint(x: 332, y: arrowY))
    ctx.addLine(to: CGPoint(x: 318, y: arrowY - 12))
    ctx.strokePath()
    ctx.restoreGState()

    // Bottom caption using AppKit text drawing into this CGContext.
    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.36, green: 0.40, blue: 0.47, alpha: 1),
        .paragraphStyle: paragraph,
    ]
    let caption = "将 LiveZoom 拖到右侧「应用程序」文件夹即可安装" as NSString
    caption.draw(in: CGRect(x: 40, y: 34, width: 520, height: 24), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "dmg-bg", code: 2)
    }
    let dpi = 72.0 * Double(scale)
    let props: [CFString: Any] = [
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi,
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "dmg-bg", code: 3)
    }
}

try render(scale: 1, to: CommandLine.arguments[1])
try render(scale: 2, to: CommandLine.arguments[2])
SWIFT

TIFF_LOG="$WORK/tiffutil.log"
if ! tiffutil -cathidpicheck "$BG_1X" "$BG_2X" -out "$BG_TIFF" >"$TIFF_LOG" 2>&1; then
  cat "$TIFF_LOG" >&2
  exit 1
fi

SIZE_MB="$(( $(du -sm "$STAGE" | awk '{print $1}') + 32 ))"
RW_DMG="$WORK/rw.dmg"
hdiutil create \
  -srcfolder "$STAGE" \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size "${SIZE_MB}m" \
  "$RW_DMG" >/dev/null

MOUNT_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
MOUNT_DEVICE="$(awk '/^\/dev\/disk/ {print $1; exit}' <<< "$MOUNT_OUTPUT")"
MOUNT_POINT="$(awk -F'\t' '/\/Volumes\// {print $NF; exit}' <<< "$MOUNT_OUTPUT")"
if [ -z "$MOUNT_DEVICE" ] || [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
  echo "error: failed to parse hdiutil attach output:" >&2
  echo "$MOUNT_OUTPUT" >&2
  exit 1
fi

chflags hidden "$MOUNT_POINT/.background" 2>/dev/null || true

# Apply Finder icon-view layout. In release CI (REQUIRE_FINDER_LAYOUT=1), fail loudly if layout fails.
LAYOUT_OK=false
if osascript - "$VOLUME_NAME" "$APP_NAME" "$MOUNT_POINT/.background/background.tiff" <<'APPLESCRIPT'
on run argv
  set diskName to item 1 of argv
  set appName to item 2 of argv
  set bgPath to item 3 of argv
  with timeout of 30 seconds
    tell application "Finder"
      tell disk diskName
        open
        try
          set current view of container window to icon view
          set toolbar visible of container window to false
          set statusbar visible of container window to false
          set the bounds of container window to {200, 120, 800, 508}
          set viewOptions to the icon view options of container window
          set arrangement of viewOptions to not arranged
          set icon size of viewOptions to 104
          set background picture of viewOptions to (POSIX file bgPath) as alias
          set position of item appName of container window to {165, 165}
          set position of item "Applications" of container window to {435, 165}
          update without registering applications
          delay 1
          close
        on error errMsg number errNum
          try
            close
          end try
          error errMsg number errNum
        end try
      end tell
    end tell
  end timeout
end run
APPLESCRIPT
then
  for _ in $(seq 1 10); do
    [ -s "$MOUNT_POINT/.DS_Store" ] && break
    sleep 0.3
  done
  if [ -s "$MOUNT_POINT/.DS_Store" ]; then
    LAYOUT_OK=true
    echo "Configured Finder layout for $VOLUME_NAME"
  fi
fi

if [ "$LAYOUT_OK" != true ]; then
  if [ "$REQUIRE_FINDER_LAYOUT" = "1" ]; then
    echo "error: Finder layout / .DS_Store was not written for $VOLUME_NAME" >&2
    exit 1
  fi
  echo "warning: Finder layout skipped; DMG still contains $APP_NAME and Applications symlink" >&2
fi

rm -rf "$MOUNT_POINT/.fseventsd" 2>/dev/null || true
sync
for _ in 1 2 3 4 5; do
  if hdiutil detach "$MOUNT_DEVICE" -quiet 2>/dev/null; then
    MOUNT_DEVICE=""
    break
  fi
  sleep 1
done
if [ -n "$MOUNT_DEVICE" ]; then
  hdiutil detach "$MOUNT_DEVICE" -force -quiet
  MOUNT_DEVICE=""
fi

OUT_DMG="$WORK/out.dmg"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null

if [[ "${CODESIGN_IDENTITY:-}" == "Developer ID Application:"* ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$OUT_DMG"
  codesign --verify --verbose "$OUT_DMG"
  SIGN_NOTE=" (signed with: $CODESIGN_IDENTITY)"
elif [ -n "${CODESIGN_IDENTITY:-}" ] && [ "$CODESIGN_IDENTITY" != "-" ]; then
  echo "warning: CODESIGN_IDENTITY '$CODESIGN_IDENTITY' is not a Developer ID Application identity; skipping DMG signing" >&2
  SIGN_NOTE=""
else
  SIGN_NOTE=""
fi

mkdir -p "$(dirname "$DMG_PATH")"
mv -f "$OUT_DMG" "$DMG_PATH"
echo "Built $DMG_PATH$SIGN_NOTE"
