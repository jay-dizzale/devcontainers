#!/bin/sh
# install-snyk.sh
# Installs the Snyk CLI for dependency and container vulnerability scanning.
# Binary + SHA256 sidecar published on GitHub releases.

set -eu

. /usr/local/lib/shell/download-utils.sh

SNYK_VERSION="${SNYK_VERSION:-}"
if [ -z "${SNYK_VERSION}" ]; then
    echo "Resolving latest Snyk release ..."
    SNYK_VERSION="$(github_latest_stable snyk/snyk)"
    [ -n "${SNYK_VERSION}" ] || { echo "ERROR: could not resolve latest Snyk version" >&2; exit 1; }
fi

ARCH="$(uname -m)"
case "${ARCH}" in
    aarch64) BINARY="snyk-linux-arm64" ;;
    x86_64)  BINARY="snyk-linux"       ;;
    *) echo "ERROR: Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac

BASE_URL="https://github.com/snyk/snyk/releases/download/v${SNYK_VERSION}"

echo "Downloading Snyk ${SNYK_VERSION} (${ARCH}) ..."
SHA256="$(wget -qO- "${BASE_URL}/${BINARY}.sha256" 2>/dev/null | awk '{print $1}')"
[ -n "${SHA256}" ] || { echo "ERROR: could not fetch Snyk SHA256" >&2; exit 1; }

download_and_verify "${BASE_URL}/${BINARY}" "/tmp/${BINARY}" "${SHA256}"

install -m 755 "/tmp/${BINARY}" /usr/local/bin/snyk
rm -f "/tmp/${BINARY}"

echo "OK: snyk $(snyk --version) installed"
