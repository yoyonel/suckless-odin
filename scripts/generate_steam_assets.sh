#!/usr/bin/env bash
# scripts/generate_steam_assets.sh — Generate Steam Grid artworks & icon formats
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REF_IMAGE="${ROOT_DIR}/docs/front.png"
OUT_DIR="${ROOT_DIR}/assets/steam_grid"

if [ ! -f "$REF_IMAGE" ]; then
    echo "❌ Error: Source reference image '$REF_IMAGE' not found."
    exit 1
fi

MAGICK_CMD="magick"
if ! command -v magick >/dev/null 2>&1; then
    if command -v convert >/dev/null 2>&1; then
        MAGICK_CMD="convert"
    else
        echo "❌ Error: ImageMagick (magick or convert) is required."
        exit 1
    fi
fi

echo "==> Creating Steam Grid assets directory in $OUT_DIR..."
mkdir -p "$OUT_DIR"

# 1. Cover (600x900) : Vertical poster cover
echo "==> 1. Generating cover.png (600x900)..."
"$MAGICK_CMD" "$REF_IMAGE" -resize 600x900^ -gravity center -extent 600x900 "$OUT_DIR/cover.png"

# 2. Hero (1920x620) : Wide panoramic header
echo "==> 2. Generating hero.png (1920x620)..."
"$MAGICK_CMD" "$REF_IMAGE" -resize 1920x620^ -gravity center -extent 1920x620 "$OUT_DIR/hero.png"

# 3. Banner (460x215) : Standard grid capsule
echo "==> 3. Generating banner.png (460x215)..."
"$MAGICK_CMD" "$REF_IMAGE" -resize 460x215^ -gravity center -extent 460x215 "$OUT_DIR/banner.png"

# 4. Logo (800x300) : Transparent overlay logo
echo "==> 4. Generating logo.png (800x300 transparent)..."
FONT_ARGS=()
if FONT_PATH=$(fc-match -f "%{file}" "sans-serif:bold" 2>/dev/null) && [ -n "$FONT_PATH" ] && [ -f "$FONT_PATH" ]; then
    FONT_ARGS=("-font" "$FONT_PATH")
else
    FONT_ARGS=("-font" "DejaVu-Sans-Bold")
fi

"$MAGICK_CMD" -size 800x300 xc:transparent \
    "${FONT_ARGS[@]}" \
    -pointsize 68 -fill white -gravity center \
    -draw "text 0,0 'Suckless Odin'" \
    "$OUT_DIR/logo.png"

# 5. Icon (64x64) & multi-resolution Windows ICO (16, 32, 48, 64, 128, 256)
echo "==> 5. Generating icon.png & icon.ico..."
"$MAGICK_CMD" "$REF_IMAGE" -resize 64x64^ -gravity center -extent 64x64 "$OUT_DIR/icon.png"
"$MAGICK_CMD" "$REF_IMAGE" -define icon:auto-resize=256,128,64,48,32,16 "$OUT_DIR/icon.ico"

echo "[✓] All Steam Grid assets generated successfully in assets/steam_grid/:"
ls -lh "$OUT_DIR"
