# DRAFT. Built locally by run.py from common/Dockerfile (see BASE_IMAGE in run.py),
# same as every other toolbelt - but this is NOT a toolbelt (see AGENTS.md's
# "Agent sandbox" note): it exists to run Claude Code against a project
# directory, isolated from every other environment. See
# agents/claude-agent/docker-compose.yml's ACCEPTED RISK note for what it does
# still share with the host: the project directory itself, mounted
# read-write at /workspace. Credentials are NOT shared with the host - see
# agents/claude-agent/scripts/agent-login.sh: you log in from inside this
# container, and that session lives only in its own named volumes.
#
# Copilot CLI is a SEPARATE environment (../copilot-agent) on purpose -
# installing both agent CLIs by default in one image was the thing being
# avoided here.
ARG BASE_IMAGE=toolbelt-base:latest
FROM ${BASE_IMAGE}

# Build-only: no TTY during docker build, so keep debconf from probing for a frontend
ARG DEBIAN_FRONTEND=noninteractive

# Enterprise proxy support for the build - see common/Dockerfile for the full
# rationale.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

LABEL org.opencontainers.image.authors="jay-dizzale"
LABEL description="DRAFT - isolated sandbox for running Claude Code against a project directory. Not a toolbelt."
ENV DEVCONTAINER_TYPE=claude-agent

WORKDIR /tmp

## Node.js (Claude Code CLI ships as an npm package) - reuses web-toolbelt's
## install script rather than duplicating it.
ADD web-toolbelt/scripts/install-nodejs.sh /tmp/
RUN sh /tmp/install-nodejs.sh 22

## Claude Code CLI
ADD agents/claude-agent/scripts/ /tmp/
RUN sh /tmp/install-claude-code.sh

## In-container login wrapper + startup banner (see agent-login.sh/startup.sh)
RUN cp /tmp/agent-login.sh /usr/local/bin/agent-login.sh \
    && cp /tmp/startup.sh /usr/local/bin/startup.sh \
    && chmod +x /usr/local/bin/agent-login.sh /usr/local/bin/startup.sh

## Cleanup
RUN rm -rf /tmp/*

## Pre-create and chown the dirs the agent-claude-home/agent-gh-config named
## volumes (docker-compose.yml) mount over - /home/ubuntu/.claude and
## /home/ubuntu/.config/gh don't otherwise exist in the image. An empty named
## volume's target directory gets created by the Docker engine itself (as
## root, since it does so before any container process runs), not inherited
## from whoever's running at mount time - so without this, `claude login`/
## `gh auth login` as uid 1000 fails to write there. Docker copies an image
## directory's content (here: nothing, but also its ownership) into the
## volume the first time it's mounted, which is what this relies on.
RUN mkdir -p /home/ubuntu/.claude /home/ubuntu/.config/gh \
    && chown -R ubuntu:ubuntu /home/ubuntu/.claude /home/ubuntu/.config

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
