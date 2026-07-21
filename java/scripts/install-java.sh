#!/bin/sh
# install-java.sh
# Installs Amazon Corretto JDK.
# Version is expected via ARG/ENV: JAVA_VERSION (major version only, e.g. 21)
# Corretto publishes SHA256 checksums under the /downloads/latest_checksum/ path.
# Dependencies: wget, sha256sum, dpkg, apt-get

. /usr/local/lib/shell/download-utils.sh

JAVA_VERSION="${1:-${JAVA_VERSION:-}}"
if [ -z "${JAVA_VERSION}" ]; then
    echo "Resolving latest Java LTS major ..."
    # Corretto tracks each major in a separate repo; find the newest with a recent release.
    # Java LTS releases: 8, 11, 17, 21, 25, ... — check latest known LTS majors newest-first.
    for _major in 25 21 17; do
        _tag="$(wget -qO- "https://api.github.com/repos/corretto/corretto-${_major}/releases/latest" 2>/dev/null \
            | jq -r '.tag_name // empty')"
        if [ -n "${_tag}" ]; then
            JAVA_VERSION="${_major}"
            break
        fi
    done
    [ -n "${JAVA_VERSION}" ] || { echo "ERROR: could not resolve latest Java LTS major" >&2; exit 1; }
    echo "Resolved Java LTS major: ${JAVA_VERSION}"
fi

# ---------------------------------------------------------------------------
# Arch detection
# ---------------------------------------------------------------------------
MACHINE_TYPE="$(uname -m)"
case "${MACHINE_TYPE}" in
    aarch64) CORRETTO_ARCH="aarch64" ;;
    x86_64)  CORRETTO_ARCH="x64"     ;;
    *)
        echo "ERROR: Unsupported architecture: ${MACHINE_TYPE}" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Amazon Corretto
# SHA256 is served from /downloads/latest_checksum/, not /downloads/latest/
# ---------------------------------------------------------------------------
CORRETTO_DEB="amazon-corretto-${JAVA_VERSION}-${CORRETTO_ARCH}-linux-jdk.deb"
CORRETTO_URL="https://corretto.aws/downloads/latest/${CORRETTO_DEB}"
CORRETTO_SHA256_URL="https://corretto.aws/downloads/latest_sha256/${CORRETTO_DEB}"

echo "Fetching Corretto ${JAVA_VERSION} SHA256 checksum ..."
CORRETTO_SHA256="$(wget -qO- "${CORRETTO_SHA256_URL}" | awk '{print $1}')" || {
    echo "ERROR: Could not fetch SHA256 for Corretto ${JAVA_VERSION}" >&2
    exit 1
}

apt-get install -qqy java-common

download_and_verify "${CORRETTO_URL}" "/tmp/${CORRETTO_DEB}" "${CORRETTO_SHA256}"

dpkg -i "/tmp/${CORRETTO_DEB}"
rm -f "/tmp/${CORRETTO_DEB}"