#!/bin/sh
# start-open-webui.sh
# Container command for open-webui-service (installed as
# /usr/local/bin/start-open-webui). Checks that Ollama on the Docker host is
# reachable through the egress proxy, then runs Open WebUI in the
# foreground (its output is the container's log — `docker logs`). If Open
# WebUI exits, the container is kept alive so a shell can still be opened
# to investigate (docker exec -it -u ubuntu open-webui sh); restart it by
# hand with `start-open-webui`.
#
# Configuration comes from open-webui-service/docker-compose.yml's
# environment block (OLLAMA_BASE_URL, RAG_EMBEDDING_*, DATA_DIR, ...).

set -u

DATA_DIR="${DATA_DIR:-/data}"
mkdir -p "${DATA_DIR}"
# `open-webui serve` keeps its generated WEBUI_SECRET_KEY in
# ./.webui_secret_key — run from DATA_DIR so it persists with the data
# (otherwise every container recreate logs everyone out).
cd "${DATA_DIR}" || exit 1

echo "open-webui: checking Ollama at ${OLLAMA_BASE_URL} ..."
if tags="$(curl -fsS -m 10 "${OLLAMA_BASE_URL}/api/tags")"; then
    echo "open-webui: Ollama reachable — models: $(echo "${tags}" | jq -r '[.models[].name] | join(", ")')"
    if ! echo "${tags}" | jq -e --arg m "${RAG_EMBEDDING_MODEL}" \
        '.models[].name | select(. == $m or . == ($m + ":latest"))' >/dev/null; then
        echo "open-webui: WARNING: embedding model '${RAG_EMBEDDING_MODEL}' not found — RAG needs it." >&2
        echo "open-webui:          run on the host: ollama pull ${RAG_EMBEDDING_MODEL}" >&2
    fi
else
    echo "open-webui: WARNING: Ollama not reachable at ${OLLAMA_BASE_URL}." >&2
    echo "open-webui:          Is Ollama running on the host? (Linux host: OLLAMA_HOST=0.0.0.0)" >&2
    echo "open-webui:          Starting anyway — it will pick Ollama up once it's running." >&2
fi

open-webui serve --host 0.0.0.0 --port 8080
echo "open-webui: exited with status $? — container kept alive; restart with 'start-open-webui'." >&2
exec sleep infinity
