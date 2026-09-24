# Built locally by run.sh from common/Dockerfile (see BASE_IMAGE in run.sh).
ARG BASE_IMAGE=toolbelt-base:latest
FROM ${BASE_IMAGE}

# Build-only: no TTY during docker build, so keep debconf from probing for a frontend
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.authors="jay-dizzale"
ENV DEVCONTAINER_TYPE=java-toolbelt
LABEL description="Toolbelt environment for Java development"

WORKDIR /tmp

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
