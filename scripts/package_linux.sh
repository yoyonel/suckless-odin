#!/usr/bin/env bash
# Package suckless-odin Linux release archive (.tar.zst and .zip)
set -euo pipefail

VERSION="${1:-v0.1.0}"
BUILD_DIR="${2:-build/release}"
ZSTD_LEVEL="${3:-3}"

RELEASE_BASE_DIR="build-release"
RELEASE_NAME="suckless-odin-linux-${VERSION}"
RELEASE_DIR="${RELEASE_BASE_DIR}/${RELEASE_NAME}"
ARCHIVE_NAME="${RELEASE_NAME}.tar.zst"
ARCHIVE_PATH="${RELEASE_BASE_DIR}/${ARCHIVE_NAME}"
ZIP_NAME="${RELEASE_NAME}.zip"
ZIP_PATH="${RELEASE_BASE_DIR}/${ZIP_NAME}"

BIN_PATH="${BUILD_DIR}/suckless-odin"

if [ ! -f "${BIN_PATH}" ]; then
    echo "==> Executable ${BIN_PATH} not found. Triggering build..."
    task build-release
fi

echo "==> Synchronizing Linux release directory structure (${RELEASE_NAME})..."

# 1. Structure
mkdir -p "${RELEASE_DIR}/shaders" "${RELEASE_DIR}/assets"

# 2. Smart sync
rsync -a --update "${BIN_PATH}" "${RELEASE_DIR}/"
[ -d "shaders" ] && rsync -a --update shaders/ "${RELEASE_DIR}/shaders/"
[ -d "assets" ] && rsync -a --update assets/ "${RELEASE_DIR}/assets/"
[ -f "README.md" ] && rsync -a --update README.md "${RELEASE_DIR}/"
[ -f "LICENSE" ] && rsync -a --update LICENSE "${RELEASE_DIR}/"

# 3. Compression check (.tar.zst)
NEEDS_COMPRESSION=1
if [ -f "${ARCHIVE_PATH}" ]; then
    NEWER_FILES=$(find "${RELEASE_DIR}" -newer "${ARCHIVE_PATH}" -type f 2>/dev/null | head -n 1)
    if [ -z "${NEWER_FILES}" ]; then
        NEEDS_COMPRESSION=0
    fi
fi

if [ "${NEEDS_COMPRESSION}" -eq 0 ]; then
    echo "==> No changed files. tar.zst rebuild skipped."
else
    echo "==> Generating tar.zst archive (Level ${ZSTD_LEVEL}, rsyncable)..."
    cd "${RELEASE_BASE_DIR}"
    tar -I "zstd -T0 -${ZSTD_LEVEL} --rsyncable" -cf "${ARCHIVE_NAME}.tmp" "${RELEASE_NAME}"
    mv "${ARCHIVE_NAME}.tmp" "${ARCHIVE_NAME}"
    cd - > /dev/null
fi

# 4. Optional ZIP creation if zip is installed
if command -v zip >/dev/null 2>&1; then
    echo "==> Generating zip archive (${ZIP_NAME})..."
    (
        cd "${RELEASE_BASE_DIR}"
        zip -q -r "${ZIP_NAME}.tmp" "${RELEASE_NAME}"
        mv "${ZIP_NAME}.tmp" "${ZIP_NAME}"
    )
fi

echo "[✓] Linux packaging complete:"
du -sh "${ARCHIVE_PATH}"
[ -f "${ZIP_PATH}" ] && du -sh "${ZIP_PATH}"
