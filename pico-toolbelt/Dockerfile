FROM ubuntu:26.04

# Build-only: no TTY during docker build, so keep debconf from probing for a frontend
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.authors="jay-dizzale"
ENV DEVCONTAINER_TYPE=pico-toolbelt
LABEL description="Toolbelt environment for Raspberry Pi Pico / RP2040 firmware development"

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
RUN --mount=type=secret,id=github_token sh /tmp/agents/install-agents.sh

## Install PICO toolchain to compile for RP2040
ADD ./pico-toolbelt/scripts /tmp/
RUN --mount=type=secret,id=github_token sh /tmp/install-pico-toolchain.sh
ENV PICO_SDK_PATH=/opt/pico/pico-sdk \
    PICO_EXTRAS_PATH=/opt/pico/pico-extras \
    PICO_EXAMPLES_PATH=/opt/pico/pico-examples

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace

## Install the Rust toolchain (rustup itself installed above, as root)
ARG RUST_VERSION=stable
RUN rustup toolchain install "${RUST_VERSION}" && rustup default "${RUST_VERSION}"
ENV PATH="/home/ubuntu/.cargo/bin:${PATH}"
