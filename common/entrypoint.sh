#!/bin/sh
# Shared base image entrypoint. Runs as root (base.docker-compose.yml sets
# `user: root`) so it can set up the egress-enforcing iptables rules below,
# then drops privileges to uid 1000 (ubuntu) for good before exec'ing the
# real command (e.g. `sleep infinity`). Capabilities don't survive a
# non-ambient privilege drop, so the process it execs into has none — it
# can't touch these rules again, and neither can a later `docker compose
# exec` into the same container (iptables rules live in the network
# namespace, not per-process).
#
# `dev` sits on the stack's ordinary default network (real internet access
# at the Docker-network level — needed for `proxy` to work at all, since it
# shares that network) and is kept off it purely by this OUTPUT allowlist:
# only loopback, Docker's embedded DNS, and the `proxy` service are reachable.
# Everything else is dropped. `depends_on: proxy: condition: service_healthy`
# guarantees `proxy` already resolves by the time this runs.
set -eu

PROXY_IP="$(getent hosts proxy | awk '{print $1; exit}')"
if [ -z "$PROXY_IP" ]; then
    echo "entrypoint: could not resolve 'proxy' — refusing to start without an egress allowlist" >&2
    exit 1
fi

# Build the ACCEPT rules before flipping the default policy, so this script
# can't lock itself out mid-setup.
iptables -A OUTPUT -o lo -j ACCEPT
# Reply traffic for connections *into* dev (e.g. a published dev-server
# port) is itself outbound from dev's point of view — without this, the
# default DROP below silently eats every response and published ports look
# reachable (Docker's NAT binds them fine) but hang (tested: they did).
# This only allows replies on already-permitted flows; a brand new outbound
# connection to an unlisted host is still a NEW packet and still gets
# dropped by the default policy below.
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d 127.0.0.11 --dport 53 -j ACCEPT
iptables -A OUTPUT -d "$PROXY_IP" -j ACCEPT
iptables -P OUTPUT DROP

exec setpriv --reuid=1000 --regid=1000 --init-groups -- "$@"
