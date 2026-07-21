#!/bin/sh
# install-gh.sh
# Downloads a pinned GitHub CLI tarball from GitHub releases,
# verifies its SHA256 checksum, and installs it.
#
# Usage:
#   ./install-gh.sh <version>
#
# Or via environment variable:
#   GH_VERSION=2.62.0 ./install-gh.sh
#
# Dependencies: wget, sha256sum, tar, awk
set -eu
. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
GH_VERSION="${1:-${GH_VERSION:-}}"
if [ -z "${GH_VERSION}" ]; then
    echo "Resolving latest gh release ..."
    GH_VERSION="$(github_latest_stable cli/cli)"
    [ -n "${GH_VERSION}" ] || { echo "ERROR: could not resolve latest gh version" >&2; exit 1; }
fi
BASE_URL="https://github.com/cli/cli/releases/download/v${GH_VERSION}"
INSTALL_DIR="/usr/local/bin"

# ---------------------------------------------------------------------------
# Detect architecture
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
case "${ARCH}" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64)        ARCH="amd64" ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

TARBALL_NAME="gh_${GH_VERSION}_linux_${ARCH}.tar.gz"

echo "GitHub CLI installation"
echo "  Version:      ${GH_VERSION}"
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

CHECKSUMS_PATH="${TMP_DIR}/checksums.txt"
download_file "${BASE_URL}/gh_${GH_VERSION}_checksums.txt" "${CHECKSUMS_PATH}"

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

BINARY_PATH="${TMP_DIR}/gh_${GH_VERSION}_linux_${ARCH}/bin/gh"
echo "Installing gh to ${INSTALL_DIR}/gh ..."
chmod +x "${BINARY_PATH}"
cp "${BINARY_PATH}" "${INSTALL_DIR}/gh"

echo ""
echo "Done: gh installed successfully"
"${INSTALL_DIR}/gh" --version