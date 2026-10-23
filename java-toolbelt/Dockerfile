# Built locally by run.sh from common/Dockerfile (see BASE_IMAGE in run.sh).
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
