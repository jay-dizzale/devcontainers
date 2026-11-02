#!/bin/sh
# agent-login.sh gh
#
# Run this from an interactive shell in this container (not as the
# container's own startup command) to authenticate gh - this covers both
# the Copilot CLI (which rides on gh's own auth, no separate login step)
# and `git push`/`fetch` against /workspace. The resulting session lives
# only in the agent-gh-config named volume (see docker-compose.yml) -
# never on the host, never reused from a host login.
#
# Just `gh auth login`'s default device-code flow - no local callback
# port needed (unlike claude-agent's version of this script, which also
# handles Claude Code's less certain login flow).
set -eu

usage() {
    cat >&2 <<'EOF'
Usage: agent-login.sh gh

Logs in to gh from inside this container. Normally run from the HOST
instead, via `./run.py login gh` (devtool/launcher.py's cmd_login), which
execs this same script here for you. Only run this directly if you're
already in a shell in this container (docker compose exec -u ubuntu dev
zsh) - either way it needs your actual browser.
EOF
    exit 1
}

[ "${1:-}" = "gh" ] || usage

echo "agent-login: GitHub device-code login - no port needed, just follow the prompt." >&2
exec gh auth login --hostname github.com --git-protocol https
