#!/bin/sh
# Installs Node.js via the official NodeSource APT repository.
# Requires: NODE_VERSION (major version number, e.g. "22")

. /usr/local/lib/shell/download-utils.sh

NODE_VERSION="${1:-}"
if [ -z "${NODE_VERSION}" ]; then
    echo "Resolving latest Node.js LTS major version ..."
    NODE_VERSION="$(wget -qO- 'https://nodejs.org/dist/index.json' 2>/dev/null \
        | jq -r '[.[] | select(.lts != false)][0].version | ltrimstr("v") | split(".")[0]')"
    [ -n "${NODE_VERSION}" ] || { echo "ERROR: could not resolve latest Node.js LTS major" >&2; exit 1; }
fi

KEYRING_DIR="/etc/apt/keyrings"
KEYRING_FILE="${KEYRING_DIR}/nodesource.gpg"
SOURCES_FILE="/etc/apt/sources.list.d/nodesource.list"
GPG_KEY_URL="https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"
GPG_KEY_TMP="/tmp/nodesource-repo.gpg.key"

echo "Installing Node.js ${NODE_VERSION} via NodeSource APT repository ..."

# Download GPG key
download_file "${GPG_KEY_URL}" "${GPG_KEY_TMP}"

# Import key into dedicated keyring (no curl|bash, no apt-key)
mkdir -p "${KEYRING_DIR}"
gpg --dearmor < "${GPG_KEY_TMP}" > "${KEYRING_FILE}"
rm -f "${GPG_KEY_TMP}"

# Add NodeSource APT repository
echo "deb [signed-by=${KEYRING_FILE}] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main" \
    > "${SOURCES_FILE}"

apt-get update -qq
apt-get install -y nodejs

echo "OK: Node.js $(node --version) installed."