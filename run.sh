#!/bin/sh
# run.sh — Interactive launcher for docker-compose stacks.
# Usage: run.sh [-v /path/to/mount]
#        run.sh stop [-v /path/to/mount]   — stop & delete stacks mounted from that dir
#        run.sh stop --all                 — stop & delete every devcontainer stack
#        run.sh list                       — list every devcontainer stack
#        run.sh logs [-v /path/to/mount] [-f]  — view/tail the egress proxy's access log
#        run.sh proxy start|stop [-v /path/to/mount]  — toggle just the proxy sidecar
#        run.sh proxy status [-v /path/to/mount]      — proxy state + recent access.log
#        run.sh proxy clear-log [-v /path/to/mount]   — truncate access.log in place
#        run.sh proxy overview [-v /path/to/mount] [-f]  — colorized allow/deny summary + add a domain
#        run.sh proxy allow <domain> [-e <env-toolbelt>]  — whitelist a domain
#        run.sh build-base [-r]            — build (or refresh) the shared base image only

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOCATION_DIR="$(pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "❌ ERROR: $*" >&2; exit 1; }

# Moved up from near the interactive flow further down so early-dispatch
# subcommands (e.g. `logs`) can use it too — it has no dependencies on
# anything defined later in this file.
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

cmd_help() {
    cat <<'EOF'
run.sh — Interactive launcher for docker-compose devcontainer stacks.

Usage:
  run.sh [-v /path/to/mount] [-r] [--debug]
      Interactively pick an environment + service, build/reuse the
      container, and open a zsh shell in it.

  run.sh stop [-v /path/to/mount]
      Stop & delete stacks mounted from that directory (default: cwd).

  run.sh stop --all
      Stop & delete every devcontainer stack, from any directory.

  run.sh list
      List every devcontainer stack (project, env, service, status, workspace).

  run.sh logs [-v /path/to/mount] [-f]
      Show the whitelist proxy's access log (allowed + denied domains) for
      the stack mounted from that directory (default: cwd). -f follows it
      live; prompts if more than one stack is running from that directory.

  run.sh proxy start [-v /path/to/mount]
  run.sh proxy stop [-v /path/to/mount]
      Start/stop just the proxy sidecar for the stack mounted from that
      directory, without touching `dev` or tearing the stack down. Stopping
      it blocks all of dev's egress until it's started again.

  run.sh proxy status [-v /path/to/mount]
      Proxy container/health state, whitelisted domain count, and the last
      15 lines of access.log.

  run.sh proxy clear-log [-v /path/to/mount]
      Truncate access.log in place (file stays, content is emptied).

  run.sh proxy overview [-v /path/to/mount] [-f]
      Colorized allow/deny summary of access.log — one line per domain,
      green for allowed, red for denied, with a hit count and how long ago
      it was last seen. Ends with a prompt to whitelist a new domain
      (added to that stack's own <env>-toolbelt.txt) — Enter to skip.
      -f redraws the same summary every 2s instead (Ctrl-C to stop); no
      prompt in that mode.

  run.sh proxy allow <domain> [-e <env-toolbelt>]
      Add a domain to common/proxy/whitelist.d/00-common.txt (every
      environment), or to a specific <env>-toolbelt.txt with -e (e.g.
      -e java-toolbelt) — restarts every currently-running proxy container
      so the change applies immediately.

  run.sh build-base [-r] [--debug]
      Build the shared base image (toolbelt-base:latest) and exit. Only
      rebuilds if common/ changed since it was last built; -r forces a
      from-scratch rebuild. Honours RUST_VERSION from the environment.

  run.sh -h | --help | help
      Show this help.

Options:
  -v, --volume <path>   Directory to mount at /workspace (default: cwd).
  -r, --rebuild         Force a from-scratch rebuild (--no-cache).
  -f, --follow          With `logs`, follow the access log instead of a one-shot view.
  --debug               Verbose docker build output (--progress=plain).

If installed via setup.sh, all of the above also work as `dev ...`
(e.g. `dev stop --all`, `dev list`).
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Given a list of container IDs, group them by compose project and tear
# each project down (containers, networks and anonymous volumes removed).
# ---------------------------------------------------------------------------
_teardown_containers() {
    projects="$(
        for cid in "$@"; do
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
}

# ---------------------------------------------------------------------------
# Print the IDs of every container that belongs to this project, i.e. carries
# the `devcontainer.env` label set in each <env>/docker-compose.yml (from any
# directory). Unrelated docker-compose projects on the host are never matched.
# ---------------------------------------------------------------------------
_all_workspace_containers() {
    docker ps -a -q --filter "label=devcontainer.env" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# `stop` subcommand — find every compose project whose /workspace mount
# points at the given directory (default: current directory) and tear it
# down.
# ---------------------------------------------------------------------------
cmd_stop() {
    target="$1"
    echo "🔍 Looking for containers mounted from: $target"

    candidates="$(docker ps -a -q --filter "label=devcontainer.env" 2>/dev/null || true)"
    [ -n "$candidates" ] || die "No devcontainer stacks found."

    matches=""
    for cid in $candidates; do
        src="$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
        [ "$src" = "$target" ] && matches="$matches $cid"
    done
    [ -n "$matches" ] || die "No containers mounted from $target."

    # shellcheck disable=SC2086
    _teardown_containers $matches
    exit 0
}

# ---------------------------------------------------------------------------
# `stop --all` subcommand — tear down every devcontainer stack (scoped to
# /workspace mounts so it never touches unrelated docker-compose projects
# on the host).
# ---------------------------------------------------------------------------
cmd_stop_all() {
    echo "🔍 Looking for all devcontainer stacks ..."

    matches="$(_all_workspace_containers)"
    [ -n "$matches" ] || die "No devcontainer stacks found."

    # shellcheck disable=SC2086
    _teardown_containers $matches
    exit 0
}

# ---------------------------------------------------------------------------
# `list` subcommand — show every devcontainer stack (project, service,
# status, mounted workspace) regardless of which directory it was started
# from.
# ---------------------------------------------------------------------------
cmd_list() {
    matches="$(_all_workspace_containers)"
    if [ -z "$matches" ]; then
        echo "No devcontainer stacks found."
        exit 0
    fi

    printf "%-16s %-24s %-10s %-10s %s\n" "PROJECT" "ENV" "SERVICE" "STATUS" "WORKSPACE"
    for cid in $matches; do
        info="$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "devcontainer.env"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
        [ -n "$info" ] || continue
        IFS='|' read -r proj env svc status src <<EOF
$info
EOF
        printf "%-16s %-24s %-10s %-10s %s\n" "$proj" "$env" "$svc" "$status" "$src"
    done | sort -u
    exit 0
}

# ---------------------------------------------------------------------------
# Resolve the stack mounted from a directory to "project|env" on stdout.
# Shared by `logs` and every `proxy` subcommand. Prompts to pick one if more
# than one stack is running from that directory.
# ---------------------------------------------------------------------------
_resolve_stack() {
    target="$1"
    echo "🔍 Looking for containers mounted from: $target" >&2

    candidates="$(docker ps -a -q --filter "label=devcontainer.env" 2>/dev/null || true)"
    [ -n "$candidates" ] || die "No devcontainer stacks found."

    matches=""
    for cid in $candidates; do
        src="$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
        [ "$src" = "$target" ] && matches="$matches $cid"
    done
    [ -n "$matches" ] || die "No containers mounted from $target."

    proj_env_list="$(
        for cid in $matches; do
            docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "devcontainer.env"}}'
        done | sort -u
    )"

    count="$(echo "$proj_env_list" | wc -l)"
    if [ "$count" -eq 1 ]; then
        echo "$proj_env_list"
        return 0
    fi

    envs="$(echo "$proj_env_list" | cut -d'|' -f2)"
    # shellcheck disable=SC2086
    idx="$(pick_from_list "🐳 Multiple stacks running from this directory" $envs)"
    chosen="$(echo "$proj_env_list" | awk -v n="$idx" 'NR==n{print; exit}')"
    [ -n "$chosen" ] || die "Invalid selection: $idx"
    echo "$chosen"
}

