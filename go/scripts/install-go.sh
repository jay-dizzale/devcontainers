#!/bin/sh
# install-go.sh
# Downloads a pinned Go tarball from dl.google.com, verifies its SHA256
# checksum, installs it, then builds and installs the latest Delve debugger
# (dlv) from source using the freshly installed toolchain.
#
# Usage:
#   ./install-go.sh <version>
#
# Or via environment variable:
#   GO_VERSION=1.24.1 ./install-go.sh
#
# Dependencies: wget, sha256sum, tar, git, awk

set -eu

. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
GO_VERSION="${1:-${GO_VERSION:-}}"
if [ -z "${GO_VERSION}" ]; then
    echo "Resolving latest stable Go release ..."
    GO_VERSION="$(wget -qO- 'https://go.dev/dl/?mode=json' 2>/dev/null \
        | jq -r '.[0].version | ltrimstr("go")')"
    [ -n "${GO_VERSION}" ] || { echo "ERROR: could not resolve latest Go version" >&2; exit 1; }
fi

BASE_URL="https://dl.google.com/go"
INSTALL_DIR="/usr/local"

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

TARBALL_NAME="go${GO_VERSION}.linux-${ARCH}.tar.gz"

echo "Go installation"
echo "  Version:      ${GO_VERSION}"
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
# dl.google.com publishes a .sha256 sidecar alongside every release tarball.
EXPECTED="$(wget -qO- "${BASE_URL}/${TARBALL_NAME}.sha256")" || {
    echo "ERROR: Could not fetch checksum for ${TARBALL_NAME}" >&2
    exit 1
}
EXPECTED="$(echo "${EXPECTED}" | awk '{print $1}')"

echo "Downloading and verifying tarball ..."
download_and_verify "${BASE_URL}/${TARBALL_NAME}" "${TARBALL_PATH}" "${EXPECTED}"
echo ""

# ---------------------------------------------------------------------------
# Extract and install
# ---------------------------------------------------------------------------
echo "Extracting tarball to ${INSTALL_DIR} ..."

# Remove any pre-existing Go installation to avoid stale files.
rm -rf "${INSTALL_DIR}/go"
tar -xzf "${TARBALL_PATH}" -C "${INSTALL_DIR}"

GO_BIN="${INSTALL_DIR}/go/bin/go"

if [ ! -x "${GO_BIN}" ]; then
    echo "ERROR: go binary not found at ${GO_BIN}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify installed Go version
# ---------------------------------------------------------------------------
echo "Verifying installed Go version ..."
INSTALLED_VERSION="$("${GO_BIN}" version | awk '{print $3}' | sed 's/go//')"

if [ "${INSTALLED_VERSION}" != "${GO_VERSION}" ]; then
    echo "ERROR: Go version mismatch" >&2
    echo "  Expected: ${GO_VERSION}" >&2
    echo "  Got:      ${INSTALLED_VERSION}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Symlink binaries into /usr/local/bin for PATH visibility
# ---------------------------------------------------------------------------
echo "Symlinking go and gofmt into /usr/local/bin ..."
ln -sf "${INSTALL_DIR}/go/bin/go"    /usr/local/bin/go
ln -sf "${INSTALL_DIR}/go/bin/gofmt" /usr/local/bin/gofmt

echo ""
echo "Done: $("${GO_BIN}" version)"
echo ""

# ---------------------------------------------------------------------------
# Install dlv (Delve debugger) from source
# ---------------------------------------------------------------------------
# Delve does not ship pre-built release binaries for the current tag, so we
# build from source using the toolchain installed above.
# proxy.golang.org is not reachable in this environment; GOPROXY=direct
# instructs the toolchain to clone from VCS (github.com) directly.
# GONOSUMDB=* skips the unreachable checksum database.
echo "Delve (dlv) installation"
echo "  Module:  github.com/go-delve/delve/cmd/dlv@latest"
echo ""

TMP_GOPATH="$(mktemp -d)"
# Extend the existing trap to also clean up the Go build cache.
trap 'rm -rf "${TMP_DIR}" "${TMP_GOPATH}"' EXIT

echo "Building dlv from source (GOPROXY=direct) ..."
GOPATH="${TMP_GOPATH}" \
GOBIN="${TMP_GOPATH}/bin" \
GOPROXY="direct" \
GONOSUMDB="*" \
    "${GO_BIN}" install github.com/go-delve/delve/cmd/dlv@latest

DLV_BINARY="${TMP_GOPATH}/bin/dlv"

if [ ! -x "${DLV_BINARY}" ]; then
    echo "ERROR: dlv binary not found after build" >&2
    exit 1
fi

echo "Installing dlv to /usr/local/bin/dlv ..."
cp "${DLV_BINARY}" /usr/local/bin/dlv

echo ""
echo "Done: $(/usr/local/bin/dlv version)"