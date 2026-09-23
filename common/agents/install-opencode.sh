#!/bin/sh
# install-opencode.sh
# Downloads a pinned opencode tarball from GitHub releases, verifies its
# SHA256 against the digest GitHub's release API publishes for the asset
# (opencode ships no separate checksum file), and installs it.
#
# Usage:
#   ./install-opencode.sh <version>
#
# Or via environment variable:
#   OPENCODE_VERSION=1.18.32 ./install-opencode.sh
#
# Notes:
#   - Installs the glibc Linux binary (linux-x64 / linux-arm64).
#
# Dependencies: wget, sha256sum, tar, jq
set -eu
. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
REPO="anomalyco/opencode"
OPENCODE_VERSION="${1:-${OPENCODE_VERSION:-}}"
OPENCODE_VERSION="${OPENCODE_VERSION#v}"
if [ -z "${OPENCODE_VERSION}" ]; then
    echo "Resolving latest opencode release ..."
    OPENCODE_VERSION="$(github_latest_stable "${REPO}")"
    [ -n "${OPENCODE_VERSION}" ] || { echo "ERROR: could not resolve latest opencode version" >&2; exit 1; }
fi
BASE_URL="https://github.com/${REPO}/releases/download/v${OPENCODE_VERSION}"
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

TARBALL_NAME="opencode-linux-${ARCH}.tar.gz"

echo "opencode installation"
echo "  Version:      ${OPENCODE_VERSION}"
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
# Look up the expected SHA256 from the release API
# ---------------------------------------------------------------------------
echo "Fetching asset digest ..."
EXPECTED="$(_github_wget -qO- "https://api.github.com/repos/${REPO}/releases/tags/v${OPENCODE_VERSION}" 2>/dev/null \
    | jq -r --arg n "${TARBALL_NAME}" '.assets[] | select(.name == $n) | .digest // empty')"
EXPECTED="${EXPECTED#sha256:}"
[ -n "${EXPECTED}" ] || { echo "ERROR: no SHA256 digest for ${TARBALL_NAME} in v${OPENCODE_VERSION}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Download and verify
# ---------------------------------------------------------------------------
echo "Downloading and verifying tarball ..."
download_and_verify "${BASE_URL}/${TARBALL_NAME}" "${TARBALL_PATH}" "${EXPECTED}"
echo ""

# ---------------------------------------------------------------------------
# Extract and install
# ---------------------------------------------------------------------------
echo "Extracting tarball ..."
tar -xzf "${TARBALL_PATH}" -C "${TMP_DIR}"

echo "Installing opencode to ${INSTALL_DIR}/opencode ..."
chmod +x "${TMP_DIR}/opencode"
cp "${TMP_DIR}/opencode" "${INSTALL_DIR}/opencode"

echo ""
echo "Done: opencode installed successfully"
"${INSTALL_DIR}/opencode" --version || true
