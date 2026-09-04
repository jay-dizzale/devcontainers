#!/bin/sh
# ensure-egress-proxy.sh
# Idempotently starts the shared egress-proxy stack if it isn't already
# running. Safe to call on every devcontainer start — called both from
# run.sh and (once wired into an environment's devcontainer.json) from
# VS Code's `initializeCommand`, so both launch paths behave identically.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROXY_DIR="$SCRIPT_DIR/egress-proxy"

if docker network inspect devcontainer-egress >/dev/null 2>&1; then
    exit 0
fi

echo "🧱 Starting shared egress-proxy (devcontainer-egress) ..."
( cd "$PROXY_DIR" && docker compose up -d --build )
