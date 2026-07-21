#!/bin/sh
# install-dotnet.sh — Installs .NET SDK and ASP.NET Runtime via official tarballs
#
# SHA512 hashes are fetched automatically from Microsoft — no manual copying required.
#
# Usage:
#   ./install-dotnet.sh <sdk-version> <runtime-version>
#
# Or via environment variables:
#   DOTNET_SDK_VERSION=10.0.105 DOTNET_RUNTIME_VERSION=10.0.5 ./install-dotnet.sh
#
# Installs to /usr/local/dotnet (configurable via DOTNET_INSTALL_DIR)

set -e

. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

DOTNET_SDK_VERSION="${1:-${DOTNET_SDK_VERSION:-}}"
DOTNET_RUNTIME_VERSION="${2:-${DOTNET_RUNTIME_VERSION:-}}"

DOTNET_INSTALL_DIR="${DOTNET_INSTALL_DIR:-/usr/local/dotnet}"
DOTNET_BASE_URL="https://dotnetcli.azureedge.net/dotnet"

if [ -z "${DOTNET_SDK_VERSION}" ]; then
    echo "Resolving latest .NET LTS SDK version ..."
    DOTNET_SDK_VERSION="$(wget -qO- "${DOTNET_BASE_URL}/Sdk/LTS/latest.version" 2>/dev/null | tr -d '[:space:]')"
    [ -n "${DOTNET_SDK_VERSION}" ] || { echo "ERROR: could not resolve latest .NET SDK version" >&2; exit 1; }
fi
if [ -z "${DOTNET_RUNTIME_VERSION}" ]; then
    echo "Resolving latest .NET LTS runtime version ..."
    DOTNET_RUNTIME_VERSION="$(wget -qO- "${DOTNET_BASE_URL}/Runtime/LTS/latest.version" 2>/dev/null | tr -d '[:space:]')"
    [ -n "${DOTNET_RUNTIME_VERSION}" ] || { echo "ERROR: could not resolve latest .NET runtime version" >&2; exit 1; }
fi

# Detect architecture
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  DOTNET_ARCH="x64" ;;
  aarch64) DOTNET_ARCH="arm64" ;;
  armv7l)  DOTNET_ARCH="arm" ;;
  *)
    echo "ERROR: Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

SDK_FILENAME="dotnet-sdk-${DOTNET_SDK_VERSION}-linux-${DOTNET_ARCH}.tar.gz"
RUNTIME_FILENAME="aspnetcore-runtime-${DOTNET_RUNTIME_VERSION}-linux-${DOTNET_ARCH}.tar.gz"

SDK_URL="${DOTNET_BASE_URL}/Sdk/${DOTNET_SDK_VERSION}/${SDK_FILENAME}"
RUNTIME_URL="${DOTNET_BASE_URL}/aspnetcore/Runtime/${DOTNET_RUNTIME_VERSION}/${RUNTIME_FILENAME}"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
download_and_install() {
  url="$1"
  label="$2"
  tmpfile="$(mktemp /tmp/dotnet-XXXXXX.tar.gz)"

  # Fetch hash from Microsoft
  expected_sha="$(fetch_sha512 "${url}" "${label}")"

  # Download tarball
  echo "Downloading ${label} ..."
  wget -q --show-progress "${url}" -O "${tmpfile}"

  # Verify
  verify_sha512 "${tmpfile}" "${expected_sha}" "${label}"

  # Extract
  echo "Extracting ${label} to ${DOTNET_INSTALL_DIR} ..."
  mkdir -p "${DOTNET_INSTALL_DIR}"
  tar -xzf "${tmpfile}" -C "${DOTNET_INSTALL_DIR}"

  rm "${tmpfile}"
  echo ""
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

echo ".NET Installation"
echo "  SDK Version:      ${DOTNET_SDK_VERSION} (${DOTNET_ARCH})"
echo "  Runtime Version:  ${DOTNET_RUNTIME_VERSION} (${DOTNET_ARCH})"
echo "  Install path:     ${DOTNET_INSTALL_DIR}"
echo ""

download_and_install "${SDK_URL}"     "dotnet-sdk-${DOTNET_SDK_VERSION}"
download_and_install "${RUNTIME_URL}" "aspnetcore-runtime-${DOTNET_RUNTIME_VERSION}"

# ---------------------------------------------------------------------------
# Set up PATH
# ---------------------------------------------------------------------------

if [ ! -f /usr/local/bin/dotnet ]; then
  ln -s "${DOTNET_INSTALL_DIR}/dotnet" /usr/local/bin/dotnet
fi

echo "Done: installation complete"
dotnet --version