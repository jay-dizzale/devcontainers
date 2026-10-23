#!/bin/sh
# Shared base image entrypoint. Runs as root (base.docker-compose.yml sets
# `user: root`) so it can set up the egress-enforcing iptables rules below,
# then drops privileges to uid 1000 (ubuntu) for good before exec'ing the
# real command (e.g. `sleep infinity`). Capabilities don't survive a
# non-ambient privilege drop, so the process it execs into has none - it
# can't touch these rules again, and neither can a later `docker compose
# exec` into the same container (iptables rules live in the network
# namespace, not per-process).
#
# `dev` sits on the stack's ordinary default network (real internet access
# at the Docker-network level - needed for `proxy` to work at all, since it
# shares that network) and is kept off it purely by this OUTPUT allowlist:
# only loopback, Docker's embedded DNS, and the `proxy` service are reachable.
# Everything else is dropped. `depends_on: proxy: condition: service_healthy`
# guarantees `proxy` already resolves by the time this runs.
set -eu

# ahostsv4, not `hosts`: on an IPv6-enabled Docker network `hosts` can return the
# proxy's IPv6 address first, which the IPv4 rule below can't take.
PROXY_IP="$(getent ahostsv4 proxy | awk '{print $1; exit}')"
if [ -z "$PROXY_IP" ]; then
    echo "entrypoint: could not resolve 'proxy' - refusing to start without an egress allowlist" >&2
    exit 1
fi

# Build the ACCEPT rules before flipping the default policy, so this script
# can't lock itself out mid-setup.
iptables -A OUTPUT -o lo -j ACCEPT
# Reply traffic for connections *into* dev (e.g. a published dev-server
# port) is itself outbound from dev's point of view - without this, the
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

# IPv6 needs the same allowlist, or a Docker network with IPv6 enabled is a
# wide-open second route out. Same rules (the proxy's IPv6 address(es), if it
# has any). If ip6tables can't be used at all, start only when the container
# has no IPv6 address beyond loopback/link-local (/proc/net/if_inet6 field 4 is
# the scope: 10 = host, 20 = link) - otherwise refuse, rather than run with
# unfiltered IPv6.
if ip6tables -L OUTPUT >/dev/null 2>&1; then
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # Neighbor discovery is IPv6's ARP. Unlike ARP it's ICMPv6, so the DROP
    # policy below would eat it and even the allowed proxy route would fail
    # (tested). Link-local only - it can't carry anything off the network.
    ip6tables -A OUTPUT -p ipv6-icmp --icmpv6-type neighbour-solicitation -j ACCEPT
    ip6tables -A OUTPUT -p ipv6-icmp --icmpv6-type neighbour-advertisement -j ACCEPT
    for ip in $(getent ahostsv6 proxy | awk '$1 !~ /^::ffff:/ {print $1}' | sort -u); do
        ip6tables -A OUTPUT -d "$ip" -j ACCEPT
    done
    ip6tables -P OUTPUT DROP
elif [ -r /proc/net/if_inet6 ] && awk '$4 != "10" && $4 != "20"' /proc/net/if_inet6 | grep -q .; then
    echo "entrypoint: container has IPv6 but ip6tables is unusable - refusing to start with unfiltered IPv6 egress" >&2
    exit 1
fi

exec setpriv --reuid=1000 --regid=1000 --init-groups -- "$@"