# ---------------------------------------------------------------------------
# The `proxy` container ID for a compose project, running or not (`-a`) —
# callers that need a running container check .State.Running themselves.
# ---------------------------------------------------------------------------
_proxy_cid_for_project() {
    docker ps -a -q \
        --filter "label=com.docker.compose.project=${1}" \
        --filter "label=com.docker.compose.service=proxy" 2>/dev/null | head -n 1
}

# ---------------------------------------------------------------------------
# `logs` subcommand — tail (or one-shot view) the whitelist proxy's access
# log for the stack mounted from the given directory (default: cwd).
# ---------------------------------------------------------------------------
cmd_logs() {
    target="$1"; follow="$2"
    chosen="$(_resolve_stack "$target")"
    proj="$(echo "$chosen" | cut -d'|' -f1)"
    env="$(echo "$chosen" | cut -d'|' -f2)"

    proxy_cid="$(_proxy_cid_for_project "$proj")"
    [ -n "$proxy_cid" ] || die "No 'proxy' container found for stack '$proj' ($env)."
    [ "$(docker inspect "$proxy_cid" --format '{{.State.Running}}' 2>/dev/null || echo false)" = "true" ] \
        || die "Proxy for '$env' (project $proj) isn't running — 'sh run.sh proxy start' to bring it back up."

    # No -t: tail doesn't need a TTY, and this way `logs` also works when
    # run.sh's own stdin/stdout aren't a terminal (e.g. piped/scripted).
    if [ "$follow" = "1" ]; then
        echo "📜 Tailing access log for '$env' (project $proj) — Ctrl-C to stop ..."
        docker exec -i "$proxy_cid" tail -n 50 -f /var/log/squid/access.log
    else
        echo "📜 Access log for '$env' (project $proj):"
        docker exec -i "$proxy_cid" tail -n 50 /var/log/squid/access.log
    fi
    exit 0
}

