FROM ubuntu:26.04

# Build-only: no TTY during docker build, so keep debconf from probing for a frontend
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.authors="jay-dizzale"
LABEL description="Whitelist-enforcing forward proxy for devcontainer runtime traffic"

# goaccess + python3: a live dashboard for this same container's access.log
# (see entrypoint.sh) — goaccess's --real-time-html mode only runs a
# WebSocket server for live pushes, python3's http.server serves the
# report.html/JS it writes to /var/www.
RUN apt-get update && apt-get install -y --no-install-recommends \
        squid \
        netcat-openbsd \
        goaccess \
        python3 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/log/squid /var/spool/squid /var/www \
    && chown -R proxy:proxy /var/log/squid /var/spool/squid

COPY squid.conf /etc/squid/squid.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3128 8080 7890

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
