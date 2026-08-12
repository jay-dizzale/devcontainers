FROM ubuntu:noble

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
ARG AGENTS=
RUN --mount=type=secret,id=github_token AGENTS="${AGENTS}" sh /tmp/agents/install-agents.sh

## Dependencies for ruby-build
ADD ruby/scripts/ /tmp/
RUN --mount=type=secret,id=github_token sh /tmp/install-ruby.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
