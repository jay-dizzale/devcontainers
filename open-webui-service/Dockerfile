# Built locally by run.py on top of the shared base (common/Dockerfile) — a
# service, not a devcontainer: it reuses the base for its egress-enforcing
# entrypoint (common/entrypoint.sh) and uv, nothing else.
ARG BASE_IMAGE=toolbelt-base:latest
FROM ${BASE_IMAGE}

# Build-only: no TTY during docker build, so keep debconf from probing for a frontend
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.authors="jay-dizzale"
LABEL description="Open WebUI service, preconfigured for Ollama on the Docker host (RAG)"

WORKDIR /tmp

## Install Open WebUI (+ the start script used as the container's command)
ADD open-webui-service/scripts/ /tmp/
ARG OPEN_WEBUI_VERSION=
RUN sh /tmp/install-open-webui.sh
RUN install -m 0755 /tmp/start-open-webui.sh /usr/local/bin/start-open-webui

## Cleanup
RUN rm -rf /tmp/*

## Data directory — owned by ubuntu so the (external, initially empty) named
## volume mounted here inherits that ownership on first use.
RUN install -d -o ubuntu -g ubuntu /data

USER ubuntu
WORKDIR /data
