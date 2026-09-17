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

## Install the Rust toolchain (rustup itself installed above, as root)
ARG RUST_VERSION=stable
RUN rustup toolchain install "${RUST_VERSION}" && rustup default "${RUST_VERSION}"
ENV PATH="/home/ubuntu/.cargo/bin:${PATH}"

