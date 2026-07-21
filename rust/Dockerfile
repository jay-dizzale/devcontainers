FROM ubuntu:noble

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
WORKDIR /tmp
RUN sh /tmp/install-common.sh
ARG INSTALL_CLAUDE=0
RUN [ "${INSTALL_CLAUDE}" = "1" ] && sh /tmp/install-claude.sh || true

## Install `rustup`
RUN apt-get install -qqy rustup build-essential

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace

ARG RUST_VERSION=stable
RUN rustup toolchain install "${RUST_VERSION}" && rustup default "${RUST_VERSION}"
ENV PATH="/home/ubuntu/.cargo/bin:${PATH}"