# ---------------------------------------------------------------------------
# `proxy start`/`proxy stop` — toggle just the proxy sidecar for the stack
# mounted from a directory, without touching `dev` or tearing anything down.
# ---------------------------------------------------------------------------
cmd_proxy_start() {
    chosen="$(_resolve_stack "$1")"
    proj="$(echo "$chosen" | cut -d'|' -f1)"
    env="$(echo "$chosen" | cut -d'|' -f2)"

    cid="$(_proxy_cid_for_project "$proj")"
    [ -n "$cid" ] || die "No 'proxy' container found for stack '$proj' ($env). Start the stack first with 'sh run.sh'."

    if [ "$(docker inspect "$cid" --format '{{.State.Running}}' 2>/dev/null || echo false)" = "true" ]; then
        echo "✅ Proxy for '$env' (project $proj) is already running."
        exit 0
    fi

    echo "▶️  Starting proxy for '$env' (project $proj) ..."
    docker start "$cid" >/dev/null || die "Failed to start proxy container."
    echo "✅ Proxy started — dev's egress is allowed again."
    exit 0
}

cmd_proxy_stop() {
    chosen="$(_resolve_stack "$1")"
    proj="$(echo "$chosen" | cut -d'|' -f1)"
    env="$(echo "$chosen" | cut -d'|' -f2)"

    cid="$(_proxy_cid_for_project "$proj")"
    [ -n "$cid" ] || die "No 'proxy' container found for stack '$proj' ($env)."

    if [ "$(docker inspect "$cid" --format '{{.State.Running}}' 2>/dev/null || echo false)" != "true" ]; then
        echo "ℹ️  Proxy for '$env' (project $proj) is already stopped."
        exit 0
    fi

    echo "⏸️  Stopping proxy for '$env' (project $proj) — dev's egress will be blocked until it's started again ..."
    docker stop "$cid" >/dev/null || die "Failed to stop proxy container."
    echo "✅ Proxy stopped."
    exit 0
}

# ---------------------------------------------------------------------------
# `proxy status` — container/health state, whitelisted domain count, and a
# short tail of access.log, for the stack mounted from a directory.
# ---------------------------------------------------------------------------
cmd_proxy_status() {
    chosen="$(_resolve_stack "$1")"
    proj="$(echo "$chosen" | cut -d'|' -f1)"
    env="$(echo "$chosen" | cut -d'|' -f2)"

    cid="$(_proxy_cid_for_project "$proj")"
    [ -n "$cid" ] || die "No 'proxy' container found for stack '$proj' ($env)."

    status="$(docker inspect "$cid" --format '{{.State.Status}}' 2>/dev/null || echo unknown)"
    health="$(docker inspect "$cid" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' 2>/dev/null || echo unknown)"

    echo "📡 Proxy status for '$env' (project $proj)"
    echo "   container: $status (health: $health)"

    if [ "$status" != "running" ]; then
        echo "   (not running — 'sh run.sh proxy start' to bring it back up)"
        exit 0
    fi

    domains="$(docker exec "$cid" sh -c 'wc -l < /etc/squid/whitelist.txt' 2>/dev/null || echo "?")"
    echo "   whitelisted domains: $domains"

    echo "   recent access.log:"
    docker exec -i "$cid" tail -n 15 /var/log/squid/access.log 2>/dev/null | sed 's/^/     /'
    exit 0
}

