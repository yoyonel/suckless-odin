#!/usr/bin/env bash
# scripts/run_proton.sh — Run suckless-odin Windows executable under Steam Proton (Flatpak or Native)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-v0.1.0}"
shift || true
RELEASE_NAME="suckless-odin-windows-${VERSION}"
ARCHIVE_PATH="${ROOT_DIR}/build-release/${RELEASE_NAME}.tar.zst"
SANDBOX_DIR="${ROOT_DIR}/build/proton_sandbox"
mkdir -p "${SANDBOX_DIR}"

if [ ! -f "${ARCHIVE_PATH}" ]; then
    echo "==> Package ${ARCHIVE_PATH} not found. Triggering packaging..."
    "${ROOT_DIR}/scripts/package_win.sh" "${VERSION}"
fi

EXTRACTED_APP="${SANDBOX_DIR}/${RELEASE_NAME}/suckless-odin.exe"
PROTON_PFX="${SANDBOX_DIR}/proton_pfx"

echo "==> 1. Extracting package archive into sandbox (${SANDBOX_DIR})..."
rm -rf "${SANDBOX_DIR}/${RELEASE_NAME}"
tar -I "zstd" -xf "${ARCHIVE_PATH}" -C "${SANDBOX_DIR}"
mkdir -p "${PROTON_PFX}"

echo "==> 2. Detecting Steam Proton environment..."

# Test A : Flatpak Steam
if command -v flatpak &>/dev/null && flatpak info com.valvesoftware.Steam &>/dev/null; then
    echo "    [i] Environment detected: Steam Flatpak"
    STEAM_ROOT="${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    PROTON_PATH="${STEAM_ROOT}/steamapps/common/Proton - Experimental/proton"
    if [ ! -f "${PROTON_PATH}" ]; then
        PROTON_PATH="${STEAM_ROOT}/steamapps/common/Proton 9.0 (Beta)/proton"
    fi
    if [ ! -f "${PROTON_PATH}" ]; then
        PROTON_PATH=$(find "${STEAM_ROOT}/steamapps/common" -name "proton" -type f -perm -111 2>/dev/null | head -n 1 || true)
    fi

    if [ -z "${PROTON_PATH}" ] || [ ! -f "${PROTON_PATH}" ]; then
        echo "    [x] Error: Proton runner executable not found in ${STEAM_ROOT}/steamapps/common"
        exit 1
    fi

    echo "==> 3. Running suckless-odin under Proton Flatpak (${PROTON_PATH})..."
    cd "${SANDBOX_DIR}/${RELEASE_NAME}"
    flatpak run \
        --filesystem="${ROOT_DIR}" \
        --filesystem="${SANDBOX_DIR}" \
        --env=STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_ROOT}" \
        --env=STEAM_COMPAT_DATA_PATH="${PROTON_PFX}" \
        --command=python3 \
        com.valvesoftware.Steam \
        "${PROTON_PATH}" run "${EXTRACTED_APP}" "$@"

# Test B : Native Steam
elif [ -d "${HOME}/.local/share/Steam" ]; then
    echo "    [i] Environment detected: Native Steam"
    STEAM_ROOT="${HOME}/.local/share/Steam"
    PROTON_PATH="${STEAM_ROOT}/steamapps/common/Proton - Experimental/proton"
    if [ ! -f "${PROTON_PATH}" ]; then
        PROTON_PATH="${STEAM_ROOT}/steamapps/common/Proton 9.0 (Beta)/proton"
    fi
    if [ ! -f "${PROTON_PATH}" ]; then
        PROTON_PATH=$(find "${STEAM_ROOT}/steamapps/common" -name "proton" -type f -perm -111 2>/dev/null | head -n 1 || true)
    fi

    if [ -z "${PROTON_PATH}" ] || [ ! -f "${PROTON_PATH}" ]; then
        echo "    [x] Error: Proton runner executable not found in ${STEAM_ROOT}/steamapps/common"
        exit 1
    fi

    echo "==> 3. Running suckless-odin under Native Proton (${PROTON_PATH})..."
    cd "${SANDBOX_DIR}/${RELEASE_NAME}"
    STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_ROOT}" \
    STEAM_COMPAT_DATA_PATH="${PROTON_PFX}" \
    "${PROTON_PATH}" run "${EXTRACTED_APP}" "$@"

else
    echo "    [x] Error: No Steam installation detected (neither Flatpak nor Native)."
    exit 1
fi
