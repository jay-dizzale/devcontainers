#!/bin/sh
# Install Ruby from source.
#
# Usage: install-ruby.sh <version>
#   version   Full Ruby version, e.g. 3.4.9
#
# The SHA256 checksum is fetched automatically from
# https://cache.ruby-lang.org/pub/ruby/index.txt

set -eu

. /usr/local/lib/shell/download-utils.sh

RUBY_VERSION="${1:-}"
if [ -z "${RUBY_VERSION}" ]; then
    echo "Resolving latest stable Ruby release ..."
    # ruby/ruby tags stable releases as vX_Y_Z; filter out preview/rc entries.
    RUBY_VERSION="$(wget -qO- 'https://api.github.com/repos/ruby/ruby/releases?per_page=20' 2>/dev/null \
        | jq -r '[.[] | select(.prerelease == false and .draft == false)
                       | select(.tag_name | test("^v[0-9]+_[0-9]+_[0-9]+$"))
                       | .tag_name][0]
                 | ltrimstr("v") | gsub("_"; ".")')"
    [ -n "${RUBY_VERSION}" ] || { echo "ERROR: could not resolve latest Ruby version" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Derive the minor-series directory component (e.g. "3.4" from "3.4.9")
# ---------------------------------------------------------------------------
RUBY_MINOR="$(echo "${RUBY_VERSION}" | awk -F. '{print $1"."$2}')"

RUBY_TARBALL="ruby-${RUBY_VERSION}.tar.gz"
RUBY_URL="https://cache.ruby-lang.org/pub/ruby/${RUBY_MINOR}/${RUBY_TARBALL}"
RUBY_SRC_DIR="/tmp/ruby-${RUBY_VERSION}"

# ---------------------------------------------------------------------------
# 1. Fetch SHA256 from the upstream index
#    index.txt is a tab-separated file: filename  size  date  sha1  sha256  sha512
# ---------------------------------------------------------------------------
echo "==> Fetching SHA256 for ${RUBY_TARBALL} ..."
RUBY_SHA256="$(wget -qO- "https://cache.ruby-lang.org/pub/ruby/index.txt" \
    | awk -F'\t' -v f="${RUBY_TARBALL}" '$1 == f { print $5 }' \
    | tr '[:upper:]' '[:lower:]')"

if [ -z "${RUBY_SHA256}" ]; then
    echo "ERROR: No SHA256 found for ${RUBY_TARBALL} in index.txt" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Download and verify the Ruby source tarball
# ---------------------------------------------------------------------------
echo "==> Downloading Ruby ${RUBY_VERSION} ..."
download_file "${RUBY_URL}" "/tmp/${RUBY_TARBALL}"

echo "==> Verifying SHA256 ..."
verify_sha256 "/tmp/${RUBY_TARBALL}" "${RUBY_SHA256}"

# ---------------------------------------------------------------------------
# 3. Build and install Ruby from source
# ---------------------------------------------------------------------------
echo "==> Extracting ..."
tar -xzf "/tmp/${RUBY_TARBALL}" -C /tmp

echo "==> Configuring ..."
cd "${RUBY_SRC_DIR}"
./configure --prefix=/usr/local --disable-install-doc

echo "==> Building ..."
make -j"$(nproc)"

echo "==> Installing ..."
make install

cd /
rm -rf "${RUBY_SRC_DIR}" "/tmp/${RUBY_TARBALL}"
echo "OK: Ruby ${RUBY_VERSION} installed."