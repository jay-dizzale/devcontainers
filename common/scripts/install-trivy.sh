#!/bin/sh
# install-trivy.sh
# Downloads a pinned Trivy tarball from GitHub releases,
# verifies its SHA256 checksum, and installs it.
#
# Usage:
#   ./install-trivy.sh <version>
#
# Or via environment variable:
#   TRIVY_VERSION=0.55.0 ./install-trivy.sh
#
# Dependencies: wget, sha256sum, tar, awk
set -eu
. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
TRIVY_VERSION="${1:-${TRIVY_VERSION:-}}"
if [ -z "${TRIVY_VERSION}" ]; then
    echo "Resolving latest Trivy release ..."
    TRIVY_VERSION="$(github_latest_stable aquasecurity/trivy)"
    [ -n "${TRIVY_VERSION}" ] || { echo "ERROR: could not resolve latest Trivy version" >&2; exit 1; }
fi
BASE_URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}"
INSTALL_DIR="/usr/local/bin"

# ---------------------------------------------------------------------------
# Detect architecture
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"
case "${ARCH}" in
    arm64|aarch64) ARCH="ARM64"   ;;
    x86_64)        ARCH="64bit"  ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

TARBALL_NAME="trivy_${TRIVY_VERSION}_Linux-${ARCH}.tar.gz"

echo "Trivy installation"
echo "  Version:      ${TRIVY_VERSION}"
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
download_file "${BASE_URL}/trivy_${TRIVY_VERSION}_checksums.txt" "${CHECKSUMS_PATH}"

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

echo "Installing trivy to ${INSTALL_DIR}/trivy ..."
chmod +x "${TMP_DIR}/trivy"
cp "${TMP_DIR}/trivy" "${INSTALL_DIR}/trivy"

echo ""
echo "Done: trivy installed successfully"
"${INSTALL_DIR}/trivy" --version
