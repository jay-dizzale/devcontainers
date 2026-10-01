#!/bin/sh
# Concatenates whitelist.d/*.txt (comments and blank lines stripped) into the
# single dstdomain ACL file squid.conf reads, generates the upstream cache_peer
# chain (if any), starts the GoAccess live dashboard in the background, then
# execs squid in the foreground so it stays PID 1 (keeps the fast
# shutdown_lifetime-0 teardown — see squid.conf). Re-run (docker compose
# restart proxy) after editing a whitelist.d file or proxy.env to pick up
# the change.
set -eu

WHITELIST_DIR=/etc/squid/whitelist.d
WHITELIST_FILE=/etc/squid/whitelist.txt

# sort -u: several whitelist.d/*.txt files legitimately repeat the same
# domain (e.g. the Apache mirrors java-toolbelt.txt and
# infrastructure-toolbelt.txt both need) — Squid only warns about ACL
# duplicates, but deduping here keeps that log clean.
: > "$WHITELIST_FILE"
if [ -d "$WHITELIST_DIR" ]; then
    for f in "$WHITELIST_DIR"/*.txt; do
        [ -e "$f" ] || continue
        grep -Ev '^[[:space:]]*(#|$)' "$f"
    done | sort -u > "$WHITELIST_FILE"
fi

echo "toolbelt-proxy: loaded $(wc -l < "$WHITELIST_FILE") whitelisted domain(s):"
sed 's/^/  /' "$WHITELIST_FILE"

# If proxy.env configures a corporate proxy (UPSTREAM_PROXY, e.g.
# http://proxy.example.com:8080), chain every allowed request to it instead
# of going direct on the egress network. Left empty otherwise.
UPSTREAM_FILE=/etc/squid/upstream.conf
: > "$UPSTREAM_FILE"
if [ -n "${UPSTREAM_PROXY:-}" ]; then
    _host_port="$(echo "$UPSTREAM_PROXY" | sed -E 's#^[a-zA-Z]+://##; s#/$##')"
    _host="${_host_port%%:*}"
    _port="${_host_port#*:}"
    [ "$_port" = "$_host" ] && _port=80
    echo "cache_peer $_host parent $_port 0 no-query default" >> "$UPSTREAM_FILE"
    echo "never_direct allow all" >> "$UPSTREAM_FILE"
    echo "toolbelt-proxy: chaining to upstream proxy $_host:$_port"
fi

# Live dashboard for this container's own access.log. Create the file
# first so goaccess doesn't have to wait for squid's first logged request;
# squid.conf's access_log just opens/appends to it as normal below. Squid's
# native log format: <epoch>.<ms> <elapsed> <client> <code>/<status> <bytes>
# <method> <url> <ident> <hierarchy>/<peer> <mime-type>. --date/time-format
# %s + %x in the log-format together tell GoAccess the first field is a raw
# Unix timestamp (its own documented Squid example, in
# /etc/goaccess/goaccess.conf). %~%L (not a generic %^) is required for the
# elapsed-time field specifically — Squid right-pads it to a fixed width
# (%6tr), and a generic %^ does not correctly skip that variable leading
# whitespace (tested: it does not, and silently shifts every field after it).
touch /var/log/squid/access.log
chown proxy:proxy /var/log/squid/access.log
goaccess /var/log/squid/access.log \
    --log-format='%x.%^ %~%L %h %^/%s %b %m %U' \
    --date-format='%s' \
    --time-format='%s' \
    -o /var/www/report.html \
    --real-time-html \
    --port=7890 \
    --addr=0.0.0.0 \
    --daemonize
echo "toolbelt-proxy: dashboard ready on :8080 (ws :7890)"
(cd /var/www && exec python3 -m http.server 8080) &

exec squid -N -f /etc/squid/squid.conf
