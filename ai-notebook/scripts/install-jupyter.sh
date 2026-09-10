#!/bin/sh
# install-jupyter.sh
# Installs JupyterLab into a dedicated system-wide venv managed by uv, so
# it's usable regardless of which user runs it — a per-user `uv tool
# install` would only be visible under the installing user's $HOME, but
# this script runs as root during the build while the container runs as
# `ubuntu` at runtime.
#
# Usage:
#   ./install-jupyter.sh <version>
#
# Or via environment variable:
#   JUPYTERLAB_VERSION=4.2.5 ./install-jupyter.sh
#
# Dependencies: uv (already on PATH — installed by install-uv.sh)
set -eu

JUPYTERLAB_VERSION="${1:-${JUPYTERLAB_VERSION:-}}"
JUPYTER_VENV=/opt/jupyter-venv

echo "Creating venv at ${JUPYTER_VENV} ..."
uv venv "${JUPYTER_VENV}"

if [ -n "${JUPYTERLAB_VERSION}" ]; then
    echo "Installing jupyterlab==${JUPYTERLAB_VERSION} ..."
    uv pip install --python "${JUPYTER_VENV}/bin/python" "jupyterlab==${JUPYTERLAB_VERSION}"
else
    echo "Installing latest jupyterlab ..."
    uv pip install --python "${JUPYTER_VENV}/bin/python" jupyterlab
fi

ln -sf "${JUPYTER_VENV}/bin/jupyter"     /usr/local/bin/jupyter
ln -sf "${JUPYTER_VENV}/bin/jupyter-lab" /usr/local/bin/jupyter-lab

chown -R ubuntu:ubuntu "${JUPYTER_VENV}"

echo ""
echo "Done: JupyterLab installed to ${JUPYTER_VENV}"
"${JUPYTER_VENV}/bin/jupyter" --version
