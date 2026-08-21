#!/usr/bin/env bash
# setup_win_toolchain.sh — Setup Windows cross-compilation toolchain and Wine environment on Ubuntu runner.
set -euo pipefail

WITH_PACKAGING="${1:-false}"

PACKAGES=(
    gcc-mingw-w64-x86-64
    g++-mingw-w64-x86-64
    clang-19
    lld-19
    llvm-19
    wine
    wine64
    libgl1-mesa-dev
    xvfb
    python3-ply
    python3-pip
)

if [ "$WITH_PACKAGING" = "true" ]; then
    PACKAGES+=(zstd zip mesa-utils rsync)
fi

sudo apt-get update -qq
sudo apt-get install -y -qq "${PACKAGES[@]}" >/dev/null

# Configure Clang-19 / LLVM-19 symlinks as default
sudo ln -sf /usr/bin/clang-19 /usr/bin/clang
sudo ln -sf /usr/bin/clang++-19 /usr/bin/clang++
sudo ln -sf /usr/bin/lld-19 /usr/bin/lld
sudo ln -sf /usr/bin/llvm-ar-19 /usr/bin/llvm-ar

# Initialize Wine prefix quietly
WINEDEBUG=-all wineboot --init || true
echo "==> Windows cross-compilation toolchain configured successfully."
