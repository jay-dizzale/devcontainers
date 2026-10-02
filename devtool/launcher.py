"""devtool/launcher.py — `stop`/`list`/`logs`/`build-base`, plus the build+start+open-shell
logic (`start_and_open_shell`) that both the bare `run.py` picker fallback (non-tty) and the
Stacks pane's 'o' action in devtool/proxy.py call into. Direct Python port of the previous
POSIX-sh `run.sh`'s own logic (everything except `proxy`'s own UI, which lives in
devtool/proxy.py — the default interactive entry point is now that two-pane app, with the
Stacks pane doubling as the environment picker — and one-time host setup, in
devtool/hostsetup.py).

Stdlib only — every Docker interaction shells out to the `docker`/`docker compose` CLI via
devtool/docker_utils.py, no SDK.
"""
import hashlib
import os
import signal
import subprocess
import sys
from pathlib import Path

from .docker_utils import REPO_ROOT, die, docker_out, is_running, proxy_cid_for_project, resolve_stack

BASE_IMAGE = "toolbelt-base:latest"  # keep in sync with ARG BASE_IMAGE in <env>/Dockerfile


def pick_from_list(label, items):
    print(f"{label}:", file=sys.stderr)
    for i, item in enumerate(items, 1):
        print(f"  [{i}] {item}", file=sys.stderr)
    print("Select: ", end="", file=sys.stderr, flush=True)
    return input()


# ---------------------------------------------------------------------------
# Every container that carries the `devcontainer.env` label set in each
# <env>/docker-compose.yml, from any directory. Unrelated docker-compose
# projects on the host are never matched.
# ---------------------------------------------------------------------------
def _all_workspace_containers():
    return docker_out("ps", "-a", "-q", "--filter", "label=devcontainer.env").split()


def _workspace_mount_source(cid):
    fmt = '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}'
    return docker_out("inspect", cid, "--format", fmt)


# ---------------------------------------------------------------------------
# Given a list of container IDs, group them by compose project and tear each
# project down (containers, networks and anonymous volumes removed).
# ---------------------------------------------------------------------------
def _teardown_containers(cids):
    """Returns one result dict per torn-down project — {"project", "workdir", "ok", "output"}
    — so a caller that wants the teardown output somewhere other than stdout (the Stacks
    tab's 'd' action shows it in a modal — see devtool/proxy.py's _show_output_modal) has it,
    while the plain `stop`/`stop --all` CLI path still gets it printed below as before."""
    fmt = (
        '{{index .Config.Labels "com.docker.compose.project"}}|'
        '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'
    )
    pairs = sorted({docker_out("inspect", cid, "--format", fmt) for cid in cids})

    results = []
    for pair in pairs:
        proj, _, workdir = pair.partition("|")
        if not proj:
            continue
        print(f"🛑 Stopping & deleting stack '{proj}' (in {workdir}) ...")
        # capture_output: this can run from inside the Stacks tab's curses session (the 'd'
        # action, via teardown_stack below) without tearing curses down first, unlike 'o'/'n'.
        # An uncaptured subprocess inherits the real terminal fds and `docker compose down -v`
        # prints container/network/volume removal lines straight to it, corrupting the
        # alternate-screen display underneath curses — confirmed: this is exactly what broke
        # the Stacks tab's view on delete.
        if workdir and Path(workdir).is_dir():
            r = subprocess.run(
                ["docker", "compose", "down", "-v"],
                cwd=workdir,
                env={**os.environ, "COMPOSE_PROJECT_NAME": proj},
                capture_output=True, text=True,
            )
        else:
            r = subprocess.run(["docker", "compose", "-p", proj, "down", "-v"], capture_output=True, text=True)

        output = (r.stdout + r.stderr).strip()
        results.append({"project": proj, "workdir": workdir, "ok": r.returncode == 0, "output": output})

        if r.returncode != 0:
            print(f"⚠️  Failed to tear down {proj}", file=sys.stderr)
            if r.stderr:
                print(r.stderr, file=sys.stderr)
        elif output:
            # Batched rather than streamed live (capture_output above requires that), but
            # still surfaced for the plain `stop`/`stop --all` CLI path — only lost when the
            # caller wraps this in _quiet_stdout() (the Stacks tab's 'd' action), same as the
            # "🛑 Stopping ..." line above.
            print(output)
    return results


def teardown_stack(cid):
    """Public one-container entry point into _teardown_containers — same teardown as `stop`/
    `stop --all` (containers, networks, anonymous volumes removed), given any single
    container ID belonging to the stack's compose project (any service's container carries
    the same `com.docker.compose.project*` labels, so the Stacks tab's 'd' action in
    devtool/proxy.py can pass its `proxy` container without needing the `dev` container's id
    too). Returns _teardown_containers' result list (one entry here, since a single cid
    belongs to exactly one project) for the caller to show however it likes."""
    return _teardown_containers([cid])