# ---------------------------------------------------------------------------
# `proxy clear-log` — empty access.log in place (truncate, not delete) for
# the stack mounted from a directory.
# ---------------------------------------------------------------------------
cmd_proxy_clear_log() {
    chosen="$(_resolve_stack "$1")"
    proj="$(echo "$chosen" | cut -d'|' -f1)"
    env="$(echo "$chosen" | cut -d'|' -f2)"

    cid="$(_proxy_cid_for_project "$proj")"
    [ -n "$cid" ] || die "No 'proxy' container found for stack '$proj' ($env)."
    [ "$(docker inspect "$cid" --format '{{.State.Running}}' 2>/dev/null || echo false)" = "true" ] \
        || die "Proxy for '$env' (project $proj) isn't running — 'sh run.sh proxy start' first."

    docker exec -u root -i "$cid" sh -c ': > /var/log/squid/access.log' \
        || die "Failed to clear access.log."
    echo "🧹 Cleared access.log for '$env' (project $proj)."
    exit 0
}

# ---------------------------------------------------------------------------
# Renders one snapshot of the colorized ALLOW/DENY summary for a proxy
# container — shared by the one-shot and --follow modes of `proxy overview`.
# ---------------------------------------------------------------------------
_render_overview() {
    cid="$1"; env="$2"; proj="$3"

    if [ -t 1 ]; then
        _green="$(printf '\033[32m')"; _red="$(printf '\033[31m')"
        _bold="$(printf '\033[1m')"; _reset="$(printf '\033[0m')"
    else
        _green=""; _red=""; _bold=""; _reset=""
    fi

    now="$(date +%s)"
    echo "${_bold}📡 Egress overview — '$env' (project $proj)${_reset}  [$(date '+%H:%M:%S')]"
    echo

    # Groups by host regardless of whether it came from a CONNECT (HTTPS,
    # e.g. "github.com:443") or a plain-HTTP GET (e.g. "http://host/path")
    # line — strip scheme, path, and port down to just the host. $4 is
    # Squid's "code/status" field (e.g. TCP_TUNNEL/200, TCP_DENIED/403); $7
    # is the URL. See common/proxy/squid.conf for the full field layout.
    summary="$(docker exec "$cid" cat /var/log/squid/access.log 2>/dev/null | awk '
        {
            code = $4; url = $7
            split(code, cs, "/")
            verdict = (cs[1] ~ /DENIED/) ? "DENY" : "ALLOW"
            host = url
            sub(/^[a-zA-Z]+:\/\//, "", host)
            sub(/\/.*/, "", host)
            sub(/:[0-9]+$/, "", host)
            if (host == "") next
            key = verdict "\t" host
            count[key]++
            if ($1 + 0 > last[key]) last[key] = $1
        }
        END {
            for (k in count) print k "\t" count[k] "\t" last[k]
        }
    ')"

    if [ -z "$summary" ]; then
        echo "   (no traffic logged yet)"
    else
        echo "$summary" | sort -t "$(printf '\t')" -k2,2 | while IFS="$(printf '\t')" read -r verdict host cnt last_ts; do
            ago=$((now - ${last_ts%.*}))
            if [ "$verdict" = "ALLOW" ]; then
                printf "   %s✅ ALLOW%s  %-40s  %3sx  %ss ago\n" "$_green" "$_reset" "$host" "$cnt" "$ago"
            else
                printf "   %s⛔ DENY %s  %-40s  %3sx  %ss ago\n" "$_red" "$_reset" "$host" "$cnt" "$ago"
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# `proxy overview` — colorized ALLOW/DENY summary of access.log (grouped by
# domain, with a hit count and how long ago it was last seen), for the
# stack mounted from a directory.
#
# One-shot (default): snapshot, then an interactive prompt to whitelist a
# new domain on the spot (added to that stack's own <env>-toolbelt.txt).
# --follow: clears and redraws the same snapshot every 2s until Ctrl-C —
# no prompt in this mode, since it's meant for passive "leave it on screen"
# monitoring, same spirit as `run.sh logs -f`.
# ---------------------------------------------------------------------------
cmd_proxy_overview() {
    target="$1"; follow="$2"
    chosen="$(_resolve_stack "$target")"
    proj="$(echo "$chosen" | cut -d'|' -f1)"
    env="$(echo "$chosen" | cut -d'|' -f2)"

    cid="$(_proxy_cid_for_project "$proj")"
    [ -n "$cid" ] || die "No 'proxy' container found for stack '$proj' ($env)."
    [ "$(docker inspect "$cid" --format '{{.State.Running}}' 2>/dev/null || echo false)" = "true" ] \
        || die "Proxy for '$env' (project $proj) isn't running — 'sh run.sh proxy start' first."

    if [ "$follow" = "1" ]; then
        trap 'echo; echo "👋 Stopped watching."; exit 0' INT TERM
        while true; do
            # \033[2J\033[H: clear screen + cursor to top-left, same
            # mechanism as the color codes above — plain ANSI, no
            # dependency on `clear`/terminfo being installed.
            [ -t 1 ] && printf '\033[2J\033[H'
            _render_overview "$cid" "$env" "$proj"
            echo
            echo "(Ctrl-C to stop watching)"
            sleep 2
        done
    fi

    _render_overview "$cid" "$env" "$proj"

    echo
    printf "➕ Add a domain to '%s's whitelist (Enter to skip): " "$env"
    read -r new_domain
    if [ -n "$new_domain" ]; then
        cmd_proxy_allow "$new_domain" "$env"
    fi
    exit 0
}

# ---------------------------------------------------------------------------
# `proxy allow <domain>` — add a domain to the whitelist (common/proxy/
# whitelist.d/00-common.txt by default, or a specific <env>-toolbelt.txt
# with -e) and restart every currently-running proxy container so the
# change applies immediately — every stack's proxy loads the whole
# whitelist.d/ directory, so this isn't scoped to one stack.
# ---------------------------------------------------------------------------
cmd_proxy_allow() {
    domain="$1"; env="$2"
    whitelist_dir="$SCRIPT_DIR/common/proxy/whitelist.d"

    if [ -n "$env" ]; then
        target_file="$whitelist_dir/${env}.txt"
        [ -f "$target_file" ] || die "No whitelist file for '$env' — expected $target_file (name matches the toolbelt directory, e.g. java-toolbelt)"
    else
        target_file="$whitelist_dir/00-common.txt"
    fi

    if grep -qxF "$domain" "$whitelist_dir"/*.txt 2>/dev/null; then
        echo "ℹ️  '$domain' is already whitelisted (in $(grep -lxF "$domain" "$whitelist_dir"/*.txt | xargs -n1 basename | tr '\n' ' '))."
    else
        printf '%s\n' "$domain" >> "$target_file"
        echo "✅ Added '$domain' to $(basename "$target_file")."
    fi

    # The `proxy` service carries no `devcontainer.env` label of its own
    # (only `dev` does), so filter on its compose service name — then
    # double-check each match's config-files label actually includes our
    # proxy.docker-compose.yml, so an unrelated project's own "proxy"
    # service (if one somehow exists on the host) is never touched.
    running_proxies=""
    for cid in $(docker ps -q --filter "label=com.docker.compose.service=proxy" 2>/dev/null || true); do
        case "$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || true)" in
            */common/proxy.docker-compose.yml*) running_proxies="$running_proxies $cid" ;;
        esac
    done
    if [ -z "$running_proxies" ]; then
        echo "ℹ️  No running proxy containers right now — the new domain applies the next time a stack starts."
        exit 0
    fi

    echo "🔁 Restarting running proxy container(s) so the change takes effect ..."
    for cid in $running_proxies; do
        env_label="$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null | xargs -I{} basename {} || echo "?")"
        if docker restart "$cid" >/dev/null 2>&1; then
            echo "   ✅ $env_label"
        else
            echo "   ⚠️  failed to restart $env_label" >&2
        fi
    done
    exit 0
}

# ---------------------------------------------------------------------------
# `proxy` dispatcher — parses its own sub-action + flags and always exits
# itself, same as the other early-dispatch subcommands.
# ---------------------------------------------------------------------------
cmd_proxy() {
    action="${1:-}"
    [ -n "$action" ] && shift

    case "$action" in
        start|stop|status|clear-log|overview)
            vol="$INVOCATION_DIR"
            follow=0
            while [ $# -gt 0 ]; do
                case "$1" in
                    -v|--volume)
                        [ $# -ge 2 ] || die "--volume requires a value"
                        vol="$2"; shift 2 ;;
                    -f|--follow)
                        [ "$action" = "overview" ] || die "-f/--follow is only valid with 'proxy overview'"
                        follow=1; shift ;;
                    *) die "Unknown argument: $1" ;;
                esac
            done
            _vol_in="$vol"
            vol="$(cd "$vol" 2>/dev/null && pwd)" || die "Volume directory not found: $_vol_in"
            case "$action" in
                start)     cmd_proxy_start "$vol" ;;
                stop)      cmd_proxy_stop "$vol" ;;
                status)    cmd_proxy_status "$vol" ;;
                clear-log) cmd_proxy_clear_log "$vol" ;;
                overview)  cmd_proxy_overview "$vol" "$follow" ;;
            esac
            ;;
        allow)
            domain="${1:-}"
            [ -n "$domain" ] || die "Usage: run.sh proxy allow <domain> [-e <env-toolbelt>]"
            shift
            env=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    -e|--env)
                        [ $# -ge 2 ] || die "--env requires a value"
                        env="$2"; shift 2 ;;
                    *) die "Unknown argument: $1" ;;
                esac
            done
            cmd_proxy_allow "$domain" "$env"
            ;;
        "")
            die "Usage: run.sh proxy <start|stop|status|clear-log|overview|allow> ..."
            ;;
        *)
            die "Unknown 'proxy' action: $action (expected start, stop, status, clear-log, overview, or allow)"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# `proxy` has its own sub-action + flags (start|stop|status|clear-log|
