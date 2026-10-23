# Built locally by run.py from common/Dockerfile (see BASE_IMAGE in devtool/launcher.py).
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
ENV DEVCONTAINER_TYPE=rust-toolbelt
LABEL description="Toolbelt environment for Rust development"

WORKDIR /tmp

## Install rustup (as root, from apt)
ADD rust-toolbelt/scripts/ /tmp/
RUN sh /tmp/install-rust.sh

## Cleanup
RUN rm -rf /tmp/*

## Install the Rust toolchain (per-user, so as `ubuntu`). RUST_VERSION comes from
## docker-compose.yml; empty means the latest stable release.
USER ubuntu
ARG RUST_VERSION=
RUN rustup toolchain install "${RUST_VERSION:-stable}" && rustup default "${RUST_VERSION:-stable}"
ENV PATH="/home/ubuntu/.cargo/bin:${PATH}"

VOLUME [ "/workspace" ]
WORKDIR /workspace
