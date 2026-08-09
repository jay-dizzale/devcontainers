#!/bin/sh
# run.sh — Interactive launcher for docker-compose stacks.
# Usage: run.sh [-v /path/to/mount]
#        run.sh stop [-v /path/to/mount]   — stop & delete stacks mounted from that dir

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOCATION_DIR="$(pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "❌ ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# `stop` subcommand — find every compose project whose /workspace mount
# points at the given directory (default: current directory) and tear it
# down (containers, networks and anonymous volumes removed).
# ---------------------------------------------------------------------------
cmd_stop() {
    target="$1"
    echo "🔍 Looking for containers mounted from: $target"

    candidates="$(docker ps -a -q --filter "label=com.docker.compose.project" 2>/dev/null || true)"
    [ -n "$candidates" ] || die "No devcontainer stacks found."

    matches=""
    for cid in $candidates; do
        src="$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
        [ "$src" = "$target" ] && matches="$matches $cid"
    done
    [ -n "$matches" ] || die "No containers mounted from $target."

    projects="$(
        for cid in $matches; do
            docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}'
        done | sort -u
    )"

    echo "$projects" | while IFS='|' read -r proj workdir; do
        [ -n "$proj" ] || continue
        echo "🛑 Stopping & deleting stack '$proj' (in $workdir) ..."
        if [ -n "$workdir" ] && [ -d "$workdir" ]; then
            ( cd "$workdir" && COMPOSE_PROJECT_NAME="$proj" docker compose down -v ) \
                || echo "⚠️  Failed to tear down $proj" >&2
        else
            docker compose -p "$proj" down -v || echo "⚠️  Failed to tear down $proj" >&2
        fi
    done
    exit 0
}

# ---------------------------------------------------------------------------
# Arguments  (-v defaults to the directory run.sh was called from)
# ---------------------------------------------------------------------------
STOP=0
VOLUME="$INVOCATION_DIR"
REBUILD=0
DEBUG=0
while [ $# -gt 0 ]; do
    case "$1" in
        stop)         STOP=1;    shift ;;
        -v|--volume)
            [ $# -ge 2 ] || die "--volume requires a value"
            VOLUME="$2"; shift 2 ;;
        -r|--rebuild) REBUILD=1; shift ;;
        --debug)      DEBUG=1;   shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done
export VOLUME

if [ "$STOP" = "1" ]; then
    cmd_stop "$(cd "$VOLUME" && pwd)"
fi

PROGRESS=""
[ "$DEBUG" = "1" ] && PROGRESS="--progress=plain"

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
# Force rebuild — tears down first so --no-cache is never skipped.
# ---------------------------------------------------------------------------
if [ "$REBUILD" = "1" ]; then
    echo "🔨 Rebuilding from scratch (no cache) ..."
    docker compose down 2>/dev/null || true
    # shellcheck disable=SC2086
    docker compose build --no-cache $PROGRESS || die "Failed to build stack."
fi

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
    _up_build="--build"
    [ "$REBUILD" = "1" ] && _up_build=""
    # shellcheck disable=SC2086
    docker compose up -d $_up_build || die "Failed to start stack."
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
