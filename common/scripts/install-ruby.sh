#!/bin/sh
# Install Ruby from source.
#
# Usage: install-ruby.sh <version>
#   version   Full Ruby version, e.g. 3.4.9
#
# The SHA256 checksum is fetched automatically from ruby/www.ruby-lang.org's
# _data/releases.yml (index.txt's format is undocumented/unreliable and has
# changed over time; the Ruby core team itself points to releases.yml, see
# https://bugs.ruby-lang.org/issues/20446)

set -eu

. /usr/local/lib/shell/download-utils.sh

RUBY_VERSION="${1:-}"
if [ -z "${RUBY_VERSION}" ]; then
    echo "Resolving latest stable Ruby release ..."
    # ruby/ruby tags stable releases as vX_Y_Z; filter out preview/rc entries.
    RUBY_VERSION="$(_github_wget -qO- 'https://api.github.com/repos/ruby/ruby/releases?per_page=20' 2>/dev/null \
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
# 1. Fetch SHA256 from releases.yml
#    Each entry looks like (indentation may vary, keys don't):
#      - version: 3.3.12
#        ...
#        sha256:
#          gz: <hex digest>
#          zip: ...
#          xz: ...
#        sha512:
#          ...
#    We match the "- version: X" line, then scan until the next "- version:"
#    for the "gz:" entry nested under "sha256:".
# ---------------------------------------------------------------------------
echo "==> Fetching SHA256 for ${RUBY_TARBALL} ..."
RELEASES_YML="$(mktemp)"
if ! wget -O "${RELEASES_YML}" "https://raw.githubusercontent.com/ruby/www.ruby-lang.org/master/_data/releases.yml"; then
    echo "ERROR: could not download releases.yml from raw.githubusercontent.com" >&2
    rm -f "${RELEASES_YML}"
    exit 1
fi

RUBY_SHA256="$(awk -v ver="${RUBY_VERSION}" '
    BEGIN { pat = "^- version: " ver "$" }
    $0 ~ pat { found = 1; insha = 0; next }
    found && /^- version:/ { exit }
    found {
        line = $0
        sub(/^[ \t]+/, "", line)
        if (line ~ /^[A-Za-z0-9_]+:$/) { insha = (line == "sha256:"); next }
        if (insha && line ~ /^gz:[ \t]+/) { sub(/^gz:[ \t]+/, "", line); print line; exit }
    }
' "${RELEASES_YML}")"
rm -f "${RELEASES_YML}"

if [ -z "${RUBY_SHA256}" ]; then
    echo "ERROR: No SHA256 found for Ruby ${RUBY_VERSION} in releases.yml" >&2
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