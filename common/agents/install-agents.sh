#!/bin/sh
# install-agents.sh
# Installs zero or more optional coding-agent CLIs, selected via the
# AGENTS build arg (comma/space-separated agent names, e.g. "claude,copilot").
#
# To add a new agent in the future:
#   1. Drop a common/agents/install-<name>.sh script (same conventions as
#      the others: pinned version, checksum/signature verification).
#   2. Add its id/label to AGENTS_AVAILABLE in run.sh.
# No Dockerfile or docker-compose.yml changes are needed — this script and
# the AGENTS arg are already generic.
#
# Usage:
#   AGENTS="claude,copilot" ./install-agents.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

AGENTS="${AGENTS:-}"
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
