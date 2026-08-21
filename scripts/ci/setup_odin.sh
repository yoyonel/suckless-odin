#!/usr/bin/env bash
# setup_odin.sh — Download and install Odin compiler if not already present.
set -euo pipefail

ODIN_VERSION="${ODIN_VERSION:-dev-2026-05}"
ODIN_URL="${ODIN_URL:-https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz}"
ODIN_DEST="${ODIN_ROOT:-/opt/odin}"

if [ ! -f "${ODIN_DEST}/odin" ]; then
    echo "==> Installing Odin (${ODIN_VERSION}) to ${ODIN_DEST}..."
    sudo mkdir -p "${ODIN_DEST}" 2>/dev/null || mkdir -p "${ODIN_DEST}"
    curl -sSL "${ODIN_URL}" | (sudo tar xz -C "${ODIN_DEST}" --strip-components=1 2>/dev/null || tar xz -C "${ODIN_DEST}" --strip-components=1)
    (sudo make -C "${ODIN_DEST}/vendor/stb/src" 2>/dev/null || make -C "${ODIN_DEST}/vendor/stb/src")
fi

if [ -n "${GITHUB_PATH:-}" ]; then
    echo "${ODIN_DEST}" >> "$GITHUB_PATH"
fi
echo "==> Odin configured at ${ODIN_DEST}."
