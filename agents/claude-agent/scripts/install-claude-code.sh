#!/bin/sh
# install-claude-code.sh
# Installs the Claude Code CLI from npm.
#
# Usage:
#   ./install-claude-code.sh <version>
# Or via environment variable:
#   CLAUDE_CODE_VERSION=1.2.3 ./install-claude-code.sh
#
# Unlike the checksum-verified tarball installs elsewhere in this repo, npm
# itself verifies package integrity against the registry's signed metadata,
# so there's no separate checksum step here.
set -eu

CLAUDE_CODE_VERSION="${1:-${CLAUDE_CODE_VERSION:-latest}}"

echo "Installing Claude Code CLI (@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}) ..."
npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

echo "OK: $(claude --version)"
