#!/bin/sh
# install-copilot-cli.sh
# Installs the GitHub Copilot CLI as a `gh` extension.
#
# NOT VERIFIED: GitHub has moved Copilot's CLI distribution before. Confirm
# `github/gh-copilot` is still the current channel (vs. a standalone
# `copilot` binary) before relying on this. `gh extension install` only
# needs network access to github.com/api.github.com/codeload.github.com
# (already whitelisted) - no credential needed to install the extension
# itself, only to use it afterwards.
set -eu

echo "Installing GitHub Copilot CLI extension (github/gh-copilot) ..."
gh extension install github/gh-copilot

echo "OK: gh copilot extension installed"
