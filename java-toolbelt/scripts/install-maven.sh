#!/bin/sh
# install-maven.sh
# Installs Apache Maven.
# Version is expected via ARG/ENV: MAVEN_VERSION (e.g. 3.9.11)
# Apache Maven publishes a .sha512 sidecar for every release tarball.
# Uses the same CDN/archive fallback as install-kafka.sh since dlcdn.apache.org
# only hosts the current release.
# Dependencies: wget, sha512sum, tar

. /usr/local/lib/shell/download-utils.sh

MAVEN_VERSION="${1:-${MAVEN_VERSION:-}}"
if [ -z "${MAVEN_VERSION}" ]; then
    echo "Resolving latest stable Maven release ..."
    # apache/maven publishes RCs without marking them as pre-releases on GitHub,
    # so filter explicitly for tags matching the X.Y.Z stable pattern.
    MAVEN_VERSION="$(github_latest_matching apache/maven '^[0-9]+\.[0-9]+\.[0-9]+$' maven-)"
    [ -n "${MAVEN_VERSION}" ] || { echo "ERROR: could not resolve latest Maven version" >&2; exit 1; }
fi

MAVEN_MAJOR="$(echo "${MAVEN_VERSION}" | cut -d. -f1)"
MAVEN_TARBALL="apache-maven-${MAVEN_VERSION}-bin.tar.gz"
MAVEN_DIR="apache-maven-${MAVEN_VERSION}"
MAVEN_INSTALL_DIR="/opt/maven"

MAVEN_CDN_URL="https://dlcdn.apache.org/maven/maven-${MAVEN_MAJOR}/${MAVEN_VERSION}/binaries/${MAVEN_TARBALL}"
MAVEN_ARCHIVE_URL="https://archive.apache.org/dist/maven/maven-${MAVEN_MAJOR}/${MAVEN_VERSION}/binaries/${MAVEN_TARBALL}"

if wget -q --spider "${MAVEN_CDN_URL}" 2>/dev/null; then
    MAVEN_URL="${MAVEN_CDN_URL}"
    echo "Using CDN mirror for Maven ${MAVEN_VERSION}"
else
    MAVEN_URL="${MAVEN_ARCHIVE_URL}"
    echo "CDN mirror unavailable, using archive for Maven ${MAVEN_VERSION}"
fi

# ---------------------------------------------------------------------------
# Download & verify via SHA512 sidecar
# Apache's .sha512 format: "FILENAME: HASH_SPLIT\nACROSS\nLINES"
# Strip the "filename:" prefix and all whitespace to get the plain hex hash.
# ---------------------------------------------------------------------------
echo "Fetching SHA512 for Maven ${MAVEN_VERSION} ..."
MAVEN_SHA512="$(wget -qO- "${MAVEN_URL}.sha512" \
    | tr -d ' \n\r' \
    | sed 's/^[^:]*://')" || {
    echo "ERROR: Could not fetch SHA512 for Maven ${MAVEN_VERSION}" >&2
    exit 1
}

download_file "${MAVEN_URL}" "/tmp/${MAVEN_TARBALL}" || exit 1

verify_sha512 "/tmp/${MAVEN_TARBALL}" "${MAVEN_SHA512}" "Maven ${MAVEN_VERSION}" || {
    rm -f "/tmp/${MAVEN_TARBALL}"
    exit 1
}

# ---------------------------------------------------------------------------
# Extract & install
# ---------------------------------------------------------------------------
mkdir -p "${MAVEN_INSTALL_DIR}"
tar -xzf "/tmp/${MAVEN_TARBALL}" \
    --strip-components=1 \
    -C "${MAVEN_INSTALL_DIR}"
rm -f "/tmp/${MAVEN_TARBALL}"

echo "OK: Maven ${MAVEN_VERSION} installed to ${MAVEN_INSTALL_DIR}"