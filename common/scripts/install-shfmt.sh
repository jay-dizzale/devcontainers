#!/bin/sh
# install-shfmt.sh
# Downloads a pinned shfmt binary from GitHub releases (mvdan/sh),
# verifies it against the SHA256 digest GitHub's release API publishes for the
# asset, and installs it.
#
# Usage:
#   ./install-shfmt.sh <version>
#
# Or via environment variable:
#   SHFMT_VERSION=3.10.0 ./install-shfmt.sh
#
# Dependencies: wget, sha256sum, jq
set -eu
. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
SHFMT_VERSION="${1:-${SHFMT_VERSION:-}}"
if [ -z "${SHFMT_VERSION}" ]; then
    echo "Resolving latest shfmt release ..."
    SHFMT_VERSION="$(github_latest_stable mvdan/sh)"
    [ -n "${SHFMT_VERSION}" ] || { echo "ERROR: could not resolve latest shfmt version" >&2; exit 1; }
fi
BASE_URL="https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}"
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

BINARY_NAME="shfmt_v${SHFMT_VERSION}_linux_${ARCH}"

echo "shfmt installation"
echo "  Version:      ${SHFMT_VERSION}"
echo "  Architecture: ${ARCH}"
echo "  Binary:       ${BASE_URL}/${BINARY_NAME}"
echo ""

# ---------------------------------------------------------------------------
# Temporary directory (cleaned up on exit)
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
BINARY_PATH="${TMP_DIR}/${BINARY_NAME}"

# ---------------------------------------------------------------------------
# Look up the expected SHA256 from the release API (recent shfmt releases
# no longer ship a sha256sums.txt), then download and verify
# ---------------------------------------------------------------------------
echo "Fetching asset digest ..."
EXPECTED="$(_github_wget -qO- "https://api.github.com/repos/mvdan/sh/releases/tags/v${SHFMT_VERSION}" 2>/dev/null \
    | jq -r --arg n "${BINARY_NAME}" '.assets[] | select(.name == $n) | .digest // empty')"
EXPECTED="${EXPECTED#sha256:}"
[ -n "${EXPECTED}" ] || { echo "ERROR: no SHA256 digest for ${BINARY_NAME} in v${SHFMT_VERSION}" >&2; exit 1; }

echo "Downloading and verifying binary ..."
download_and_verify "${BASE_URL}/${BINARY_NAME}" "${BINARY_PATH}" "${EXPECTED}"

echo ""

# ---------------------------------------------------------------------------
# Install binary
# ---------------------------------------------------------------------------
echo "Installing shfmt to ${INSTALL_DIR}/shfmt ..."
install -m 755 "${BINARY_PATH}" "${INSTALL_DIR}/shfmt"

echo ""
echo "Done: shfmt installed successfully"
"${INSTALL_DIR}/shfmt" --version
