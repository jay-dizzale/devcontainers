FROM ubuntu:noble

LABEL org.opencontainers.image.authors="jay-dizzale"
ENV DEVCONTAINER_TYPE=pico-development

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
RUN --mount=type=secret,id=github_token sh /tmp/agents/install-agents.sh

## Install PICO toolchain to compile for RP2040
ADD ./pico-development/scripts /tmp/
RUN --mount=type=secret,id=github_token sh /tmp/install-pico-toolchain.sh
ENV PICO_SDK_PATH=/opt/pico/pico-sdk \
    PICO_EXTRAS_PATH=/opt/pico/pico-extras \
    PICO_EXAMPLES_PATH=/opt/pico/pico-examples

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
