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
# Derive a stable, per-volume project name so the same directory always maps
# to the same container (and distinct directories get distinct containers).
# ---------------------------------------------------------------------------
VOLUME_HASH="$(printf '%s' "$VOLUME" | cksum | cut -d' ' -f1)"
COMPOSE_PROJECT_NAME="$(basename "$COMPOSE_DIR")_${VOLUME_HASH}"
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
