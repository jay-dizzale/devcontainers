FROM ubuntu:noble

LABEL description="Toolbelt environment for software development"

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
RUN --mount=type=secret,id=github_token sh /tmp/agents/install-agents.sh

## Install `java` (Amazon Corretto)
ADD ./java/scripts/ /tmp/
ARG JAVA_VERSION=
RUN --mount=type=secret,id=github_token sh /tmp/install-java.sh
RUN --mount=type=secret,id=github_token sh /tmp/install-maven.sh
ENV PATH=/opt/maven/bin:$PATH

## Install `uv` to manage Python versions and virtual environments
ADD ./python-with-uv/scripts/ /tmp/
RUN --mount=type=secret,id=github_token sh /tmp/install-uv.sh

## Install `node` (including npm)
ADD ./web/scripts/ /tmp/
RUN sh /tmp/install-nodejs.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
