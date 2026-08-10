FROM ubuntu:noble

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
ARG INSTALL_CLAUDE=0
RUN [ "${INSTALL_CLAUDE}" = "1" ] && sh /tmp/install-claude.sh || true

## Install `uv` to manage python versions and venv
ADD uv/scripts/ /tmp/
RUN sh /tmp/install-uv.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
