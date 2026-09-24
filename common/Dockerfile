FROM ubuntu:26.04

# Build-only: no TTY during docker build, so keep debconf from probing for a frontend
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.authors="jay-dizzale"
LABEL description="Shared base image for every toolbelt (built locally by run.sh, never pushed)"

## Install common tools (includes Ruby, Go, and uv — see common/scripts/install-common.sh)
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
RUN --mount=type=secret,id=github_token sh /tmp/agents/install-agents.sh

## Cleanup
RUN rm -rf /tmp/*

## Install the Rust toolchain (rustup itself installed above, as root)
USER ubuntu
ARG RUST_VERSION=stable
RUN rustup toolchain install "${RUST_VERSION}" && rustup default "${RUST_VERSION}"
ENV PATH="/home/ubuntu/.cargo/bin:${PATH}"

## Toolbelts layer on top of this and need root for their own install scripts;
## each one switches back to `ubuntu` at the end.
USER root
