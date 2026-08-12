#!/bin/sh
# install-claude-code.sh
# Downloads a pinned Claude Code binary from the Anthropic release bucket,
# verifies the manifest's GPG signature against the official release key
# (with a pinned fingerprint check), then verifies the binary's SHA256
# against the verified manifest, and installs it.
#
# Usage:
#   ./install-claude-code.sh <version>
#
# Or via environment variable:
#   CLAUDE_CODE_VERSION=2.1.89 ./install-claude-code.sh
#
# Notes:
#   - Manifest signatures are available for releases >= 2.1.89. Earlier
#     releases publish manifest.json without a detached signature and are
#     therefore not supported by this script.
#   - This installs the glibc Linux binary (linux-x64 / linux-arm64).
#     For musl distros (Alpine), the upstream tarball names are
#     linux-x64-musl / linux-arm64-musl and require libgcc, libstdc++,
#     and ripgrep — adapt the case statement below if you need that.
#   - To stop the installed binary from auto-updating itself out from under
#     your pinned version, set DISABLE_AUTOUPDATER=1 (background check
#     only) or DISABLE_UPDATES=1 (all update paths) in the user's env.
#
# Dependencies: wget, sha256sum, gpg, jq, awk

set -eu

. /usr/local/lib/shell/download-utils.sh

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

CLAUDE_CODE_VERSION="${1:-${CLAUDE_CODE_VERSION:-}}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION#v}"
if [ -z "${CLAUDE_CODE_VERSION}" ]; then
    echo "Resolving latest Claude Code release ..."
    CLAUDE_CODE_VERSION="$(wget -qO- 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest' 2>/dev/null \
        | jq -r '.version')"
    [ -n "${CLAUDE_CODE_VERSION}" ] || { echo "ERROR: could not resolve latest Claude Code version" >&2; exit 1; }
fi

REPO_URL="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}"
KEY_URL="https://downloads.claude.ai/keys/claude-code.asc"
INSTALL_DIR="/usr/local/bin"

# Pinned fingerprint of the Anthropic Claude Code release signing key.
# Source: https://code.claude.com/docs/en/setup#binary-integrity-and-code-signing
EXPECTED_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

# ---------------------------------------------------------------------------
# Detect architecture / platform key as it appears in manifest.json
# ---------------------------------------------------------------------------

ARCH="$(uname -m)"
case "${ARCH}" in
  arm64|aarch64) PLATFORM="linux-arm64" ;;
  x86_64)        PLATFORM="linux-x64"  ;;
  *)
    echo "ERROR: Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

echo "Claude Code installation"
echo "  Version:      ${CLAUDE_CODE_VERSION}"
echo "  Platform:     ${PLATFORM}"
echo "  Repo:         ${REPO_URL}"
echo ""

# ---------------------------------------------------------------------------
# Temporary directory (cleaned up on exit)
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

KEY_PATH="${TMP_DIR}/claude-code.asc"
KEYRING="${TMP_DIR}/claude-code.gpg"
MANIFEST_PATH="${TMP_DIR}/manifest.json"
MANIFEST_SIG_PATH="${TMP_DIR}/manifest.json.sig"
BINARY_PATH="${TMP_DIR}/claude"

# ---------------------------------------------------------------------------
# Fetch the release signing key and pin its fingerprint
# ---------------------------------------------------------------------------

echo "Fetching Anthropic release signing key ..."
download_file "${KEY_URL}" "${KEY_PATH}"

gpg --dearmor < "${KEY_PATH}" > "${KEYRING}" 2>/dev/null || {
  echo "ERROR: Failed to import Claude Code release signing key" >&2
  exit 1
}

ACTUAL_FINGERPRINT="$(
  gpg --no-default-keyring --keyring "${KEYRING}" \
      --with-colons --fingerprint 2>/dev/null \
  | awk -F: '/^fpr:/ {print $10; exit}'
)"

if [ "${ACTUAL_FINGERPRINT}" != "${EXPECTED_FINGERPRINT}" ]; then
  echo "ERROR: Release-key fingerprint mismatch" >&2
  echo "  Expected: ${EXPECTED_FINGERPRINT}" >&2
  echo "  Got:      ${ACTUAL_FINGERPRINT}" >&2
  exit 1
fi
echo "OK: Release-key fingerprint matches: ${ACTUAL_FINGERPRINT}"

# ---------------------------------------------------------------------------
# Download and verify manifest.json via detached signature
# ---------------------------------------------------------------------------

echo "Fetching manifest.json and signature ..."
download_file "${REPO_URL}/manifest.json"     "${MANIFEST_PATH}"
download_file "${REPO_URL}/manifest.json.sig" "${MANIFEST_SIG_PATH}"

gpg --no-default-keyring --keyring "${KEYRING}" \
    --verify "${MANIFEST_SIG_PATH}" "${MANIFEST_PATH}" 2>/dev/null || {
  echo "ERROR: GPG signature verification failed for manifest.json" >&2
  echo "       (Manifest signatures only exist for releases >= 2.1.89.)" >&2
  exit 1
}
echo "OK: GPG signature verified: manifest.json"

# ---------------------------------------------------------------------------
# Extract the platform's SHA256 from the verified manifest
# ---------------------------------------------------------------------------

EXPECTED_SHA256="$(jq -r --arg p "${PLATFORM}" '.platforms[$p].checksum // empty' "${MANIFEST_PATH}")"

if [ -z "${EXPECTED_SHA256}" ]; then
  echo "ERROR: No checksum entry for platform '${PLATFORM}' in manifest.json" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Download the binary and verify its SHA256 against the verified manifest
# ---------------------------------------------------------------------------

echo "Downloading and verifying binary ..."
download_and_verify "${REPO_URL}/${PLATFORM}/claude" "${BINARY_PATH}" "${EXPECTED_SHA256}"

echo ""

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

echo "Installing claude to ${INSTALL_DIR}/claude ..."
chmod +x "${BINARY_PATH}"

if [ -w "${INSTALL_DIR}" ]; then
  cp "${BINARY_PATH}" "${INSTALL_DIR}/claude"
else
  sudo cp "${BINARY_PATH}" "${INSTALL_DIR}/claude"
fi

echo ""
echo "Done: Claude Code installed successfully"
"${INSTALL_DIR}/claude" --version

mkdir -p /home/ubuntu/.local/bin
chown -R ubuntu:ubuntu /home/ubuntu/.local 

# Shell-integration
"${INSTALL_DIR}/claude" install --non-interactive 2>/dev/null || true
ln -sf /usr/local/bin/claude /home/ubuntu/.local/bin/claude