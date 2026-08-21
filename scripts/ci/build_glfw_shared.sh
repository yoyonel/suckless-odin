#!/usr/bin/env bash
# build_glfw_shared.sh — Build GLFW shared library for Linux CI.
set -euo pipefail

GLFW_VERSION="${GLFW_VERSION:-3.4}"
INSTALL_PREFIX="${1:-$PWD/glfw-install}"

sudo apt-get update -qq
sudo apt-get install -y -qq cmake libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libwayland-dev libxkbcommon-dev >/dev/null

BUILD_DIR="/tmp/glfw-build"
SRC_DIR="/tmp/glfw-src"
rm -rf "$SRC_DIR" "$BUILD_DIR"

git clone --depth 1 --branch "${GLFW_VERSION}" https://github.com/glfw/glfw.git "$SRC_DIR"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DBUILD_SHARED_LIBS=ON \
    -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF
cmake --build "$BUILD_DIR" -j"$(nproc)"
cmake --install "$BUILD_DIR"
rm -rf "$SRC_DIR" "$BUILD_DIR"
echo "==> GLFW ${GLFW_VERSION} installed into ${INSTALL_PREFIX}."
