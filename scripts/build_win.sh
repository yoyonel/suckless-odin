#!/usr/bin/env bash
# Cross-compile suckless-odin for Windows x64 using Odin + MinGW/LLD toolchain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPS_DIR="$ROOT_DIR/deps"
ODIN_ROOT="${ODIN_ROOT:-$(odin root 2>/dev/null || echo "/opt/odin")}"

MODE="${1:-debug}"
OUT_FILE="${2:-}"

EXTRA_WIN_LIBS=""

case "$MODE" in
    debug)
        ODIN_FLAGS="-debug -use-separate-modules"
        DEFAULT_OUT="$ROOT_DIR/build/debug-win/suckless-odin.exe"
        OBJ_DIR="$ROOT_DIR/build/obj-win-debug"
        ;;
    release)
        ODIN_FLAGS="-o:speed -use-separate-modules"
        DEFAULT_OUT="$ROOT_DIR/build/release-win/suckless-odin.exe"
        OBJ_DIR="$ROOT_DIR/build/obj-win-release"
        ;;
    profile)
        ODIN_FLAGS="-o:speed -define:TRACY_ENABLE=true -use-separate-modules"
        DEFAULT_OUT="$ROOT_DIR/build/profile-win/suckless-odin.exe"
        OBJ_DIR="$ROOT_DIR/build/obj-win-profile"
        EXTRA_WIN_LIBS="$DEPS_DIR/libtracy_windows_x64.lib -lws2_32 -ldbghelp"
        ;;
    ultra)
        ODIN_FLAGS="-o:aggressive -no-bounds-check -no-type-assert"
        DEFAULT_OUT="$ROOT_DIR/build/ultra-win/suckless-odin.exe"
        OBJ_DIR="$ROOT_DIR/build/obj-win-ultra"
        ;;
    *)
        echo "Error: Unknown build mode '$MODE'. Choices: debug, release, profile, ultra"
        exit 1
        ;;
esac

OUT_FILE="${OUT_FILE:-$DEFAULT_OUT}"
OUT_DIR="$(dirname "$OUT_FILE")"

# 1. Ensure Windows static libs are built
if [ ! -f "$DEPS_DIR/win_compat.o" ] || \
   [ ! -f "$DEPS_DIR/libsimd_windows_x64.lib" ] || \
   [ ! -f "$DEPS_DIR/odin-imgui/imgui_windows_x64.lib" ] || \
   [ ! -f "$DEPS_DIR/glfw_build_win/src/libglfw3.a" ] || \
   [ ! -f "$ODIN_ROOT/vendor/stb/lib/stb_image.lib" ]; then
    echo "==> Windows dependencies missing or incomplete. Building..."
    "$SCRIPT_DIR/build_win_deps.sh"
fi

# 2. Compile Odin packages to Windows object files
mkdir -p "$OBJ_DIR" "$OUT_DIR"
rm -f "$OBJ_DIR"/*.obj

echo "==> Compiling Odin sources for Windows ($MODE)..."
odin build "$ROOT_DIR/src/" \
    -target:windows_amd64 \
    -build-mode:obj \
    -out:"$OBJ_DIR/suckless-odin.obj" \
    $ODIN_FLAGS

# 3. Link Windows PE executable via clang/lld
echo "==> Linking Windows executable ($OUT_FILE)..."
LTO_FLAGS=""
if [ "$MODE" != "debug" ]; then
    LTO_FLAGS="-flto=thin -O3 -mavx2 -mfma -mf16c"
fi

CLANG_WIN="clang"
if command -v clang-19 >/dev/null 2>&1; then
    CLANG_WIN="clang-19"
fi

$CLANG_WIN --target=x86_64-w64-windows-gnu \
    -fuse-ld=lld \
    $LTO_FLAGS \
    -static \
    -static-libgcc \
    -o "$OUT_FILE" \
    "$OBJ_DIR"/*.obj \
    "$DEPS_DIR/win_compat.o" \
    "$DEPS_DIR/odin-imgui/imgui_windows_x64.lib" \
    "$DEPS_DIR/libsimd_windows_x64.lib" \
    "$DEPS_DIR/glfw_build_win/src/libglfw3.a" \
    "$ODIN_ROOT/vendor/stb/lib/stb_image.lib" \
    "$ODIN_ROOT/vendor/stb/lib/stb_truetype.lib" \
    "$ODIN_ROOT/vendor/stb/lib/stb_image_write.lib" \
    "$ODIN_ROOT/vendor/stb/lib/stb_rect_pack.lib" \
    $EXTRA_WIN_LIBS \
    -lopengl32 \
    -lgdi32 \
    -luser32 \
    -lshell32 \
    -lkernel32 \
    -lbcrypt \
    -lntdll \
    -lsynchronization \
    -lpthread \
    -lstdc++

echo "[✓] Windows binary generated successfully: $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"
