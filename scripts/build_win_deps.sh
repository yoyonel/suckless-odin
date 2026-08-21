#!/usr/bin/env bash
# Build Windows x64 dependencies: GLFW, Dear ImGui, SIMD utils, win_compat shim, and vendor STB libs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPS_DIR="$ROOT_DIR/deps"
ODIN_ROOT="${ODIN_ROOT:-$(odin root 2>/dev/null || echo "$HOME/.local/share/odin-linux-amd64-nightly+2026-08-06/")}"
NPROCS=$(( $(nproc) - 2 ))
[ "$NPROCS" -lt 1 ] && NPROCS=1

if command -v clang-19 >/dev/null 2>&1; then
    CC_WIN="clang-19 --target=x86_64-w64-windows-gnu"
    CXX_WIN="clang++-19 --target=x86_64-w64-windows-gnu"
    AR_TOOL="llvm-ar-19"
    if ! command -v llvm-ar-19 >/dev/null 2>&1; then
        AR_TOOL="$(command -v llvm-ar 2>/dev/null || echo "x86_64-w64-mingw32-ar")"
    fi
    OPTIM_FLAGS="-O3 -flto=thin -mavx2 -mfma -mf16c"
elif command -v clang >/dev/null 2>&1; then
    CC_WIN="clang --target=x86_64-w64-windows-gnu"
    CXX_WIN="clang++ --target=x86_64-w64-windows-gnu"
    AR_TOOL="$(command -v llvm-ar 2>/dev/null || echo "x86_64-w64-mingw32-ar")"
    OPTIM_FLAGS="-O3 -flto=thin -mavx2 -mfma -mf16c"
else
    CC_WIN="x86_64-w64-mingw32-gcc"
    CXX_WIN="x86_64-w64-mingw32-g++"
    AR_TOOL="x86_64-w64-mingw32-ar"
    OPTIM_FLAGS="-O3 -mavx2 -mf16c"
fi
AS_WIN="x86_64-w64-mingw32-as"
WINDRES_WIN="x86_64-w64-mingw32-windres"

echo "==> [1/5] Building Windows win_compat.o shim..."
"$AS_WIN" "$DEPS_DIR/win_compat.s" -o "$DEPS_DIR/win_compat.o"

echo "==> [2/5] Building Windows libsimd_windows_x64.lib (AVX2/FMA/F16C ThinLTO)..."
$CC_WIN $OPTIM_FLAGS -I"$DEPS_DIR" -c "$DEPS_DIR/simd_utils.c" -o "$DEPS_DIR/simd_utils_win.o"
"$AR_TOOL" rcs "$DEPS_DIR/libsimd_windows_x64.lib" "$DEPS_DIR/simd_utils_win.o"
rm -f "$DEPS_DIR/simd_utils_win.o"

echo "==> [3/5] Building Windows GLFW static library (libglfw3.a)..."
if [ ! -d "$DEPS_DIR/odin-imgui/backend_deps/glfw/.git" ]; then
    echo "==> Cloning GLFW repository for Dear ImGui & Windows cross-compilation..."
    rm -rf "$DEPS_DIR/odin-imgui/backend_deps/glfw"
    git clone https://github.com/glfw/glfw.git "$DEPS_DIR/odin-imgui/backend_deps/glfw"
fi
if [ -f "$DEPS_DIR/glfw_build_win/CMakeCache.txt" ]; then
    if ! grep -q "CMAKE_CACHEFILE_DIR:INTERNAL=$DEPS_DIR/glfw_build_win" "$DEPS_DIR/glfw_build_win/CMakeCache.txt" 2>/dev/null; then
        rm -rf "$DEPS_DIR/glfw_build_win"
    fi
fi
mkdir -p "$DEPS_DIR/glfw_build_win"
cmake -B "$DEPS_DIR/glfw_build_win" -S "$DEPS_DIR/odin-imgui/backend_deps/glfw" \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc \
    -DCMAKE_RC_COMPILER="$WINDRES_WIN" \
    -DGLFW_BUILD_EXAMPLES=OFF \
    -DGLFW_BUILD_TESTS=OFF \
    -DGLFW_BUILD_DOCS=OFF \
    -DGLFW_INSTALL=OFF \
    -Wno-dev
cmake --build "$DEPS_DIR/glfw_build_win" --parallel "$NPROCS"

if [ -d "$ODIN_ROOT/vendor/glfw/lib" ] && [ -w "$ODIN_ROOT/vendor/glfw/lib" ]; then
    cp "$DEPS_DIR/glfw_build_win/src/libglfw3.a" "$ODIN_ROOT/vendor/glfw/lib/glfw3_mt.lib"