# allow), so it's dispatched here, before the generic one-level flag loop
# below, and always exits itself.
#
# The `dev()` shell function setup.sh installs always runs
# `run.sh -v "$(pwd)" "$@"` — i.e. a leading `-v <path>` before whatever the
# user actually typed, so `dev proxy status` arrives here as
# `-v <path> proxy status`, not `proxy status`. Extract that one leading
# -v/--volume first (tested: without this, `dev proxy ...` fell through to
# the generic loop and died on "Unknown argument: proxy"); if it turns out
# this isn't a `proxy` call after all, put it back so the generic loop below
# still sees it exactly as before.
# ---------------------------------------------------------------------------
_pre_volume=""
case "${1:-}" in
    -v|--volume)
        [ $# -ge 2 ] || die "--volume requires a value"
        _pre_volume="$2"
        shift 2
        ;;
esac

if [ "${1:-}" = "proxy" ]; then
    shift
    [ -n "$_pre_volume" ] && INVOCATION_DIR="$_pre_volume"
    cmd_proxy "$@"
    exit 0
fi

if [ -n "$_pre_volume" ]; then
    set -- -v "$_pre_volume" "$@"
fi

# ---------------------------------------------------------------------------
# Arguments  (-v defaults to the directory run.sh was called from)
# ---------------------------------------------------------------------------
STOP=0
BUILD_BASE=0
STOP_ALL=0
LIST=0
LOGS=0
FOLLOW=0
VOLUME="$INVOCATION_DIR"
REBUILD=0
DEBUG=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) cmd_help ;;
        stop)         STOP=1;    shift ;;
        list)         LIST=1;    shift ;;
        logs)         LOGS=1;    shift ;;
        build-base)   BUILD_BASE=1; shift ;;
        --all)        STOP_ALL=1; shift ;;
        -v|--volume)
            [ $# -ge 2 ] || die "--volume requires a value"
            VOLUME="$2"; shift 2 ;;
        -r|--rebuild) REBUILD=1; shift ;;
        -f|--follow)  FOLLOW=1;  shift ;;
        --debug)      DEBUG=1;   shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done
