#!/usr/bin/env bash
# install_glfw_system.sh — Install GLFW artifacts from local directory to system /usr/local/.
set -euo pipefail

SOURCE_DIR="${1:-glfw-install}"

if [ ! -d "${SOURCE_DIR}" ]; then
    echo "Error: GLFW source directory ${SOURCE_DIR} not found." >&2
    exit 1
fi

sudo cp -a "${SOURCE_DIR}"/lib/* /usr/local/lib/
sudo cp -a "${SOURCE_DIR}"/include/* /usr/local/include/
cd /usr/local/lib && sudo ln -sf libglfw.so.3 libglfw.so 2>/dev/null || true
sudo ldconfig
echo "==> GLFW libraries installed to /usr/local/lib."
