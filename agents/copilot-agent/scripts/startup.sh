#!/bin/sh
# This container's command: (see docker-compose.yml) - prints the login
# instructions once at startup (visible via `docker logs`, same
# container), then idles like every toolbelt's `sleep infinity`.
set -eu

cat <<'EOF'

copilot-agent: no credentials are mounted from the host. To authenticate
gh (covers both the Copilot CLI and git push against /workspace), run on
the HOST (not in here):

    ./run.py login gh

(or `dev login gh` after `run.py setup`). That needs your actual browser,
so it's not something to run from this startup banner - it just execs
agent-login.sh inside this same container for you. The resulting login
lives only in this container's own volume - see AGENTS.md's agent-sandbox
note.

EOF

exec sleep infinity
