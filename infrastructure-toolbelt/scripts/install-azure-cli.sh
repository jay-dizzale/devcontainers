#!/bin/sh
# install-azure-cli.sh
# Installs the Azure CLI via Microsoft's signed APT repository.
# Dependencies: wget, gpg, apt-transport-https

AZURE_REPO_URL="https://packages.microsoft.com/repos/azure-cli/"
AZURE_KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
AZURE_KEY_PATH="/usr/share/keyrings/microsoft.gpg"
AZURE_SOURCES_PATH="/etc/apt/sources.list.d/azure-cli.list"

# ---------------------------------------------------------------------------
# Import Microsoft signing key
# ---------------------------------------------------------------------------
echo "Importing Microsoft signing key ..."
wget -qO- "${AZURE_KEY_URL}" \
    | gpg --dearmor \
    | tee "${AZURE_KEY_PATH}" > /dev/null || {
    echo "ERROR: Failed to import Microsoft signing key" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Add APT repository — use VERSION_CODENAME (e.g. "noble"), not a
# constructed string like "ubuntu2404" which Microsoft does not publish.
# ---------------------------------------------------------------------------
AZ_DIST="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=${AZURE_KEY_PATH}] ${AZURE_REPO_URL} ${AZ_DIST} main" \
    > "${AZURE_SOURCES_PATH}"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
apt-get update -q
apt-get install -qqy azure-cli  