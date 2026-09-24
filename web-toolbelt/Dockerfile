# Built locally by run.sh from common/Dockerfile (see BASE_IMAGE in run.sh).
ARG BASE_IMAGE=toolbelt-base:latest
FROM ${BASE_IMAGE}

# Build-only: no TTY during docker build, so keep debconf from probing for a frontend
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.authors="jay-dizzale"
ENV DEVCONTAINER_TYPE=web-toolbelt
LABEL description="Toolbelt environment for web development"

WORKDIR /tmp

## Install `node` (include NPM)
ADD web-toolbelt/scripts/ /tmp/
RUN sh /tmp/install-nodejs.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
