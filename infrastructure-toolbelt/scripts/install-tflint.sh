#!/bin/sh
# install-tflint.sh
# Installs TFLint.
# Version is expected via ARG/ENV: TFLINT_VERSION (without leading 'v').

. /usr/local/lib/shell/download-utils.sh

TFLINT_VERSION="${1:-${TFLINT_VERSION:-}}"
if [ -z "${TFLINT_VERSION}" ]; then
    echo "Resolving latest stable tflint release ..."
    TFLINT_VERSION="$(github_latest_stable terraform-linters/tflint)"
    [ -n "${TFLINT_VERSION}" ] || { echo "ERROR: could not resolve latest tflint version" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Arch detection
# tflint uses 'linux' + GOARCH naming in its release filenames.
# ---------------------------------------------------------------------------
MACHINE_TYPE="$(uname -m)"
case "${MACHINE_TYPE}" in
    aarch64) TFLINT_ARCH="arm64"  ;;
    x86_64)  TFLINT_ARCH="amd64"  ;;
    *)
        echo "ERROR: Unsupported architecture: ${MACHINE_TYPE}" >&2
        exit 1
        ;;
esac

TFLINT_ZIP="tflint_linux_${TFLINT_ARCH}.zip"
TFLINT_BASE_URL="https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}"
TFLINT_URL="${TFLINT_BASE_URL}/${TFLINT_ZIP}"
CHECKSUMS_URL="${TFLINT_BASE_URL}/checksums.txt"

# ---------------------------------------------------------------------------
# Download & verify via SHA256SUMS file
# ---------------------------------------------------------------------------
echo "Fetching tflint SHA256 checksum ..."
TFLINT_SHA256="$(wget -qO- "${CHECKSUMS_URL}" \
    | awk -v file="${TFLINT_ZIP}" '$2 == file {print $1}')" || {
    echo "ERROR: Could not fetch checksums for tflint ${TFLINT_VERSION}" >&2
    exit 1
}

if [ -z "${TFLINT_SHA256}" ]; then
    echo "ERROR: No checksum entry found for ${TFLINT_ZIP}" >&2
    exit 1
fi

download_and_verify "${TFLINT_URL}" "/tmp/${TFLINT_ZIP}" "${TFLINT_SHA256}"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
unzip -qq "/tmp/${TFLINT_ZIP}" -d /tmp/tflint
install -m 0755 /tmp/tflint/tflint /usr/bin/tflint
rm -rf "/tmp/${TFLINT_ZIP}" /tmp/tflint

echo "OK: tflint v${TFLINT_VERSION} installed"