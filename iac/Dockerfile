FROM ubuntu:noble

LABEL description="Development environment for ARM architecture with tools for Terraform, Trivy, and TFLint"

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
ARG AGENTS=
RUN --mount=type=secret,id=github_token AGENTS="${AGENTS}" sh /tmp/agents/install-agents.sh

ADD ./iac/scripts/ /tmp/
ADD ../opentofu/scripts/ /tmp/

## Install `tenv` to manage multiple versions of Terraform / OpenTofu
RUN sh /tmp/install-tenv.sh

## Install `terraform-docs`
RUN sh /tmp/install-terraform-docs.sh

## Install `tflint`
RUN sh /tmp/install-tflint.sh

## Install `aws` (AWS CLI)
RUN sh /tmp/install-aws-cli.sh

## Install `az` (Azure CLI)
RUN sh /tmp/install-azure-cli.sh

## Install `spacectl` (Spacelift CLI)
RUN sh /tmp/install-spacectl.sh

## Install `java` (Amazon Corretto) — always resolves latest LTS
ADD ../java/scripts/ /tmp/
RUN --mount=type=secret,id=github_token sh /tmp/install-java.sh

## Install Kafka + MSK IAM Auth
RUN sh /tmp/install-kafka.sh

## Install `go` (GO-Lang)
ADD ../go/scripts /tmp/
RUN sh /tmp/install-go.sh
ENV PATH="/usr/local/go/bin:${PATH}"

## Install `uv` to manage python versions and venv
ADD ../uv/scripts/ /tmp/
RUN sh /tmp/install-uv.sh

## Install `node` (include NPM)
ADD ../web/scripts/ /tmp/
RUN sh /tmp/install-nodejs.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
