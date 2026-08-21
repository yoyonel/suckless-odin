#!/usr/bin/env bash
# Compile and run Windows test suites under Wine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPS_DIR="$ROOT_DIR/deps"
ODIN_ROOT="${ODIN_ROOT:-$(odin root 2>/dev/null || echo "/opt/odin")}"
BUILD_WIN_DIR="$ROOT_DIR/build/windows"

SUITE="${1:-all}"

# Ensure deps exist
if [ ! -f "$DEPS_DIR/win_compat.o" ] || \
   [ ! -f "$DEPS_DIR/libsimd_windows_x64.lib" ] || \
   [ ! -f "$DEPS_DIR/odin-imgui/imgui_windows_x64.lib" ] || \
   [ ! -f "$DEPS_DIR/glfw_build_win/src/libglfw3.a" ] || \
   [ ! -f "$ODIN_ROOT/vendor/stb/lib/stb_image.lib" ]; then
    "$SCRIPT_DIR/build_win_deps.sh"
fi

mkdir -p "$BUILD_WIN_DIR"

compile_and_run_suite() {
    local target_dir="$1"
    local name="$2"
    local test_bin="$BUILD_WIN_DIR/test_${name}.exe"

    echo "==> [test-win-${name}] Compiling ${target_dir} for Windows..."
    rm -f "$BUILD_WIN_DIR/test_${name}"* "$test_bin"

    odin build "$target_dir" \
        -build-mode:test \
        -target:windows_amd64 \
        -keep-temp-files \
        -out:"$test_bin" 2>&1 || true

    # Locate generated intermediate files (.ll or .obj)
    local obj_files=()
    while IFS= read -r f; do
        obj_files+=("$f")
    done < <(find "$BUILD_WIN_DIR" "$ROOT_DIR" -maxdepth 1 -type f \( -name "test_${name}*.ll" -o -name "test_${name}*.obj" -o -name "test_${name}*.o" \) 2>/dev/null)

    if [ ${#obj_files[@]} -eq 0 ]; then
        echo "Error: No intermediate object/LLVM files found for test suite '${name}'."
        exit 1
    fi

    echo "==> [test-win-${name}] Linking $test_bin (${#obj_files[@]} object modules)..."
    CLANG_WIN="clang"
    if command -v clang-19 >/dev/null 2>&1; then
        CLANG_WIN="clang-19"
    fi

    $CLANG_WIN --target=x86_64-w64-windows-gnu \
        -fuse-ld=lld \
        -flto=thin -O3 -mavx2 -mfma -mf16c \
        -static \
        -static-libgcc \
        -o "$test_bin" \
        "${obj_files[@]}" \
        "$DEPS_DIR/win_compat.o" \
        "$DEPS_DIR/odin-imgui/imgui_windows_x64.lib" \
        "$DEPS_DIR/libsimd_windows_x64.lib" \
        "$DEPS_DIR/glfw_build_win/src/libglfw3.a" \
        "$ODIN_ROOT/vendor/stb/lib/stb_image.lib" \
        "$ODIN_ROOT/vendor/stb/lib/stb_truetype.lib" \
        "$ODIN_ROOT/vendor/stb/lib/stb_image_write.lib" \
        "$ODIN_ROOT/vendor/stb/lib/stb_rect_pack.lib" \
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

    # Cleanup temp .ll/.obj files
    for f in "${obj_files[@]}"; do
        rm -f "$f"
    done

    echo "==> [test-win-${name}] Running under Wine..."
    local wine_cmd
    wine_cmd="$(command -v wine 2>/dev/null || command -v wine64 2>/dev/null || echo "wine")"
    WINEDEBUG=-all "$wine_cmd" "$test_bin"
    echo "[✓] Suite test-win-${name} PASSED!"
}

case "$SUITE" in
    unit)
        compile_and_run_suite "$ROOT_DIR/tests/" "unit"
        ;;
    cli)
        compile_and_run_suite "$ROOT_DIR/src/" "cli"
        ;;
    shader)
        compile_and_run_suite "$ROOT_DIR/src/rendering/shader/" "shader"
        ;;
    all)
        compile_and_run_suite "$ROOT_DIR/tests/" "unit"
        compile_and_run_suite "$ROOT_DIR/src/" "cli"
        compile_and_run_suite "$ROOT_DIR/src/rendering/shader/" "shader"
        echo "[✓] All Windows test suites passed under Wine!"
        ;;
    *)
        echo "Error: Unknown suite '$SUITE'. Choices: unit, cli, shader, all"
        exit 1
        ;;
esac
