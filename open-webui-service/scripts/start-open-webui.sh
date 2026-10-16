#!/bin/sh
# start-open-webui.sh
# Container command for open-webui-service (installed as
# /usr/local/bin/start-open-webui). Checks that Ollama on the Docker host is
# reachable through the egress proxy, then hands off to the upstream
# image's own backend/start.sh in the foreground (its output is the
# container's log — `docker logs`). If Open WebUI exits, the container is
# kept alive so a shell can still be opened to investigate
# (docker exec -it -u ubuntu open-webui sh); restart it by hand with
# `start-open-webui`.
#
# Configuration comes from open-webui-service/docker-compose.yml's
# environment block (OLLAMA_BASE_URL, RAG_EMBEDDING_*, DATA_DIR,
# WEBUI_SECRET_KEY_FILE, ...). WEBUI_SECRET_KEY_FILE is pointed at DATA_DIR
# so the generated secret persists with the data volume — otherwise
# start.sh's default (relative to /app/backend) would be lost, and
# everyone logged out, on every container recreate.

set -u

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

bash /app/backend/start.sh
echo "open-webui: exited with status $? — container kept alive; restart with 'start-open-webui'." >&2
exec sleep infinity