_volume_in="$VOLUME"
VOLUME="$(cd "$VOLUME" 2>/dev/null && pwd)" || die "Volume directory not found: $_volume_in"
export VOLUME

if [ "$LIST" = "1" ]; then
    cmd_list
fi

if [ "$LOGS" = "1" ]; then
    cmd_logs "$VOLUME" "$FOLLOW"
fi

if [ "$STOP_ALL" = "1" ]; then
    [ "$STOP" = "1" ] || die "--all is only valid with 'stop'"
    cmd_stop_all
fi

if [ "$STOP" = "1" ]; then
    cmd_stop "$VOLUME"
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

# ---------------------------------------------------------------------------
# GitHub token — optional; raises the unauthenticated api.github.com rate
# limit (60 req/hr per IP) used when resolving "latest" tool versions.
# Passed to builds as a BuildKit secret (never baked into image layers).
# Always exported (even empty) so the compose `secrets.environment` lookup
# doesn't fail when unset.
# ---------------------------------------------------------------------------
GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
export GITHUB_TOKEN

# ---------------------------------------------------------------------------
# Shared base image — built locally from common/Dockerfile, never pulled or
# pushed. Every <env>/Dockerfile does `FROM toolbelt-base:latest`. It is
# (re)built when it is missing, when common/ (or RUST_VERSION) changed since
# it was built — tracked by the `toolbelt.base-hash` label — or with -r.
# Only run.sh does this, so building an env by hand (`docker compose build`,
# VS Code "Reopen in Container") needs the base to exist already: run
# `sh run.sh` once first.
# ---------------------------------------------------------------------------
BASE_IMAGE="toolbelt-base:latest"   # keep in sync with ARG BASE_IMAGE in <env>/Dockerfile

