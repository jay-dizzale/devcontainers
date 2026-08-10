FROM ubuntu:noble

LABEL description="Development environment for ARM architecture with tools for OpenTofu"

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
ARG INSTALL_CLAUDE=0
RUN [ "${INSTALL_CLAUDE}" = "1" ] && sh /tmp/install-claude.sh || true

ADD ./opentofu/scripts/ /tmp/

## Install `tenv` to manage multiple versions of Terraform / OpenTofu
RUN sh /tmp/install-tenv.sh

## Install `terraform-docs`
RUN sh /tmp/install-terraform-docs.sh

## Install `tflint`
RUN sh /tmp/install-tflint.sh

## Cleanup
RUN rm -rf /tmp/* 

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
