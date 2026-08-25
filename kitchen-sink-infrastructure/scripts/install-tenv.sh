#!/bin/sh
# install-tenv.sh
# Installs tenv (Terraform/OpenTofu version manager).
# Version is expected via ARG/ENV:
#   TENV_VERSION  e.g. 4.1.0  (without leading 'v')
# Verification: SHA256 of the .deb against the upstream checksums.txt
# fetched over HTTPS.
# Dependencies: wget, sha256sum, dpkg, awk

. /usr/local/lib/shell/download-utils.sh

TENV_VERSION="${1:-${TENV_VERSION:-}}"
if [ -z "${TENV_VERSION}" ]; then
    echo "Resolving latest stable tenv release ..."
    TENV_VERSION="$(github_latest_stable tofuutils/tenv)"
    [ -n "${TENV_VERSION}" ] || { echo "ERROR: could not resolve latest tenv version" >&2; exit 1; }
fi
ARCHITECTURE="$(dpkg --print-architecture)"

TENV_DEB="tenv_v${TENV_VERSION}_${ARCHITECTURE}.deb"
TENV_BASE_URL="https://github.com/tofuutils/tenv/releases/download/v${TENV_VERSION}"
TENV_URL="${TENV_BASE_URL}/${TENV_DEB}"
CHECKSUMS_URL="${TENV_BASE_URL}/tenv_v${TENV_VERSION}_checksums.txt"

# ---------------------------------------------------------------------------
# Download the checksums file over HTTPS
# ---------------------------------------------------------------------------
download_file "${CHECKSUMS_URL}" "/tmp/tenv_checksums.txt" || exit 1

# ---------------------------------------------------------------------------
# Extract the expected SHA256 for our .deb from the checksums file
# ---------------------------------------------------------------------------
EXPECTED_SHA256="$(awk -v f="${TENV_DEB}" '$2 == f {print $1}' /tmp/tenv_checksums.txt)"
if [ -z "${EXPECTED_SHA256}" ]; then
    echo "ERROR: No checksum entry found for ${TENV_DEB}" >&2
    rm -f /tmp/tenv_checksums.txt
    exit 1
fi

# ---------------------------------------------------------------------------
# Download .deb and verify SHA256 against the checksums file
# ---------------------------------------------------------------------------
download_and_verify "${TENV_URL}" "/tmp/${TENV_DEB}" "${EXPECTED_SHA256}" || {
    rm -f /tmp/tenv_checksums.txt
    exit 1
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
dpkg -i "/tmp/${TENV_DEB}"
rm -f /tmp/tenv_checksums.txt "/tmp/${TENV_DEB}"

echo "OK: tenv v${TENV_VERSION} installed"