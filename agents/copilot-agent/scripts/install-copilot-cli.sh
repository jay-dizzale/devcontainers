#!/bin/sh
# install-copilot-cli.sh
# Installs the standalone GitHub Copilot CLI (github/copilot-cli).
#
# The old `gh` extension this used to install (github/gh-copilot) is
# retired - GitHub replaced it with this standalone `copilot` binary, and
# `gh` itself now ships a built-in `copilot` command that just bridges to
# it. Installing the old extension today fails with "copilot matches the
# name of a built-in command or alias" because of that built-in.
#
# Uses GitHub's own install script rather than download_and_verify from
# download-utils.sh: unlike every other install-*.sh in this repo, upstream
# publishes no checksum/signature file for a direct binary download to
# verify against (checked the github/copilot-cli releases page - only a
# digest shown in the GitHub UI itself, nothing downloadable). Accepted,
# explicit exception to AGENTS.md's "no unverified curl | sh installs"
# rule in favor of the officially documented path.
#
# Usage:
#   ./install-copilot-cli.sh <version>
# Or via environment variable:
#   COPILOT_CLI_VERSION=v0.0.369 ./install-copilot-cli.sh
# Unset/empty installs the latest release. Runs as root (before USER
# ubuntu in the Dockerfile), so the install script's own root-detection
# installs to /usr/local/bin.
set -eu

VERSION="${1:-${COPILOT_CLI_VERSION:-}}"
if [ -n "${VERSION}" ]; then
    export VERSION
    echo "Installing GitHub Copilot CLI (github/copilot-cli@${VERSION}) ..."
else
    echo "Installing GitHub Copilot CLI (github/copilot-cli, latest) ..."
fi

curl -fsSL https://gh.io/copilot-install | bash

echo "OK: $(copilot --version)"
