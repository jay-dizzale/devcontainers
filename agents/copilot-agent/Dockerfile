# DRAFT. Built locally by run.py from common/Dockerfile (see BASE_IMAGE in run.py),
# same as every other toolbelt - but this is NOT a toolbelt (see AGENTS.md's
# "Agent sandbox" note): it exists to run the GitHub Copilot CLI against a
# project directory, isolated from every other environment. See
# agents/copilot-agent/docker-compose.yml's ACCEPTED RISK note for what it does
# still share with the host: the project directory itself, mounted
# read-write at /workspace. Credentials are NOT shared with the host - see
# agents/copilot-agent/scripts/agent-login.sh: you log in from inside this
# container, and that session lives only in its own named volume.
#
# Claude Code is a SEPARATE environment (../claude-agent) on purpose -
# installing both agent CLIs by default in one image was the thing being
# avoided here. No Node.js here either - the standalone Copilot CLI (see
# install-copilot-cli.sh; the old `gh-copilot` extension is retired) is
# installed as a prebuilt binary via GitHub's own install script, not the
# npm package GitHub also offers.
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
LABEL description="DRAFT - isolated sandbox for running the GitHub Copilot CLI against a project directory. Not a toolbelt."
ENV DEVCONTAINER_TYPE=copilot-agent

WORKDIR /tmp

## GitHub Copilot CLI
ADD agents/copilot-agent/scripts/ /tmp/
RUN sh /tmp/install-copilot-cli.sh

## In-container login wrapper + startup banner (see agent-login.sh/startup.sh)
RUN cp /tmp/agent-login.sh /usr/local/bin/agent-login.sh \
    && cp /tmp/startup.sh /usr/local/bin/startup.sh \
    && chmod +x /usr/local/bin/agent-login.sh /usr/local/bin/startup.sh

## Cleanup
RUN rm -rf /tmp/*

## Pre-create and chown the dir the agent-gh-config named volume
## (docker-compose.yml) mounts over - /home/ubuntu/.config/gh doesn't
## otherwise exist in the image. An empty named volume's target directory
## gets created by the Docker engine itself (as root, since it does so
## before any container process runs), not inherited from whoever's running
## at mount time - so without this, `gh auth login` as uid 1000 fails to
## write there. Docker copies an image directory's content (here: nothing,
## but also its ownership) into the volume the first time it's mounted,
## which is what this relies on.
RUN mkdir -p /home/ubuntu/.config/gh \
    && chown -R ubuntu:ubuntu /home/ubuntu/.config

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
