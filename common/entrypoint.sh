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

# The rules below allow the proxy's *port* on the whole stack network, not
# just the IP `proxy` resolves to right now: the proxy can be restarted
# behind dev's back (the TUI's whitelist edits restart it, `b`/`a` stop and
# start it), Docker doesn't guarantee it gets the same IP back, and dev can't
# update its own rules once it has dropped NET_ADMIN - a pinned IP would go
# stale and every proxied request would hang. The network holds only `dev`
# and `proxy`; its gateway (the host side of the bridge) is dropped
# explicitly so it can't stand in for the proxy.
#
# /proc/net/route, not `ip route`: iproute2 isn't in the image. It prints
# addresses as little-endian hex. Picks the directly connected (no gateway)
# route that contains PROXY_IP -> "<net>/<prefix> <gateway>".
read -r PROXY_NET GATEWAY <<EOF
$(awk -v ip="$PROXY_IP" '
    function hex(s,  i, n) { n = 0; s = tolower(s); for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1; return n }
    function octet(x, k) { return hex(substr(x, 9 - 2 * k, 2)) }
    function quad(x) { return octet(x, 1) "." octet(x, 2) "." octet(x, 3) "." octet(x, 4) }
    BEGIN { split(ip, o, ".") }
    NR > 1 && $2 == "00000000" { gw = quad($3) }
    NR > 1 && $2 != "00000000" && $3 == "00000000" {
        ok = 1; bits = 0
        for (k = 1; k <= 4; k++) {
            m = octet($8, k); block = 256 - m
            if (int(o[k] / block) * block != octet($2, k)) ok = 0
            for (b = m; b > 0; b = int(b / 2)) bits += b % 2
        }
        if (ok) net = quad($2) "/" bits
    }
    END { print net, gw }
' /proc/net/route)
EOF
if [ -z "$PROXY_NET" ]; then
    echo "entrypoint: no directly connected route to proxy ($PROXY_IP) - refusing to start" >&2
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
[ -n "$GATEWAY" ] && iptables -A OUTPUT -d "$GATEWAY" -j DROP
iptables -A OUTPUT -p tcp -d "$PROXY_NET" --dport 3128 -j ACCEPT
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
    # Same port-on-the-network rule as IPv4, only if the proxy has an IPv6
    # address at all. /proc/net/ipv6_route: field 1 is the destination (32 hex
    # digits), 2 the prefix length (hex), 5 the next hop, 10 the interface.
    # The directly connected global routes (no next hop, not lo/link-local/
    # multicast) are the stack network's; the default route's next hop is the
    # gateway, dropped like the IPv4 one.
    if getent ahostsv6 proxy | awk '$1 !~ /^::ffff:/' | grep -q .; then
        awk '
            function hex(s,  i, n) { n = 0; s = tolower(s); for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1; return n }
            function addr(x,  i, a) { a = substr(x, 1, 4); for (i = 5; i < 32; i += 4) a = a ":" substr(x, i, 4); return a }
            $1 ~ /^0+$/ && $2 == "00" && $5 !~ /^0+$/ { print "gw", addr($5) }
            $5 ~ /^0+$/ && $10 != "lo" && $1 !~ /^(fe8|ff)/ && hex($2) > 0 && hex($2) < 128 { print "net", addr($1) "/" hex($2) }
        ' /proc/net/ipv6_route | sort -u | while read -r kind cidr; do
            if [ "$kind" = gw ]; then
                ip6tables -A OUTPUT -d "$cidr" -j DROP  # "gw" sorts before "net"
            else
                ip6tables -A OUTPUT -p tcp -d "$cidr" --dport 3128 -j ACCEPT
            fi
        done
    fi
    ip6tables -P OUTPUT DROP
elif [ -r /proc/net/if_inet6 ] && awk '$4 != "10" && $4 != "20"' /proc/net/if_inet6 | grep -q .; then
    echo "entrypoint: container has IPv6 but ip6tables is unusable - refusing to start with unfiltered IPv6 egress" >&2
    exit 1
fi


# tenv (infrastructure-toolbelt) takes an install lock at
# ${TENV_ROOT}/<Tool>.lock (e.g. ~/.tenv/Terraform.lock) while auto-installing
# a version, and waits on it forever if it's held. The lock doesn't get
# released if the holder dies without cleanup, e.g. `docker stop`/a crashed
# `docker exec` session - exactly what leaves a stale lock a later `tf`/`tofu`
# in the same container then hangs on. This entrypoint only runs on container
# (re)start, by which point nothing from a previous session is still running,
# so any lock file still here is stale by definition. No-op (globbed path
# just doesn't exist) on every other environment, which has no ~/.tenv at all.
rm -f /home/ubuntu/.tenv/*.lock 2>/dev/null || true

exec setpriv --reuid=1000 --regid=1000 --init-groups -- "$@"
