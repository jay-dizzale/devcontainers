FROM ubuntu:noble

LABEL org.opencontainers.image.authors="jay-dizzale"
ENV DEVCONTAINER_TYPE=infrastructure-toolbelt

LABEL description="Toolbelt environment for infrastructure development"

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
RUN --mount=type=secret,id=github_token sh /tmp/agents/install-agents.sh

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
