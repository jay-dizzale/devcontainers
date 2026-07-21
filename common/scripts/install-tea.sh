#!/bin/sh
# install-tea.sh
# Downloads a pinned tea binary for Linux from dl.gitea.com,
# verifies it against the official checksums.txt, and installs it.
#
# Usage:
#   ./install-tea.sh <version>
#
# Or via environment variable:
#   TEA_VERSION=0.11.0 ./install-tea.sh

set -eu

. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

TEA_VERSION="${1:-${TEA_VERSION:-}}"
if [ -z "${TEA_VERSION}" ]; then
    echo "Resolving latest tea release ..."
    TEA_VERSION="$(wget -qO- 'https://gitea.com/api/v1/repos/gitea/tea/releases?limit=1&type=releases' 2>/dev/null \
        | jq -r '.[0].tag_name | ltrimstr("v")')"
    [ -n "${TEA_VERSION}" ] || { echo "ERROR: could not resolve latest tea version" >&2; exit 1; }
fi
BASE_URL="https://dl.gitea.com/tea/${TEA_VERSION}"
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

BINARY_NAME="tea-${TEA_VERSION}-linux-${ARCH}"

echo "tea installation"
echo "  Version:      ${TEA_VERSION}"
echo "  Architecture: ${ARCH}"
echo "  Binary:       ${BASE_URL}/${BINARY_NAME}"
echo ""

# ---------------------------------------------------------------------------
# Temporary directory (cleaned up on exit)
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BINARY_PATH="${TMP_DIR}/${BINARY_NAME}"
CHECKSUMS_PATH="${TMP_DIR}/checksums.txt"

# ---------------------------------------------------------------------------
# Download checksums file and binary, then verify
# ---------------------------------------------------------------------------

echo "Fetching checksums.txt ..."
download_file "${BASE_URL}/checksums.txt" "${CHECKSUMS_PATH}"

EXPECTED="$(grep "${BINARY_NAME}$" "${CHECKSUMS_PATH}" | awk '{print $1}')"

if [ -z "${EXPECTED}" ]; then
  echo "ERROR: No checksum entry found for ${BINARY_NAME} in checksums.txt" >&2
  exit 1
fi

echo "Downloading and verifying binary ..."
download_and_verify "${BASE_URL}/${BINARY_NAME}" "${BINARY_PATH}" "${EXPECTED}"

echo ""

# ---------------------------------------------------------------------------
# Install binary
# ---------------------------------------------------------------------------

echo "Installing tea to ${INSTALL_DIR}/tea ..."
chmod +x "${BINARY_PATH}"

if [ -w "${INSTALL_DIR}" ]; then
  cp "${BINARY_PATH}" "${INSTALL_DIR}/tea"
else
  sudo cp "${BINARY_PATH}" "${INSTALL_DIR}/tea"
fi

echo ""
echo "Done: tea installed successfully"
"${INSTALL_DIR}/tea" --version