fi

echo "==> [4/5] Building Windows vendor STB static libraries..."
mkdir -p "$ODIN_ROOT/vendor/stb/lib" 2>/dev/null || true
if [ -d "$ODIN_ROOT/vendor/stb/src" ]; then
    (
        cd "$ODIN_ROOT/vendor/stb/src"
        $CC_WIN $OPTIM_FLAGS -c stb_image.c stb_image_write.c stb_image_resize.c stb_truetype.c stb_rect_pack.c stb_vorbis.c stb_sprintf.c
        "$AR_TOOL" rcs ../lib/stb_image.lib stb_image.o
        "$AR_TOOL" rcs ../lib/stb_image_write.lib stb_image_write.o
        "$AR_TOOL" rcs ../lib/stb_image_resize.lib stb_image_resize.o
        "$AR_TOOL" rcs ../lib/stb_truetype.lib stb_truetype.o
        "$AR_TOOL" rcs ../lib/stb_rect_pack.lib stb_rect_pack.o
        "$AR_TOOL" rcs ../lib/stb_vorbis.lib stb_vorbis.o
        "$AR_TOOL" rcs ../lib/stb_sprintf.lib stb_sprintf.o
        rm -f ./*.o
    )
fi

echo "==> [5/5] Building Windows Dear ImGui static library (imgui_windows_x64.lib)..."
(
    cd "$DEPS_DIR/odin-imgui"
    if ! python3 -c "import ply" >/dev/null 2>&1; then
        python3 -m pip install ply || python3 -m pip install --break-system-packages ply || true
    fi
    if [ ! -d "temp" ] || [ ! -f "temp/imgui.cpp" ]; then
        python3 build.py || true
    fi
    cd temp
    for f in imgui.cpp imgui_draw.cpp imgui_demo.cpp imgui_tables.cpp imgui_widgets.cpp c_imgui.cpp c_imgui_internal.cpp imgui_impl_glfw.cpp imgui_impl_opengl3.cpp imgui_impl_vulkan.cpp; do
        if [ -f "$f" ]; then
            $CXX_WIN $OPTIM_FLAGS -std=c++11 -DIMGUI_IMPL_API='extern "C"' -DVK_NO_PROTOTYPES \
                -I. \
                -I../backend_deps/glfw/include \
                -I../backend_deps/Vulkan-Headers/include \
                -c "$f"
        fi
    done
    rm -f ../imgui_windows_x64.lib
    "$AR_TOOL" rcs ../imgui_windows_x64.lib ./*.o
    rm -f ./*.o
)

echo "==> [6/6] Building Windows Tracy Client library (libtracy_windows_x64.lib)..."
CXX_MIN_WIN="x86_64-w64-mingw32-g++"
CC_MIN_WIN="x86_64-w64-mingw32-gcc"
$CXX_MIN_WIN -c -O3 -mavx2 -mf16c -std=c++17 -DTRACY_ENABLE -DTRACY_ON_DEMAND -DTRACY_FIBERS -DWIN32_LEAN_AND_MEAN -I "$DEPS_DIR/tracy/public" -I "$DEPS_DIR/glad/include" -I "$DEPS_DIR" "$DEPS_DIR/tracy/public/TracyClient.cpp" -o "$DEPS_DIR/TracyClient_win.o"
$CXX_MIN_WIN -c -O3 -mavx2 -mf16c -std=c++17 -DTRACY_ENABLE -DTRACY_ON_DEMAND -DTRACY_FIBERS -DWIN32_LEAN_AND_MEAN -I "$DEPS_DIR/tracy/public" -I "$DEPS_DIR/glad/include" -I "$DEPS_DIR" "$DEPS_DIR/tracy_gpu.cpp" -o "$DEPS_DIR/tracy_gpu_win.o"
$CC_MIN_WIN -c -O3 -mavx2 -mf16c -I "$DEPS_DIR/glad/include" "$DEPS_DIR/glad/src/glad.c" -o "$DEPS_DIR/glad_win.o"
"$AR_TOOL" rcs "$DEPS_DIR/libtracy_windows_x64.lib" "$DEPS_DIR/TracyClient_win.o" "$DEPS_DIR/tracy_gpu_win.o" "$DEPS_DIR/glad_win.o"
rm -f "$DEPS_DIR/TracyClient_win.o" "$DEPS_DIR/tracy_gpu_win.o" "$DEPS_DIR/glad_win.o"

echo "[✓] All Windows dependencies built successfully."
