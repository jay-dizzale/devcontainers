#!/bin/sh
# install-python.sh
# Downloads a pinned uv release tarball from GitHub releases,
# verifies its SHA256 checksum, and installs uv and uvx.
#
# Usage:
#   ./install-python.sh <version>
#
# Or via environment variable:
#   UV_VERSION=0.6.14 ./install-python.sh
#
# Dependencies: wget, sha256sum, tar, awk

set -eu

. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

UV_VERSION="${1:-${UV_VERSION:-}}"
if [ -z "${UV_VERSION}" ]; then
    echo "Resolving latest stable uv release ..."
    UV_VERSION="$(github_latest_stable astral-sh/uv)"
    [ -n "${UV_VERSION}" ] || { echo "ERROR: could not resolve latest uv version" >&2; exit 1; }
fi

BASE_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
INSTALL_DIR="/usr/local/bin"

# ---------------------------------------------------------------------------
# Detect architecture
# ---------------------------------------------------------------------------

ARCH="$(uname -m)"
case "${ARCH}" in
    arm64|aarch64) TRIPLE="aarch64-unknown-linux-gnu" ;;
    x86_64)        TRIPLE="x86_64-unknown-linux-gnu"  ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

TARBALL_NAME="uv-${TRIPLE}.tar.gz"

echo "uv installation"
echo "  Version:      ${UV_VERSION}"
echo "  Architecture: ${ARCH}"
echo "  Tarball:      ${BASE_URL}/${TARBALL_NAME}"
echo ""

# ---------------------------------------------------------------------------
# Temporary directory (cleaned up on exit)
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

TARBALL_PATH="${TMP_DIR}/${TARBALL_NAME}"

# ---------------------------------------------------------------------------
# Download tarball and verify SHA256
# ---------------------------------------------------------------------------

echo "Fetching SHA256 checksum ..."
EXPECTED="$(wget -qO- "${BASE_URL}/${TARBALL_NAME}.sha256" | awk '{print $1}')"

if [ -z "${EXPECTED}" ]; then
    echo "ERROR: Could not fetch checksum for ${TARBALL_NAME}" >&2
    exit 1
fi

echo "Downloading and verifying tarball ..."
download_and_verify "${BASE_URL}/${TARBALL_NAME}" "${TARBALL_PATH}" "${EXPECTED}"
echo ""

# ---------------------------------------------------------------------------
# Extract and install
# ---------------------------------------------------------------------------

echo "Extracting tarball ..."
tar -xzf "${TARBALL_PATH}" -C "${TMP_DIR}"

EXTRACT_DIR="${TMP_DIR}/uv-${TRIPLE}"

for BINARY in uv uvx; do
    BINARY_PATH="${EXTRACT_DIR}/${BINARY}"
    if [ ! -f "${BINARY_PATH}" ]; then
        echo "ERROR: ${BINARY} not found in tarball at ${BINARY_PATH}" >&2
        exit 1
    fi
    echo "Installing ${BINARY} to ${INSTALL_DIR}/${BINARY} ..."
    chmod +x "${BINARY_PATH}"
    cp "${BINARY_PATH}" "${INSTALL_DIR}/${BINARY}"
done

echo ""
echo "Done: $("${INSTALL_DIR}/uv" version)"