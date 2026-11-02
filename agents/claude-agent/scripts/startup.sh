#!/bin/sh
# This container's command: (see docker-compose.yml) - prints the login
# instructions once at startup (visible via `docker logs`, same
# container), then idles like every toolbelt's `sleep infinity`.
set -eu

cat <<'EOF'

claude-agent: no credentials are mounted from the host. To authenticate
Claude Code / gh (needed for git push against /workspace), run on the
HOST (not in here):

    ./run.py login claude
    ./run.py login gh

(or `dev login claude`/`dev login gh` after `run.py setup`). That needs
your actual browser, so it's not something to run from this startup
banner - it just execs agent-login.sh inside this same container for you,
through the usual whitelisted proxy, with no port involved on either side
(the OAuth flow shows a URL and has you paste a one-time code back
yourself). The resulting login lives only in this container's own
volumes - see AGENTS.md's agent-sandbox note.

EOF

exec sleep infinity
