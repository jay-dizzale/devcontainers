# Built locally by run.sh from common/Dockerfile (see BASE_IMAGE in run.sh).
ARG BASE_IMAGE=toolbelt-base:latest
FROM ${BASE_IMAGE}

# Build-only: no TTY during docker build, so keep debconf from probing for a frontend
ARG DEBIAN_FRONTEND=noninteractive

# Enterprise proxy support for the build - see common/Dockerfile for the full
# rationale (the implicit "predefined proxy build-arg" mechanism proved unreliable;
# these explicit ARGs make proxy.env's values reach this file's own RUN steps too).
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

LABEL org.opencontainers.image.authors="jay-dizzale"
ENV DEVCONTAINER_TYPE=latex-toolbelt
LABEL description="Toolbelt environment for LaTeX/document authoring"

WORKDIR /tmp

## Install Latex tools
ADD ./latex-toolbelt/scripts /tmp/
RUN sh /tmp/install-latex.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
