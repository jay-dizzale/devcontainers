#!/bin/sh
# install-terraform-docs.sh
# Installs terraform-docs.
# Version is expected via ARG/ENV: TERRAFORM_DOCS_VERSION (without leading 'v').
# terraform-docs publishes a SHA256SUMS file for each release.
# Dependencies: wget, sha256sum, tar

. /usr/local/lib/shell/download-utils.sh

TERRAFORM_DOCS_VERSION="${1:-${TERRAFORM_DOCS_VERSION:-}}"
if [ -z "${TERRAFORM_DOCS_VERSION}" ]; then
    echo "Resolving latest stable terraform-docs release ..."
    TERRAFORM_DOCS_VERSION="$(github_latest_stable terraform-docs/terraform-docs)"
    [ -n "${TERRAFORM_DOCS_VERSION}" ] || { echo "ERROR: could not resolve latest terraform-docs version" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Arch detection
# terraform-docs uses 'linux' and dpkg arch names in its release filenames.
# ---------------------------------------------------------------------------
ARCHITECTURE="$(dpkg --print-architecture)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

TFDOCS_TARBALL="terraform-docs-v${TERRAFORM_DOCS_VERSION}-${OS}-${ARCHITECTURE}.tar.gz"
TFDOCS_BASE_URL="https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}"
TFDOCS_URL="${TFDOCS_BASE_URL}/${TFDOCS_TARBALL}"
CHECKSUMS_URL="${TFDOCS_BASE_URL}/terraform-docs-v${TERRAFORM_DOCS_VERSION}.sha256sum"

# ---------------------------------------------------------------------------
# Download & verify via SHA256SUMS file
# ---------------------------------------------------------------------------
echo "Fetching terraform-docs SHA256 checksum ..."
TFDOCS_SHA256="$(wget -qO- "${CHECKSUMS_URL}" \
    | awk -v file="${TFDOCS_TARBALL}" '$2 == file {print $1}')" || {
    echo "ERROR: Could not fetch checksums for terraform-docs ${TERRAFORM_DOCS_VERSION}" >&2
    exit 1
}

if [ -z "${TFDOCS_SHA256}" ]; then
    echo "ERROR: No checksum entry found for ${TFDOCS_TARBALL}" >&2
    exit 1
fi

download_and_verify "${TFDOCS_URL}" "/tmp/${TFDOCS_TARBALL}" "${TFDOCS_SHA256}"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
tar -xzf "/tmp/${TFDOCS_TARBALL}" -C /tmp terraform-docs
install -m 0755 /tmp/terraform-docs /usr/bin/terraform-docs
rm -f "/tmp/${TFDOCS_TARBALL}" /tmp/terraform-docs

echo "OK: terraform-docs v${TERRAFORM_DOCS_VERSION} installed"