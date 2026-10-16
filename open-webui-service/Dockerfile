# Built locally by run.py directly on top of Open WebUI's own published
# image — unlike every other environment/service, this one does NOT layer
# on toolbelt-base (see AGENTS.md "Services"): the upstream image already
# bundles everything the app needs (Python, curl, jq, ca-certificates, ...),
# so building our own Python environment on toolbelt-base just to pip-install
# the same package was redundant. All this Dockerfile adds on top is the
# same egress-enforcing entrypoint every other environment uses
# (common/entrypoint.sh) and the uid-1000 user it drops into — the upstream
# image otherwise runs as root (its UID/GID build args default to 0:0).
#
# `-slim`: this setup never needs local embedding/reranking/Whisper models
# or document-parsing extras (git, pandoc, ffmpeg, ...) — embeddings come
# from Ollama (RAG_EMBEDDING_ENGINE=ollama in docker-compose.yml) — so the
# slim variant's smaller image is a pure win here, not a feature trade-off.
ARG OPEN_WEBUI_VERSION=0.11.4-slim
FROM ghcr.io/open-webui/open-webui:${OPEN_WEBUI_VERSION}

LABEL org.opencontainers.image.authors="jay-dizzale"
LABEL description="Open WebUI service, preconfigured for Ollama on the Docker host (RAG)"

# Enterprise proxy support for the build — see common/Dockerfile for the full rationale
# (the implicit "predefined proxy build-arg" mechanism proved unreliable; these explicit
# ARGs make proxy.env's values reach this file's own RUN steps, e.g. apt-get below, too).
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

## common/entrypoint.sh needs iptables (not in the upstream image) and
## setpriv (ships in util-linux, already present).
RUN apt-get update && apt-get install -y --no-install-recommends iptables \
    && rm -rf /var/lib/apt/lists/*

## The uid-1000 user common/entrypoint.sh drops into. The upstream image has
## no such account by default (it runs as root) and owns /app and $HOME
## (/root, per its own ENV HOME=/root) as root — hand both to uid 1000 so
## the app can still write there after the entrypoint drops privileges.
RUN useradd --uid 1000 --no-create-home --home-dir "$HOME" --shell /bin/bash ubuntu \
    && chown -R 1000:1000 /app "$HOME"

COPY common/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

## Start wrapper used as the container's command — checks Ollama reachability,
## then hands off to the image's own backend/start.sh.
ADD open-webui-service/scripts/start-open-webui.sh /usr/local/bin/start-open-webui
RUN chmod +x /usr/local/bin/start-open-webui

## Data directory — owned by the uid the entrypoint drops to, so the
## (external, initially empty) named volume mounted here inherits that
## ownership on first use.
RUN install -d -o 1000 -g 1000 /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

USER ubuntu
WORKDIR /data
