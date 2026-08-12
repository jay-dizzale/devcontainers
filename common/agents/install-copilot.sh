#!/bin/sh
# install-copilot.sh
# Downloads a pinned GitHub Copilot CLI tarball from GitHub releases,
# verifies its SHA256 checksum, and installs it.
#
# Usage:
#   ./install-copilot.sh <version>
#
# Or via environment variable:
#   COPILOT_VERSION=1.0.79 ./install-copilot.sh
#
# Notes:
#   - Authenticates using GH_TOKEN or GITHUB_TOKEN at runtime (checked in
#     that order) — no separate Copilot-specific login step is needed.
#
# Dependencies: wget, sha256sum, tar, awk
set -eu
. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
COPILOT_VERSION="${1:-${COPILOT_VERSION:-}}"
if [ -z "${COPILOT_VERSION}" ]; then
    echo "Resolving latest GitHub Copilot CLI release ..."
    COPILOT_VERSION="$(github_latest_stable github/copilot-cli)"
    [ -n "${COPILOT_VERSION}" ] || { echo "ERROR: could not resolve latest Copilot CLI version" >&2; exit 1; }
fi
BASE_URL="https://github.com/github/copilot-cli/releases/download/v${COPILOT_VERSION}"
INSTALL_DIR="/usr/local/bin"

# ---------------------------------------------------------------------------
# Detect architecture
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
case "${ARCH}" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x64"   ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

TARBALL_NAME="copilot-linux-${ARCH}.tar.gz"

echo "GitHub Copilot CLI installation"
echo "  Version:      ${COPILOT_VERSION}"
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
# Download tarball and checksums
# ---------------------------------------------------------------------------
echo "Downloading tarball and checksums ..."
download_file "${BASE_URL}/${TARBALL_NAME}" "${TARBALL_PATH}"

CHECKSUMS_PATH="${TMP_DIR}/SHA256SUMS.txt"
download_file "${BASE_URL}/SHA256SUMS.txt" "${CHECKSUMS_PATH}"

# ---------------------------------------------------------------------------
# Verify SHA256
# ---------------------------------------------------------------------------
EXPECTED="$(grep "${TARBALL_NAME}" "${CHECKSUMS_PATH}" | awk '{print $1}')"
verify_sha256 "${TARBALL_PATH}" "${EXPECTED}"
echo ""

# ---------------------------------------------------------------------------
# Extract and install
# ---------------------------------------------------------------------------
echo "Extracting tarball ..."
tar -xzf "${TARBALL_PATH}" -C "${TMP_DIR}"

echo "Installing copilot to ${INSTALL_DIR}/copilot ..."
chmod +x "${TMP_DIR}/copilot"
cp "${TMP_DIR}/copilot" "${INSTALL_DIR}/copilot"

echo ""
echo "Done: GitHub Copilot CLI installed successfully"
"${INSTALL_DIR}/copilot" --version || true
