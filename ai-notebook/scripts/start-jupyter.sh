#!/bin/sh
# start-jupyter.sh — the container's main process (see docker-compose.yml
# `command`). Launches JupyterLab in the background against $HOME, then
# blocks forever so the container itself keeps idling like every other
# environment (still reachable via `run.sh`/`docker compose exec`).
#
# Bound to 0.0.0.0 *inside* the container; only reachable from the host via
# the 127.0.0.1-bound port published in docker-compose.yml, so no token is
# needed for convenience.
set -eu

LOG_FILE="$HOME/.jupyter-lab.log"

# JupyterLab can only browse one directory tree (its --ServerApp.root_dir).
# /workspace (your data) and ~/notebooks (your scripts, see docker-compose.yml
# NOTEBOOKS_PATH) are separate top-level mounts, so symlink /workspace *under*
# $HOME instead of the other way round — never write into the host-mounted
# /workspace itself.
[ -L "$HOME/workspace" ] || ln -s /workspace "$HOME/workspace"

nohup jupyter lab \
    --ip=0.0.0.0 \
    --no-browser \
    --ServerApp.token='' \
    --ServerApp.root_dir="$HOME" \
    > "$LOG_FILE" 2>&1 &

echo "🔬 JupyterLab starting in background (log: $LOG_FILE) — http://localhost:8888"
echo "   ~/workspace → your mounted data (symlink to /workspace)"
echo "   ~/notebooks → your notebook scripts (bind mount, see NOTEBOOKS_PATH)"

exec sleep infinity
