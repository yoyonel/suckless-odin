#!/usr/bin/env bash
# setup_linux_system.sh — Install base system libraries for Linux build/test.
set -euo pipefail

MODE="${1:-build}" # build | gl

sudo apt-get update -qq
if [ "$MODE" = "gl" ]; then
    sudo apt-get install -y -qq \
        libgl1-mesa-dev libc++-dev libx11-dev \
        mesa-utils xvfb >/dev/null
else
    sudo apt-get install -y -qq \
        libgl1-mesa-dev libc++-dev libx11-dev >/dev/null
fi
echo "==> Linux system packages installed for mode '${MODE}'."
