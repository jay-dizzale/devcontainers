#!/bin/sh
# agent-login.sh <claude|gh>
#
# Both run inside the normal, already-running `dev` container (exec'd by
# `./run.py login claude`/`./run.py login gh` - devtool/launcher.py's
# cmd_login), through this stack's usual whitelisted proxy. Neither needs
# any local port/network trick: `gh auth login`'s default flow is a pure
# device code (open a URL on any device, enter the code there), and
# `claude login`'s flow shows a URL + lets you paste a one-time code back
# into this terminal yourself - in both cases the only network traffic is
# an ordinary outbound HTTPS call, no local server involved.
set -eu

usage() {
    cat >&2 <<'EOF'
Usage: agent-login.sh <claude|gh>

Normally run from the HOST instead, via `./run.py login claude`/
`./run.py login gh` (devtool/launcher.py's cmd_login) - either way it
needs your actual browser.
EOF
    exit 1
}

[ $# -eq 1 ] || usage

case "$1" in
    gh)
        echo "agent-login: GitHub device-code login - no port needed, just follow the prompt." >&2
        exec gh auth login --hostname github.com --git-protocol https
        ;;
    claude)
        echo "agent-login: starting Claude Code login - open the URL it shows, approve, then paste the code it gives you back here." >&2
        exec claude login
        ;;
    *)
        usage
        ;;
esac
