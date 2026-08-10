FROM ubuntu:noble

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
ARG INSTALL_CLAUDE=0
RUN [ "${INSTALL_CLAUDE}" = "1" ] && sh /tmp/install-claude.sh || true

# Install Java
ADD ./java/scripts/ /tmp/
ARG JAVA_VERSION=
RUN --mount=type=secret,id=github_token sh /tmp/install-java.sh

# Install Maven
RUN sh /tmp/install-maven.sh
ENV PATH=/opt/maven/bin:$PATH

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
