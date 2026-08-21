#!/usr/bin/env bash
# build_imgui_linux.sh — Build Dear ImGui static library for Linux.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR/deps/odin-imgui"

sudo apt-get update -qq
sudo apt-get install -y -qq libc++-dev libgl1-mesa-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libwayland-dev libxkbcommon-dev python3 python3-venv python3-pip >/dev/null

python3 -m venv .venv
. .venv/bin/activate
pip install -q ply
python ../../scripts/build_imgui_parallel.py
echo "==> ImGui Linux library built at $(pwd)/imgui_linux_x64.a."
