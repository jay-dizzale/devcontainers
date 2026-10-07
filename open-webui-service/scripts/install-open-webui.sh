#!/bin/sh
# install-open-webui.sh
# Installs Open WebUI from PyPI into a dedicated virtualenv at /opt/open-webui
# (uv-managed Python 3.12 under /opt/uv-python, so it is usable by every
# user, not just root), with the CPU-only PyTorch build — Open WebUI pulls in
# torch via sentence-transformers, and the default PyPI wheel drags in
# several GB of CUDA libraries a devcontainer never uses.
#
# Integrity: there is no upstream signature/checksum file for a PyPI
# dependency tree like the other install scripts verify against. Packages
# come from PyPI (and download.pytorch.org for torch) over HTTPS, resolved
# and installed by uv.
#
# Usage:
#   ./install-open-webui.sh <version>
#
# Or via environment variable:
#   OPEN_WEBUI_VERSION=0.6.5 ./install-open-webui.sh
#
# Dependencies: uv, wget, jq

set -eu

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

OPEN_WEBUI_VERSION="${1:-${OPEN_WEBUI_VERSION:-}}"
if [ -z "${OPEN_WEBUI_VERSION}" ]; then
    echo "Resolving latest stable Open WebUI release ..."
    OPEN_WEBUI_VERSION="$(wget -qO- 'https://pypi.org/pypi/open-webui/json' | jq -r '.info.version')"
    [ -n "${OPEN_WEBUI_VERSION}" ] && [ "${OPEN_WEBUI_VERSION}" != "null" ] \
        || { echo "ERROR: could not resolve latest Open WebUI version" >&2; exit 1; }
fi

PYTHON_VERSION="3.12" # Open WebUI requires >=3.11,<3.13
VENV_DIR="/opt/open-webui"
export UV_PYTHON_INSTALL_DIR="/opt/uv-python"
export UV_NO_CACHE=1

echo "Open WebUI installation"
echo "  Version:      ${OPEN_WEBUI_VERSION}"
echo "  Python:       ${PYTHON_VERSION}"
echo "  Virtualenv:   ${VENV_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

uv venv --python "${PYTHON_VERSION}" --python-preference only-managed "${VENV_DIR}"
uv pip install --python "${VENV_DIR}/bin/python" --torch-backend cpu \
    "open-webui==${OPEN_WEBUI_VERSION}"

ln -sf "${VENV_DIR}/bin/open-webui" /usr/local/bin/open-webui

echo ""
echo "Done: open-webui ${OPEN_WEBUI_VERSION}"
