#!/bin/sh
# run.sh — Interactive launcher for docker-compose stacks.
# Usage: run.sh [-v /path/to/mount]

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOCATION_DIR="$(pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "❌ ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arguments  (-v defaults to the directory run.sh was called from)
# ---------------------------------------------------------------------------
VOLUME="$INVOCATION_DIR"
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--volume)
            [ $# -ge 2 ] || die "--volume requires a value"
            VOLUME="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
export VOLUME

# ---------------------------------------------------------------------------
# Proxy — source proxy.env if present; Docker BuildKit forwards these to build
# ---------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/proxy.env" ]; then
    . "$SCRIPT_DIR/proxy.env"
    export HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
fi

pick_from_list() {
    label="$1"; shift
    echo "${label}:" >&2
    i=1
    for item do
        printf "  [%s] %s\n" "$i" "$item" >&2
        i=$((i + 1))
    done
    printf "Select: " >&2
    read -r choice
    echo "$choice"
}

# ---------------------------------------------------------------------------
# Discover compose files (max depth 2, deduplicated)
# ---------------------------------------------------------------------------
COMPOSE_DIRS="$(
    find -L "$SCRIPT_DIR" -maxdepth 2 -type f \( -name docker-compose.yml -o -name docker-compose.yaml \) \
    | xargs -I{} dirname {} \
    | sort -u
)"

[ -n "$COMPOSE_DIRS" ] || die "No docker-compose files found."

# ---------------------------------------------------------------------------
# Select project (display basename only, keep full path for cd)
# ---------------------------------------------------------------------------
COMPOSE_NAMES="$(
    echo "$COMPOSE_DIRS" \
    | while IFS= read -r d; do basename "$d"; done
)"

# shellcheck disable=SC2086
choice="$(pick_from_list "📦 Available environments" $COMPOSE_NAMES)"
echo "$COMPOSE_DIRS" | grep -q . || die "No projects available."

COMPOSE_DIR="$(echo "$COMPOSE_DIRS" | awk -v n="$choice" 'NR==n{print; exit}')"
[ -n "$COMPOSE_DIR" ] || die "Invalid selection: $choice"

cd "$COMPOSE_DIR" || die "Cannot enter $COMPOSE_DIR"
echo "📂 Working in: $(pwd)"
echo "📁 Mounting volume: ${VOLUME}"

# ---------------------------------------------------------------------------
# Derive a human-readable project name: <env>_<parent>_<current>
# e.g. java_projects_myapp  — sanitised to lowercase alphanumeric + hyphens.
# ---------------------------------------------------------------------------
_sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//'; }
_vol_parent="$(_sanitize "$(basename "$(dirname "$VOLUME")")")"
_vol_current="$(_sanitize "$(basename "$VOLUME")")"
if [ -n "$_vol_parent" ]; then
    COMPOSE_PROJECT_NAME="$(basename "$COMPOSE_DIR")_${_vol_parent}_${_vol_current}"
else
    COMPOSE_PROJECT_NAME="$(basename "$COMPOSE_DIR")_${_vol_current}"
fi
export COMPOSE_PROJECT_NAME

# ---------------------------------------------------------------------------
# Start stack — reuse the existing container if it's already running.
# ---------------------------------------------------------------------------
if [ -n "$(docker compose ps --status running -q 2>/dev/null || true)" ]; then
    echo "♻️  Stack already running — connecting to the existing container."
else
    case "$(basename "$COMPOSE_DIR")" in
        java)
            printf "☕ Java major version:\n" >&2
            printf "  [1] 8\n  [2] 11\n  [3] 17\n  [4] 21\n  [5] 25\n" >&2
            printf "Select [ENTER for latest LTS]: "
            read -r _jv
            case "$_jv" in
                1) export JAVA_VERSION=8  ;;
                2) export JAVA_VERSION=11 ;;
                3) export JAVA_VERSION=17 ;;
                4) export JAVA_VERSION=21 ;;
                5) export JAVA_VERSION=25 ;;
            esac
            ;;
    esac

    printf "Install Claude Code? [y/N]: "
    read -r claude_choice
    case "$claude_choice" in
        y|Y|yes|YES) export INSTALL_CLAUDE=1 ;;
        *)            export INSTALL_CLAUDE=0 ;;
    esac
    docker compose up -d --build || die "Failed to start stack."
fi

cleanup() {
    echo
    echo "🛑 Stopping stack …"
    docker compose down -v
}

# ---------------------------------------------------------------------------
# Select service
# ---------------------------------------------------------------------------
SERVICES="$(docker compose config --services)" || die "Failed to list services."
[ -n "$SERVICES" ] || die "No services defined in compose file."

SVC_COUNT="$(echo "$SERVICES" | wc -l)"

if [ "$SVC_COUNT" -eq 1 ]; then
    SERVICE="$SERVICES"
    echo "🐳 Auto-selected service: ${SERVICE}"
else
    # shellcheck disable=SC2086
    svc_choice="$(pick_from_list "🐳 Available services (enter 's' to skip shell)" $SERVICES)"

    if [ "$svc_choice" = "s" ]; then
        echo "⏭️  Skipping shell. Stack is running — press Ctrl-C to stop."
        trap cleanup INT TERM
        wait
        exit 0
    fi

    SERVICE="$(echo "$SERVICES" | awk -v n="$svc_choice" 'NR==n{print; exit}')"
    [ -n "$SERVICE" ] || die "Invalid selection: $svc_choice"
fi

# ---------------------------------------------------------------------------
# Exit strategy
# ---------------------------------------------------------------------------
printf "On shell exit — [y/yes/down] bring stack down  [ENTER] keep running (default): "
read -r stop_choice
case "$stop_choice" in
  y|Y|yes|YES|down|DOWN) trap cleanup EXIT ;;
esac

# ---------------------------------------------------------------------------
# Open shell
# ---------------------------------------------------------------------------
echo "🚀 Opening zsh in service '${SERVICE}' …"
docker compose exec -ti "$SERVICE" zsh