# ---------------------------------------------------------------------------
# `stop` subcommand — find every compose project whose /workspace mount
# points at the given directory (default: current directory) and tear it
# down.
# ---------------------------------------------------------------------------
def cmd_stop(target):
    print(f"🔍 Looking for containers mounted from: {target}")
    candidates = _all_workspace_containers()
    if not candidates:
        die("No devcontainer stacks found.")

    matches = [cid for cid in candidates if _workspace_mount_source(cid) == target]
    if not matches:
        die(f"No containers mounted from {target}.")

    _teardown_containers(matches)


# ---------------------------------------------------------------------------
# `stop --all` subcommand — tear down every devcontainer stack (scoped to
# /workspace mounts so it never touches unrelated docker-compose projects
# on the host).
# ---------------------------------------------------------------------------
def cmd_stop_all():
    print("🔍 Looking for all devcontainer stacks ...")
    matches = _all_workspace_containers()
    if not matches:
        die("No devcontainer stacks found.")
    _teardown_containers(matches)


# ---------------------------------------------------------------------------
# `list` subcommand — show every devcontainer stack (project, service,
# status, mounted workspace) regardless of which directory it was started
# from.
# ---------------------------------------------------------------------------
def cmd_list():
    matches = _all_workspace_containers()
    if not matches:
        print("No devcontainer stacks found.")
        return

    print(f"{'PROJECT':<16} {'ENV':<24} {'SERVICE':<10} {'STATUS':<10} WORKSPACE")
    fmt = (
        '{{index .Config.Labels "com.docker.compose.project"}}|'
        '{{index .Config.Labels "devcontainer.env"}}|'
        '{{index .Config.Labels "com.docker.compose.service"}}|'
        '{{.State.Status}}|'
        '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}'
    )
    rows = set()
    for cid in matches:
        info = docker_out("inspect", cid, "--format", fmt)
        if info:
            rows.add(info)

    for info in sorted(rows):
        proj, env, svc, status, src = info.split("|", 4)
        print(f"{proj:<16} {env:<24} {svc:<10} {status:<10} {src}")


# ---------------------------------------------------------------------------
# `logs` subcommand — tail (or one-shot view) the whitelist proxy's access
# log for the stack mounted from the given directory (default: cwd).
# ---------------------------------------------------------------------------
def cmd_logs(target, follow):
    project, env, _workspace = resolve_stack(target)

    proxy_cid = proxy_cid_for_project(project)
    if not proxy_cid:
        die(f"No 'proxy' container found for stack '{project}' ({env}).")
    if not is_running(proxy_cid):
        die(f"Proxy for '{env}' (project {project}) isn't running — './run.py' (Stacks tab, 'a') to start it.")

    # No -t: tail doesn't need a TTY, and this way `logs` also works when
    # run.py's own stdin/stdout aren't a terminal (e.g. piped/scripted).
    if follow:
        print(f"📜 Tailing access log for '{env}' (project {project}) — Ctrl-C to stop ...")
        subprocess.run(["docker", "exec", "-i", proxy_cid, "tail", "-n", "50", "-f", "/var/log/squid/access.log"])
    else:
        print(f"📜 Access log for '{env}' (project {project}):")
        subprocess.run(["docker", "exec", "-i", proxy_cid, "tail", "-n", "50", "/var/log/squid/access.log"])


# ---------------------------------------------------------------------------
# proxy.env / GITHUB_TOKEN — folded into the environment handed to every
# docker/docker-compose subprocess call from here on, rather than one shell
# `export` (Python has no process-wide equivalent; subprocess.run's own
# `env=` is the only place it applies).
# ---------------------------------------------------------------------------
def _load_proxy_env():
    env = {}
    proxy_env_file = REPO_ROOT / "proxy.env"
    if proxy_env_file.exists():
        for line in proxy_env_file.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip()
    return env


def build_env():
    """The environment every docker/docker-compose subprocess call needs: the current
    process environment, plus proxy.env's HTTP_PROXY/HTTPS_PROXY/NO_PROXY (both cases) if
    present, plus GITHUB_TOKEN (falling back to GH_TOKEN, always present even if empty so
    compose's `secrets.environment` lookup never fails on an unset var). Raises the
    unauthenticated api.github.com rate limit (60 req/hr per IP) used when resolving "latest"
    tool versions; passed to builds as a BuildKit secret, never baked into image layers."""
    env = os.environ.copy()
    env.update(_load_proxy_env())
    env["GITHUB_TOKEN"] = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    return env