ensure_base_image() {
    _hash="$(
        cd "$SCRIPT_DIR" &&
        { find common/Dockerfile common/entrypoint.sh common/lib common/scripts -type f \
            | LC_ALL=C sort | xargs sha256sum; printf 'RUST_VERSION=%s\n' "${RUST_VERSION:-stable}"; } \
        | sha256sum | cut -c1-16
    )"
    _have="$(docker image inspect "$BASE_IMAGE" --format '{{index .Config.Labels "toolbelt.base-hash"}}' 2>/dev/null || true)"

    if [ "$REBUILD" != "1" ] && [ "$_have" = "$_hash" ]; then
        return 0
    fi

    if [ -z "$_have" ]; then
        echo "🏗️  Building base image $BASE_IMAGE (first time — this takes a while) ..."
    else
        echo "🏗️  Rebuilding base image $BASE_IMAGE (common/ changed or --rebuild) ..."
    fi
    _nocache=""
    [ "$REBUILD" = "1" ] && _nocache="--no-cache"
    # shellcheck disable=SC2086
    docker build $PROGRESS $_nocache \
        -f "$SCRIPT_DIR/common/Dockerfile" \
        -t "$BASE_IMAGE" \
        --label "toolbelt.base-hash=$_hash" \
        --build-arg "RUST_VERSION=${RUST_VERSION:-stable}" \
        --build-arg HTTP_PROXY --build-arg HTTPS_PROXY --build-arg NO_PROXY \
        --build-arg http_proxy --build-arg https_proxy --build-arg no_proxy \
        --secret id=github_token,env=GITHUB_TOKEN \
        "$SCRIPT_DIR" || die "Failed to build base image $BASE_IMAGE."
}

if [ "$BUILD_BASE" = "1" ]; then
    ensure_base_image
    echo "✅ Base image $BASE_IMAGE is ready."
    exit 0
fi

# ---------------------------------------------------------------------------
# common/.zshrc is generated by setup.sh (from common/zshrc-template) and
# gitignored, so it won't exist yet on a fresh clone.
# ---------------------------------------------------------------------------
[ -f "$SCRIPT_DIR/common/.zshrc" ] || die "common/.zshrc not found — run 'sh setup.sh' first."

pick_environment() {
    echo "==================== Base environment ====================" >&2
    i=1
    for item in $COMPOSE_NAMES; do
        case "$item" in
            base-toolbelt)
                printf "  [%s] %s\n" "$i" "$item" >&2
                ;;
        esac
        i=$((i + 1))
    done

    echo "================= Toolbelt environments =================" >&2
    i=1
    for item in $COMPOSE_NAMES; do
        case "$item" in
            base-toolbelt) ;;
            *-toolbelt) printf "  [%s] %s\n" "$i" "$item" >&2 ;;
        esac
        i=$((i + 1))
    done

    printf "Select: " >&2
    read -r choice
    echo "$choice"
}

