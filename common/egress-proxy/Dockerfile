FROM ubuntu:noble

LABEL org.opencontainers.image.authors="jay-dizzale"
LABEL description="Shared egress-filtering forward proxy (Squid) for devcontainer runtime traffic"

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends squid ca-certificates \
    && rm -rf /var/lib/apt/lists/*

EXPOSE 3128

CMD ["squid", "-N", "-d", "1"]
