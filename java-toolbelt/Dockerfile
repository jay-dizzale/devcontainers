FROM ubuntu:noble

LABEL org.opencontainers.image.authors="jay-dizzale"
ENV DEVCONTAINER_TYPE=java-toolbelt
LABEL description="Toolbelt environment for Java development"

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
RUN --mount=type=secret,id=github_token sh /tmp/agents/install-agents.sh

# Install Java
ADD ./java-toolbelt/scripts/ /tmp/
ARG JAVA_VERSION=
RUN --mount=type=secret,id=github_token sh /tmp/install-java.sh

# Install Maven
RUN --mount=type=secret,id=github_token sh /tmp/install-maven.sh
ENV PATH=/opt/maven/bin:$PATH

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace

## Install the Rust toolchain (rustup itself installed above, as root)
ARG RUST_VERSION=stable
RUN rustup toolchain install "${RUST_VERSION}" && rustup default "${RUST_VERSION}"
ENV PATH="/home/ubuntu/.cargo/bin:${PATH}"