# ---------------------------------------------------------------------------
# Discover compose files (max depth 2, deduplicated). Base toolbelt sorts first.
# ---------------------------------------------------------------------------
COMPOSE_DIRS="$(
    find -L "$SCRIPT_DIR" -maxdepth 2 -type f \( -name docker-compose.yml -o -name docker-compose.yaml \) \
    | xargs -I{} dirname {} \
    | sort -u \
    | awk '
        /\/base-toolbelt$/ { print "1|" $0; next }
                            { print "2|" $0 }
      ' \
    | sort -t'|' -k1,1n -k2,2 \
    | cut -d'|' -f2-
)"

[ -n "$COMPOSE_DIRS" ] || die "No docker-compose files found."

# ---------------------------------------------------------------------------
# Select project (display basename only, keep full path for cd)
# ---------------------------------------------------------------------------
COMPOSE_NAMES="$(
    echo "$COMPOSE_DIRS" \
    | while IFS= read -r d; do basename "$d"; done
)"

choice="$(pick_environment)"

COMPOSE_DIR="$(echo "$COMPOSE_DIRS" | awk -v n="$choice" 'NR==n{print; exit}')"
[ -n "$COMPOSE_DIR" ] || die "Invalid selection: $choice"

cd "$COMPOSE_DIR" || die "Cannot enter $COMPOSE_DIR"
echo "📂 Working in: $(pwd)"
echo "📁 Mounting volume: ${VOLUME}"

# ---------------------------------------------------------------------------
# Project name: random (`dev-<8 hex>`). Nothing is encoded in it — a stack is
# identified by its labels instead: `devcontainer.env` (which toolbelt) and
# `devcontainer.workspace` (the absolute host directory), both set in the
# compose files. If a stack for this env + directory already exists we reuse
# its project name so run.sh reconnects to it; otherwise we mint a new one.
# ---------------------------------------------------------------------------
ENV_NAME="$(basename "$COMPOSE_DIR")"

_existing="$(docker ps -a -q \
    --filter "label=devcontainer.env=${ENV_NAME}" \
    --filter "label=devcontainer.workspace=${VOLUME}" 2>/dev/null | head -n 1 || true)"
COMPOSE_PROJECT_NAME=""
if [ -n "$_existing" ]; then
    COMPOSE_PROJECT_NAME="$(docker inspect "$_existing" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
fi
if [ -z "$COMPOSE_PROJECT_NAME" ]; then
    COMPOSE_PROJECT_NAME="dev-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
fi
export COMPOSE_PROJECT_NAME
# Name the container after the project (see the override file for why it is run.sh-only).
export COMPOSE_FILE="docker-compose.yml:${SCRIPT_DIR}/common/proxy.docker-compose.yml:${SCRIPT_DIR}/common/container-name.docker-compose.yml"

ensure_base_image

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
    case "$ENV_NAME" in
        java-toolbelt)
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

    _up_build="--build"
    [ "$REBUILD" = "1" ] && _up_build=""
    # shellcheck disable=SC2086
    docker compose up -d $_up_build || die "Failed to start stack."
fi

echo "ℹ️  The stack keeps running after you exit the shell — it is not stopped or deleted automatically."
echo "   Run 'sh run.sh stop' (or 'dev stop') to stop & delete it."

cleanup() {
    echo
    echo "🛑 Stopping stack …"
    docker compose down -v
}

# ---------------------------------------------------------------------------
# Select service — `proxy` (from common/proxy.docker-compose.yml) is
# infrastructure, not a shell target: exclude it so environments with a
# single `dev` service still auto-select it, same as before the proxy was
# merged in.
# ---------------------------------------------------------------------------
SERVICES="$(docker compose config --services | grep -v '^proxy$')" || die "Failed to list services."
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
# Open shell
# ---------------------------------------------------------------------------
echo "🚀 Opening zsh in service '${SERVICE}' …"
# -u ubuntu: the container's default user is root (base.docker-compose.yml's
# entrypoint needs root briefly to set up the egress iptables rules before
# dropping privileges itself) — without this, exec would land as root too.
docker compose exec -ti -u ubuntu "$SERVICE" zsh

echo
echo "👋 Shell exited — the stack is still running."
echo "   Run 'sh run.sh stop' (or 'dev stop') to stop & delete it."
