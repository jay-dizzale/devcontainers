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
ENV DEVCONTAINER_TYPE=infrastructure-toolbelt

LABEL description="Toolbelt environment for infrastructure development"

WORKDIR /tmp

ADD ./infrastructure-toolbelt/scripts/ /tmp/

## Install `tenv` to manage multiple versions of Terraform / OpenTofu
RUN --mount=type=secret,id=github_token sh /tmp/install-tenv.sh

## Install `terraform-docs`
RUN --mount=type=secret,id=github_token sh /tmp/install-terraform-docs.sh

## Install `tflint`
RUN --mount=type=secret,id=github_token sh /tmp/install-tflint.sh

## Install `aws` (AWS CLI)
RUN sh /tmp/install-aws-cli.sh

## Install `az` (Azure CLI)
RUN sh /tmp/install-azure-cli.sh

## Install `spacectl` (Spacelift CLI)
RUN --mount=type=secret,id=github_token sh /tmp/install-spacectl.sh

## Install Kafka + MSK IAM Auth
RUN --mount=type=secret,id=github_token sh /tmp/install-kafka.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
