#!/bin/sh
# install-spacectl.sh
# Installs spacectl (Spacelift CLI).
# Version is expected via ARG/ENV: SPACECTL_VERSION (without leading 'v').
# spacectl publishes a SHA256SUMS file and a .sig for GPG verification.
# Dependencies: wget, sha256sum, unzip, gpg

. /usr/local/lib/shell/download-utils.sh

SPACECTL_VERSION="${1:-${SPACECTL_VERSION:-}}"
if [ -z "${SPACECTL_VERSION}" ]; then
    echo "Resolving latest stable spacectl release ..."
    SPACECTL_VERSION="$(github_latest_stable spacelift-io/spacectl)"
    [ -n "${SPACECTL_VERSION}" ] || { echo "ERROR: could not resolve latest spacectl version" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Arch detection
# ---------------------------------------------------------------------------
MACHINE_TYPE="$(uname -m)"
case "${MACHINE_TYPE}" in
    aarch64) SPACECTL_ARCH="arm64" ;;
    x86_64)  SPACECTL_ARCH="amd64" ;;
    *)
        echo "ERROR: Unsupported architecture: ${MACHINE_TYPE}" >&2
        exit 1
        ;;
esac

SPACECTL_ZIP="spacectl_${SPACECTL_VERSION}_linux_${SPACECTL_ARCH}.zip"
SPACECTL_BASE_URL="https://github.com/spacelift-io/spacectl/releases/download/v${SPACECTL_VERSION}"
SPACECTL_URL="${SPACECTL_BASE_URL}/${SPACECTL_ZIP}"
SHA256SUMS_FILE="spacectl_${SPACECTL_VERSION}_SHA256SUMS"
SHA256SUMS_URL="${SPACECTL_BASE_URL}/${SHA256SUMS_FILE}"
SHA256SUMS_SIG_URL="${SHA256SUMS_URL}.sig"
KEY_URL="${SPACECTL_BASE_URL}/key.asc"

# ---------------------------------------------------------------------------
# Fetch & verify SHA256SUMS via GPG signature
# ---------------------------------------------------------------------------
download_file "${SHA256SUMS_URL}"     "/tmp/${SHA256SUMS_FILE}"     || exit 1
download_file "${SHA256SUMS_SIG_URL}" "/tmp/${SHA256SUMS_FILE}.sig" || exit 1
download_file "${KEY_URL}"            "/tmp/spacectl-key.asc"       || exit 1

SPACECTL_KEYRING="/tmp/spacectl-$$.gpg"
gpg --dearmor < /tmp/spacectl-key.asc > "${SPACECTL_KEYRING}" 2>/dev/null || {
    echo "ERROR: Failed to import spacectl GPG key" >&2
    rm -f /tmp/spacectl-key.asc "${SPACECTL_KEYRING}"
    exit 1
}

gpg --no-default-keyring --keyring "${SPACECTL_KEYRING}" \
    --verify "/tmp/${SHA256SUMS_FILE}.sig" "/tmp/${SHA256SUMS_FILE}" 2>/dev/null || {
    echo "ERROR: GPG signature verification failed for ${SHA256SUMS_FILE}" >&2
    rm -f /tmp/spacectl-key.asc "${SPACECTL_KEYRING}" "/tmp/${SHA256SUMS_FILE}" "/tmp/${SHA256SUMS_FILE}.sig"
    exit 1
}
echo "OK: GPG signature verified: ${SHA256SUMS_FILE}"
rm -f /tmp/spacectl-key.asc "${SPACECTL_KEYRING}"

# ---------------------------------------------------------------------------
# Download zip and verify SHA256 against the verified SHA256SUMS file
# ---------------------------------------------------------------------------
SPACECTL_SHA256="$(awk -v f="${SPACECTL_ZIP}" '$2==f || $2=="*"f {print $1}' "/tmp/${SHA256SUMS_FILE}")"
if [ -z "${SPACECTL_SHA256}" ]; then
    echo "ERROR: No checksum entry found for ${SPACECTL_ZIP}" >&2
    rm -f "/tmp/${SHA256SUMS_FILE}" "/tmp/${SHA256SUMS_FILE}.sig"
    exit 1
fi

download_and_verify "${SPACECTL_URL}" "/tmp/${SPACECTL_ZIP}" "${SPACECTL_SHA256}" || {
    rm -f "/tmp/${SHA256SUMS_FILE}" "/tmp/${SHA256SUMS_FILE}.sig"
    exit 1
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
unzip -qq "/tmp/${SPACECTL_ZIP}" -d /tmp/spacectl
install -m 0755 /tmp/spacectl/spacectl /usr/bin/spacectl
rm -rf "/tmp/${SPACECTL_ZIP}" "/tmp/${SHA256SUMS_FILE}" "/tmp/${SHA256SUMS_FILE}.sig" /tmp/spacectl

echo "OK: spacectl ${SPACECTL_VERSION} installed"