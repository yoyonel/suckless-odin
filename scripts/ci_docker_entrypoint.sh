#!/usr/bin/env bash
# ci_docker_entrypoint.sh — Entrypoint for the local CI Docker image.
# Reproduces the exact same steps as .github/workflows/ci.yml test-unit job.
#
# Usage: docker run --rm -v $PWD:/workspace suckless-odin-ci [MODE]
# Modes: lint, build, test-unit, test-cli, test-shader, test-gl, all (default)

set -euo pipefail

LINKER_FLAGS="-lX11"
MODE="${1:-all}"

# --- Helpers ---
section() { echo -e "\n\033[1;36m══════ $1 ══════\033[0m"; }
diag() {
    section "System Diagnostics"
    echo "=== Memory ===" && free -m
    echo "=== CPU ===" && nproc
    echo "=== Disk ===" && df -h /tmp
    echo "=== Odin ===" && odin version
}

# --- Build ImGui if needed ---
ensure_imgui() {
    if [ ! -f deps/odin-imgui/imgui_linux_x64.a ]; then
        section "Building ImGui"
        cd deps/odin-imgui
        python3 -m venv .venv
        . .venv/bin/activate
        pip install -q ply
        python ../../scripts/build_imgui_parallel.py
        cd ../..
    fi
}

# --- CI steps ---
do_lint() {
    section "Lint (vet + strict-style)"
    odin check src/ -vet -strict-style -warnings-as-errors
}

do_build() {
    section "Build (debug)"
    mkdir -p build/debug
    odin build src/ -out:build/debug/suckless-odin -debug -use-separate-modules \
        -extra-linker-flags:"$LINKER_FLAGS"
}

do_test_unit() {
    section "Build Unit Tests (compilation)"
    odin build tests/ -out:/tmp/odin-test-unit -build-mode:test \
        -extra-linker-flags:"$LINKER_FLAGS"
    section "Run Unit Tests (execution)"
    /tmp/odin-test-unit
}

do_test_cli() {
    section "Build CLI Tests (compilation)"
    odin build src/ -out:/tmp/odin-test-cli -build-mode:test \
        -extra-linker-flags:"$LINKER_FLAGS"
    section "Run CLI Tests (execution)"
    /tmp/odin-test-cli
}

do_test_shader() {
    section "Build Shader CPU Tests (compilation)"
    odin build src/rendering/shader/ -out:/tmp/odin-test-shader -build-mode:test \
        -extra-linker-flags:"$LINKER_FLAGS"
    section "Run Shader CPU Tests (execution)"
    /tmp/odin-test-shader
}

do_test_gl() {
    section "Build GL Tests (compilation)"
    odin build tests/gl/ -out:/tmp/odin-test-gl -build-mode:test \
        -define:ODIN_TEST_THREADS=1 \
        -extra-linker-flags:"$LINKER_FLAGS"
    section "Run GL Tests (under xvfb)"
    xvfb-run -a -s "-screen 0 1024x768x24" /tmp/odin-test-gl
}

do_test_win() {
    section "Windows Cross-Compilation & Wine Tests"
    task test-win
}

do_package_win() {
    section "Windows Packaging & Verification"
    task package-win
}

# --- Main ---
diag
ensure_imgui

case "$MODE" in
    lint)        do_lint ;;
    build)       do_lint && do_build ;;
    test-unit)   do_test_unit ;;
    test-cli)    do_test_cli ;;
    test-shader) do_test_shader ;;
    test-gl)     do_test_gl ;;
    test-win)    do_test_win ;;
    package-win) do_package_win ;;
    all)
        do_lint
        do_build
        do_test_unit
        do_test_cli
        do_test_shader
        do_test_gl
        do_test_win
        section "ALL PASSED ✓"
        ;;
    *)
        echo "Unknown mode: $MODE"
        echo "Usage: $0 [lint|build|test-unit|test-cli|test-shader|test-gl|test-win|package-win|all]"
        exit 1
        ;;
esac