# ---------------------------------------------------------------------------
# Shared base image — built locally from common/Dockerfile, never pulled or
# pushed. Every <env>/Dockerfile does `FROM toolbelt-base:latest`. It is
# (re)built when it is missing, when common/ (or RUST_VERSION) changed since
# it was built — tracked by the `toolbelt.base-hash` label — or with -r.
# Only this launcher does this, so building an env by hand
# (`docker compose build`, VS Code "Reopen in Container") needs the base to
# exist already: run `./run.py` once first.
# ---------------------------------------------------------------------------
def _hash_base_inputs():
    paths = []
    for rel in ("common/Dockerfile", "common/entrypoint.sh"):
        p = REPO_ROOT / rel
        if p.is_file():
            paths.append(p)
    for rel in ("common/lib", "common/scripts"):
        d = REPO_ROOT / rel
        if d.is_dir():
            paths.extend(f for f in d.rglob("*") if f.is_file())
    paths.sort(key=lambda p: str(p.relative_to(REPO_ROOT)))

    lines = []
    for p in paths:
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        lines.append(f"{digest}  {p.relative_to(REPO_ROOT)}\n")
    lines.append(f"RUST_VERSION={os.environ.get('RUST_VERSION', 'stable')}\n")

    return hashlib.sha256("".join(lines).encode()).hexdigest()[:16]


def ensure_base_image(rebuild, debug, env):
    hash_ = _hash_base_inputs()
    have = docker_out("image", "inspect", BASE_IMAGE, "--format", '{{index .Config.Labels "toolbelt.base-hash"}}')

    if not rebuild and have == hash_:
        return

    if not have:
        print(f"🏗️  Building base image {BASE_IMAGE} (first time — this takes a while) ...")
    else:
        print(f"🏗️  Rebuilding base image {BASE_IMAGE} (common/ changed or --rebuild) ...")

    cmd = ["docker", "build"]
    if debug:
        cmd.append("--progress=plain")
    if rebuild:
        cmd.append("--no-cache")
    cmd += [
        "-f", str(REPO_ROOT / "common" / "Dockerfile"),
        "-t", BASE_IMAGE,
        "--label", f"toolbelt.base-hash={hash_}",
        "--build-arg", f"RUST_VERSION={os.environ.get('RUST_VERSION', 'stable')}",
    ]
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"):
        cmd += ["--build-arg", name]
    cmd += ["--secret", "id=github_token,env=GITHUB_TOKEN", str(REPO_ROOT)]

    if subprocess.run(cmd, env=env).returncode != 0:
        die(f"Failed to build base image {BASE_IMAGE}.")


# ---------------------------------------------------------------------------
# Discover toolbelt directories: every immediate subdirectory of the repo
# root containing docker-compose.yml/.yaml. base-toolbelt always sorts
# first, everything else alphabetically after. Public — devtool/proxy.py's
# Stacks tab also uses this to list toolbelts that haven't been started yet.
# ---------------------------------------------------------------------------
def discover_env_dirs():
    dirs = []
    for child in REPO_ROOT.iterdir():
        if not child.is_dir():
            continue
        if (child / "docker-compose.yml").is_file() or (child / "docker-compose.yaml").is_file():
            dirs.append(child)
    dirs.sort(key=lambda d: (0 if d.name == "base-toolbelt" else 1, d.name))
    return dirs


def _random_project_name():
    return "dev-" + os.urandom(4).hex()


