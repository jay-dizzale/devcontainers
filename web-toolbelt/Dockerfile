FROM ubuntu:noble

LABEL org.opencontainers.image.authors="jay-dizzale"
ENV DEVCONTAINER_TYPE=web-toolbelt
LABEL description="Toolbelt environment for web development"

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
RUN --mount=type=secret,id=github_token sh /tmp/agents/install-agents.sh

## Install `node` (include NPM)
ADD web-toolbelt/scripts/ /tmp/
RUN sh /tmp/install-nodejs.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace

