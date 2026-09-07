#!/bin/bash
# Builds the styled OpenClip disk image (rendered background, icon layout, volume icon).
# Layout constants below must stay in sync with assets/dmg/background.html — see docs/dmg.md.
#
# Usage: ./scripts/make_dmg.sh <path-to-OpenClip.app> <output.dmg> [volume-name]

set -euo pipefail

APP_PATH="${1:-}"
OUTPUT_DMG="${2:-}"
VOLUME_NAME="${3:-OpenClip}"

if [ -z "$APP_PATH" ] || [ -z "$OUTPUT_DMG" ]; then
    echo "usage: $0 <path-to-OpenClip.app> <output.dmg> [volume-name]" >&2
    exit 2
fi

if [ ! -d "$APP_PATH" ]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

if ! command -v create-dmg > /dev/null 2>&1; then
    echo "error: create-dmg is required. Install it with: brew install create-dmg" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The background is drawn by Finder at its natural size, anchored to the top-left of the
# window's content area, and anything larger than that area makes the window scroll. The
# content area is the window height minus Finder chrome: a 28pt title bar, plus a ~36pt tab
# bar for users who leave "Show Tab Bar" on. So the window is sized taller than the canvas
# by CHROME_H, and the canvas bleeds to white so the leftover margin is invisible.
CANVAS_W=660
CANVAS_H=380
CHROME_H=68
WINDOW_W=$CANVAS_W
WINDOW_H=$((CANVAS_H + CHROME_H))
ICON_SIZE=128
TEXT_SIZE=13
ICON_Y=210
APP_X=170
DROP_X=490

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Rendering DMG background from assets/dmg/background.html..."
swift "$SCRIPT_DIR/render_html_png.swift" \
    "$PROJECT_DIR/assets/dmg/background.html" "$WORK_DIR/background.png" "$CANVAS_W" "$CANVAS_H" 1
swift "$SCRIPT_DIR/render_html_png.swift" \
    "$PROJECT_DIR/assets/dmg/background.html" "$WORK_DIR/background@2x.png" "$CANVAS_W" "$CANVAS_H" 2

# A multi-representation TIFF lets Finder pick the @2x rendition on Retina displays.
sips -s format tiff "$WORK_DIR/background.png" --out "$WORK_DIR/background-1x.tiff" > /dev/null
sips -s format tiff "$WORK_DIR/background@2x.png" --out "$WORK_DIR/background-2x.tiff" > /dev/null
tiffutil -cathidpicheck "$WORK_DIR/background-1x.tiff" "$WORK_DIR/background-2x.tiff" \
    -out "$WORK_DIR/background.tiff" > /dev/null

echo "==> Building volume icon..."
ICONSET="$WORK_DIR/VolumeIcon.iconset"
mkdir -p "$ICONSET"
for SPEC in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    set -- $SPEC
    sips -z "$1" "$1" "$PROJECT_DIR/assets/app-icon.png" --out "$ICONSET/icon_$2.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$WORK_DIR/VolumeIcon.icns"

echo "==> Packaging $(basename "$OUTPUT_DMG")..."
mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f "$OUTPUT_DMG"

STAGING_DIR="$WORK_DIR/staging"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
APP_NAME="$(basename "$APP_PATH")"

create-dmg \
    --volname "$VOLUME_NAME" \
    --volicon "$WORK_DIR/VolumeIcon.icns" \
    --background "$WORK_DIR/background.tiff" \
    --window-pos 200 120 \
    --window-size "$WINDOW_W" "$WINDOW_H" \
    --icon-size "$ICON_SIZE" \
    --text-size "$TEXT_SIZE" \
    --icon "$APP_NAME" "$APP_X" "$ICON_Y" \
    --hide-extension "$APP_NAME" \
    --app-drop-link "$DROP_X" "$ICON_Y" \
    --format UDZO \
    --no-internet-enable \
    --hdiutil-quiet \
    "$OUTPUT_DMG" \
    "$STAGING_DIR"

echo "==> DMG created: $OUTPUT_DMG"