def start_and_open_shell(compose_dir, volume, rebuild, debug):
    """Builds (if needed)/starts the stack for `compose_dir` mounted from `volume`, then opens
    a shell in it — or reconnects straight to a shell if it's already running. Shared by the
    non-interactive picker above and devtool/proxy.py's Stacks tab 'o' action, which calls this
    after tearing curses down (a real interactive zsh session can't run inside the curses
    alternate screen)."""
    zshrc = REPO_ROOT / "common" / ".zshrc"
    if not zshrc.is_file():
        die("common/.zshrc not found — run './run.py setup' first.")

    print(f"📂 Working in: {compose_dir}")
    print(f"📁 Mounting volume: {volume}")

    # ---------------------------------------------------------------------
    # Project name: random (`dev-<8 hex>`). Nothing is encoded in it — a
    # stack is identified by its labels instead: `devcontainer.env` (which
    # toolbelt) and `devcontainer.workspace` (the absolute host directory),
    # both set in the compose files. If a stack for this env + directory
    # already exists we reuse its project name to reconnect; otherwise mint
    # a new one.
    # ---------------------------------------------------------------------
    env_name = compose_dir.name
    existing = docker_out(
        "ps", "-a", "-q",
        "--filter", f"label=devcontainer.env={env_name}",
        "--filter", f"label=devcontainer.workspace={volume}",
    ).split()

    project = ""
    if existing:
        project = docker_out("inspect", existing[0], "--format", '{{index .Config.Labels "com.docker.compose.project"}}')
    if not project:
        project = _random_project_name()

    env = build_env()
    env["VOLUME"] = volume
    env["COMPOSE_PROJECT_NAME"] = project
    # Name the container after the project (see the override file for why this is launcher-only).
    env["COMPOSE_FILE"] = ":".join([
        "docker-compose.yml",
        str(REPO_ROOT / "common" / "proxy.docker-compose.yml"),
        str(REPO_ROOT / "common" / "container-name.docker-compose.yml"),
    ])

    def compose(*args, **kw):
        return subprocess.run(["docker", "compose", *args], cwd=compose_dir, env=env, **kw)

    ensure_base_image(rebuild, debug, env)

    # ---------------------------------------------------------------------
    # Force rebuild — tears down first so --no-cache is never skipped.
    # ---------------------------------------------------------------------
    if rebuild:
        print("🔨 Rebuilding from scratch (no cache) ...")
        compose("down")
        progress = ["--progress=plain"] if debug else []
        if compose("build", "--no-cache", *progress).returncode != 0:
            die("Failed to build stack.")

    # ---------------------------------------------------------------------
    # Start stack — reuse the existing container if it's already running.
    # ---------------------------------------------------------------------
    running = compose("ps", "--status", "running", "-q", capture_output=True, text=True).stdout.strip()
    if running:
        print("♻️  Stack already running — connecting to the existing container.")
    else:
        if env_name == "java-toolbelt":
            print("☕ Java major version:", file=sys.stderr)
            print("  [1] 8\n  [2] 11\n  [3] 17\n  [4] 21\n  [5] 25", file=sys.stderr)
            print("Select [ENTER for latest LTS]: ", end="", flush=True)
            jv = input()
            versions = {"1": "8", "2": "11", "3": "17", "4": "21", "5": "25"}
            if jv in versions:
                env["JAVA_VERSION"] = versions[jv]

        up_args = [] if rebuild else ["--build"]
        if compose("up", "-d", *up_args).returncode != 0:
            die("Failed to start stack.")

    print("ℹ️  The stack keeps running after you exit the shell — it is not stopped or deleted automatically.")
    print("   Run './run.py stop' (or 'dev stop') to stop & delete it.")

    # ---------------------------------------------------------------------
    # Select service — `proxy` (from common/proxy.docker-compose.yml) is
    # infrastructure, not a shell target: exclude it so environments with a
    # single `dev` service still auto-select it, same as before the proxy
    # was merged in.
    # ---------------------------------------------------------------------
    services_result = compose("config", "--services", capture_output=True, text=True)
    if services_result.returncode != 0:
        die("Failed to list services.")
    services = [s for s in services_result.stdout.splitlines() if s != "proxy"]
    if not services:
        die("No services defined in compose file.")

    if len(services) == 1:
        service = services[0]
        print(f"🐳 Auto-selected service: {service}")
    else:
        svc_choice = pick_from_list("🐳 Available services (enter 's' to skip shell)", services)
        if svc_choice == "s":
            print("⏭️  Skipping shell. Stack is running — press Ctrl-C to stop.")

            def _cleanup(_signum, _frame):
                print()
                print("🛑 Stopping stack …")
                compose("down", "-v")
                sys.exit(0)

            signal.signal(signal.SIGINT, _cleanup)
            signal.signal(signal.SIGTERM, _cleanup)
            signal.pause()
            return 0
        try:
            service = services[int(svc_choice) - 1]
        except (ValueError, IndexError):
            die(f"Invalid selection: {svc_choice}")

    # ---------------------------------------------------------------------
    # Open shell. -u ubuntu: the container's default user is root
    # (base.docker-compose.yml's entrypoint needs root briefly to set up the
    # egress iptables rules before dropping privileges itself) — without
    # this, exec would land as root too.
    # ---------------------------------------------------------------------
    print(f"🚀 Opening zsh in service '{service}' …")
    result = compose("exec", "-ti", "-u", "ubuntu", service, "zsh")
    if result.returncode != 0:
        return result.returncode

    print()
    print("👋 Shell exited — the stack is still running.")
    print("   Run './run.py stop' (or 'dev stop') to stop & delete it.")
    return 0
