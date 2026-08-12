FROM ubuntu:noble

LABEL description="Development environment for ARM architecture with tools for OpenTofu"

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
ARG AGENTS=
RUN --mount=type=secret,id=github_token AGENTS="${AGENTS}" sh /tmp/agents/install-agents.sh

ADD ./opentofu/scripts/ /tmp/

## Install `tenv` to manage multiple versions of Terraform / OpenTofu
RUN --mount=type=secret,id=github_token sh /tmp/install-tenv.sh

## Install `terraform-docs`
RUN --mount=type=secret,id=github_token sh /tmp/install-terraform-docs.sh

## Install `tflint`
RUN --mount=type=secret,id=github_token sh /tmp/install-tflint.sh

## Cleanup
RUN rm -rf /tmp/* 

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
