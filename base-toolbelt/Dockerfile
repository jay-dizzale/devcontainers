FROM ubuntu:noble

LABEL org.opencontainers.image.authors="jay-dizzale"
LABEL description="Toolbelt environment for Ruby, Rust, Go, and Python (uv) development"
ENV DEVCONTAINER_TYPE=base-toolbelt

## Install common tools
## `build-essential` (gcc, make, ...) is already installed here, covering C development.
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
RUN --mount=type=secret,id=github_token sh /tmp/agents/install-agents.sh

## Dependencies for ruby-build
ADD base-toolbelt/scripts/ /tmp/
RUN --mount=type=secret,id=github_token sh /tmp/install-ruby.sh

## Install `rustup` (toolchain itself installed below, once running as `ubuntu`)
RUN apt-get install -qqy rustup build-essential

## Install `go` (GO-Lang)
RUN sh /tmp/install-go.sh
ENV PATH="/usr/local/go/bin:${PATH}"

## Install `uv` to manage Python versions and virtual environments
RUN --mount=type=secret,id=github_token sh /tmp/install-uv.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace

ARG RUST_VERSION=stable
RUN rustup toolchain install "${RUST_VERSION}" && rustup default "${RUST_VERSION}"
ENV PATH="/home/ubuntu/.cargo/bin:${PATH}"
