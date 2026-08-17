#!/bin/sh
# install-agents.sh
# Installs the coding-agent CLIs in AGENTS (comma/space-separated agent
# names). Defaults to installing all of them — every image ships with
# every agent CLI out of the box.
#
# To add a new agent in the future:
#   1. Drop a common/agents/install-<name>.sh script (same conventions as
#      the others: pinned version, checksum/signature verification).
#   2. Add its id to DEFAULT_AGENTS below.
# No Dockerfile or docker-compose.yml changes are needed — this script is
# already generic.
#
# Usage:
#   ./install-agents.sh                       # installs DEFAULT_AGENTS
#   AGENTS="claude" ./install-agents.sh        # installs only Claude Code
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_AGENTS="claude,copilot"

AGENTS="${AGENTS:-${DEFAULT_AGENTS}}"
[ -n "${AGENTS}" ] || { echo "No agent CLIs selected — skipping."; exit 0; }

# Normalise commas to spaces for word splitting.
for _agent in $(printf '%s' "${AGENTS}" | tr ',' ' '); do
    [ -n "${_agent}" ] || continue
    _script="${SCRIPT_DIR}/install-${_agent}.sh"
    if [ ! -f "${_script}" ]; then
        echo "ERROR: Unknown agent '${_agent}' (no ${_script})" >&2
        exit 1
    fi
    echo "── Installing agent: ${_agent} ──────────────────────────────────"
    sh "${_script}"
done
