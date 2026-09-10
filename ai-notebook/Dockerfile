FROM ubuntu:noble

LABEL org.opencontainers.image.authors="jay-dizzale"
LABEL description="Python/uv environment for AI projects, with JupyterLab running in the background"
ENV DEVCONTAINER_TYPE=ai-notebook

## Install common tools
ADD ./common/lib/ /usr/local/lib/shell/
ADD ./common/scripts/ /tmp/
ADD ./common/agents/ /tmp/agents/
WORKDIR /tmp
RUN --mount=type=secret,id=github_token sh /tmp/install-common.sh
RUN --mount=type=secret,id=github_token sh /tmp/agents/install-agents.sh

## Install `uv` to manage python versions and venvs
ADD ./python-with-uv/scripts/ /tmp/
RUN --mount=type=secret,id=github_token sh /tmp/install-uv.sh

## Install JupyterLab (system-wide venv under /opt/jupyter-venv)
ADD ./ai-notebook/scripts/ /tmp/
RUN sh /tmp/install-jupyter.sh

## start-jupyter.sh is the runtime entrypoint — install it before the /tmp
## cleanup below so it survives into the final image.
RUN install -m 755 /tmp/start-jupyter.sh /usr/local/bin/start-jupyter.sh

## Cleanup
RUN rm -rf /tmp/*

VOLUME [ "/workspace" ]
USER ubuntu
WORKDIR /workspace
