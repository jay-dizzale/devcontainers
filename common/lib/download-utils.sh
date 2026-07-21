# /usr/local/lib/shell/download_utils.sh
# Library file — must be sourced, not executed directly.
# Usage: . /usr/local/lib/shell/download_utils.sh
#
# Dependencies: wget, sha256sum, sha512sum, awk

# ---------------------------------------------------------------------------
# Download a file. Fails loudly on error.
# Arguments:
#   $1  url   Source URL
#   $2  dest  Destination path
# ---------------------------------------------------------------------------
download_file() {
    url="$1"
    dest="$2"
    wget -qq "$url" -O "$dest" || {
        echo "ERROR: Download failed: $url" >&2
        return 1
    }
}

# ---------------------------------------------------------------------------
# Verify a SHA256 checksum.
# Arguments:
#   $1  file      Path to the file
#   $2  expected  Expected hash (case-insensitive)
# ---------------------------------------------------------------------------
verify_sha256() {
    file="$1"
    expected="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: SHA256 mismatch for $file" >&2
        echo "  Expected: $expected" >&2
        echo "  Got:      $actual" >&2
        return 1
    fi
    echo "OK: SHA256 verified: $file"
}

# ---------------------------------------------------------------------------
# Fetch a SHA512 checksum from a remote .sha512 sidecar file.
# Arguments:
#   $1  url    Base URL of the file (without .sha512 extension)
#   $2  label  Human-readable name for log output
# Prints the lowercase hash to stdout.
# ---------------------------------------------------------------------------
fetch_sha512() {
    url="$1"
    label="$2"
    echo "Fetching SHA512 for ${label} ..." >&2
    sha="$(wget -qO- "${url}.sha512")" || {
        echo "ERROR: SHA512 file not reachable: ${url}.sha512" >&2
        return 1
    }
    # Some providers return "hash  filename", others just "hash"
    echo "$sha" | awk '{print $1}' | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
# Verify a SHA512 checksum.
# Arguments:
#   $1  file      Path to the file
#   $2  expected  Expected hash (case-insensitive)
#   $3  label     Human-readable name for log output
# ---------------------------------------------------------------------------
verify_sha512() {
    file="$1"
    expected="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
    label="$3"
    actual="$(sha512sum "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: SHA512 mismatch for ${label}" >&2
        echo "  Expected: $expected" >&2
        echo "  Got:      $actual" >&2
        return 1
    fi
    echo "OK: SHA512 verified: ${label}"
}

# ---------------------------------------------------------------------------
# Download a file and verify its SHA256 checksum. Cleans up on failure.
# Arguments:
#   $1  url      Source URL
#   $2  dest     Destination path
#   $3  expected Expected SHA256 hash
# ---------------------------------------------------------------------------
download_and_verify() {
    url="$1"
    dest="$2"
    expected="$3"
    download_file "$url" "$dest" || return 1
    verify_sha256 "$dest" "$expected" || { rm -f "$dest"; return 1; }
}

# ---------------------------------------------------------------------------
# Load environment variables from a file.
# Arguments:
#   $1  file  Path to the env file (default: .env)
# ---------------------------------------------------------------------------
load_env() {
    env_file="${1:-.env}"
    if [ ! -f "$env_file" ]; then
        echo "ERROR: env file not found: $env_file" >&2
        return 1
    fi
    . "$env_file"
    echo "OK: Loaded env from $env_file"
}

# ---------------------------------------------------------------------------
# Resolve the latest stable release tag from a GitHub repository.
# Uses /releases/latest which already excludes drafts and pre-releases.
# Strips any leading 'v' prefix from the returned tag.
# Arguments:
#   $1  owner/repo  e.g. "cli/cli"
#   $2  (optional) extra prefix to strip from the tag, e.g. "maven-"
# ---------------------------------------------------------------------------
github_latest_stable() {
    _repo="$1"
    _strip="${2:-}"
    _tag="$(wget -qO- "https://api.github.com/repos/${_repo}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty')"
    [ -n "${_tag}" ] || { echo "ERROR: no release found for ${_repo}" >&2; return 1; }
    _tag="${_tag#v}"
    _tag="${_tag#${_strip}}"
    printf '%s' "${_tag}"
}

# ---------------------------------------------------------------------------
# Resolve the latest stable release tag from GitHub, filtered by a regex.
# Useful when /releases/latest returns RCs that the project hasn't marked
# as pre-releases (e.g. Apache Maven).
# Arguments:
#   $1  owner/repo
#   $2  jq-compatible regex applied to the tag after stripping 'v' and prefix
#   $3  (optional) prefix to strip, e.g. "maven-"
# ---------------------------------------------------------------------------
github_latest_matching() {
    _repo="$1"
    _pat="$2"
    _strip="${3:-}"
    wget -qO- "https://api.github.com/repos/${_repo}/releases?per_page=20" 2>/dev/null \
        | jq -r --arg pat "${_pat}" --arg strip "${_strip}" \
            '[.[] | select(.prerelease == false and .draft == false)
                  | .tag_name | ltrimstr("v") | ltrimstr($strip)
                  | select(test($pat))][0] // empty'
}