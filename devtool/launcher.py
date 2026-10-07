"""devtool/launcher.py — `stop`/`list`/`logs`/`build-base`, stack start/stop/teardown, and the
build+start logic for toolbelts (`start_and_open_shell`) and services (`start_service`) that
the Stacks pane in devtool/proxy.py calls into. The interactive UI itself lives in
devtool/proxy.py; one-time host setup in devtool/hostsetup.py.

Stdlib only — every Docker interaction shells out to the `docker`/`docker compose` CLI via
devtool/docker_utils.py, no SDK.
"""
import hashlib
import json
import os
import signal
import subprocess
import sys

from .docker_utils import (
    ENV, ID, PROJECT, REPO_ROOT, SERVICE, STATE, WORKDIR, WORKSPACE,
    die, docker_out, is_running, proxy_cid_for_project, ps_rows, resolve_stack,
)

BASE_IMAGE = "toolbelt-base:latest"  # keep in sync with ARG BASE_IMAGE in <env>/Dockerfile
PROXY_COMPOSE = REPO_ROOT / "common" / "proxy.docker-compose.yml"
CONTAINER_NAME_COMPOSE = REPO_ROOT / "common" / "container-name.docker-compose.yml"


def pick_from_list(label, items):
    print(f"{label}:", file=sys.stderr)
    for i, item in enumerate(items, 1):
        print(f"  [{i}] {item}", file=sys.stderr)
    print("Select: ", end="", file=sys.stderr, flush=True)
    return input()


# ---------------------------------------------------------------------------
# Teardown — `docker compose down -v` per compose project (containers,
# networks and non-external volumes removed). Stacks are found by the
# `devcontainer.env` label set in each <env>/docker-compose.yml, so unrelated
# docker-compose projects on the host are never matched.
# ---------------------------------------------------------------------------
def _project_workdirs(*filters):
    return sorted({(p, w) for p, w in ps_rows(*filters, fields=[PROJECT, WORKDIR]) if p})


def _teardown(pairs):
    """Returns one result dict per torn-down project — {"project", "workdir", "ok", "output"}
    — so a caller that wants the output somewhere other than stdout (the Stacks tab's 'd'
    shows it in a modal) has it, while the `stop`/`stop --all` CLI path gets it printed."""
    results = []
    for proj, workdir in pairs:
        print(f"🛑 Stopping & deleting stack '{proj}' (in {workdir}) ...")
        # capture_output: this also runs from inside the Stacks tab's curses session ('d'),
        # where an uncaptured subprocess would print straight over the alternate screen —
        # confirmed: exactly what broke the Stacks tab's view on delete.
        if workdir and os.path.isdir(workdir):
            r = subprocess.run(["docker", "compose", "down", "-v"], cwd=workdir,
                               env={**os.environ, "COMPOSE_PROJECT_NAME": proj}, capture_output=True, text=True)
        else:
            r = subprocess.run(["docker", "compose", "-p", proj, "down", "-v"], capture_output=True, text=True)

        output = (r.stdout + r.stderr).strip()
        results.append({"project": proj, "workdir": workdir, "ok": r.returncode == 0, "output": output})
        if r.returncode != 0:
            print(f"⚠️  Failed to tear down {proj}", file=sys.stderr)
            if r.stderr:
                print(r.stderr, file=sys.stderr)
        elif output:
            print(output)
    return results


def teardown_stack(project):
    """Same teardown as `stop`/`stop --all`, for one compose project (the Stacks tab's 'd')."""
    return _teardown(_project_workdirs(f"label=com.docker.compose.project={project}"))


def cmd_stop(target):
    """`stop` — tear down every stack mounted from `target` (default: cwd)."""
    print(f"🔍 Looking for containers mounted from: {target}")
    pairs = _project_workdirs(f"label=devcontainer.workspace={target}")
    if not pairs:
        die(f"No containers mounted from {target}.")
    _teardown(pairs)


def cmd_stop_all():
    """`stop --all` — tear down every devcontainer stack and service, from any directory."""
    print("🔍 Looking for all devcontainer stacks ...")
    pairs = _project_workdirs("label=devcontainer.env")
    if not pairs:
        die("No devcontainer stacks found.")
    _teardown(pairs)


# ---------------------------------------------------------------------------
# Plain stop/start of a whole stack — every container in the compose project,
# nothing removed. `docker stop`/`start` on the containers directly rather than
# `docker compose stop/start`, which would need the exact COMPOSE_FILE/env the
# stack was created with. Backs the Stacks pane's 's' toggle.
# ---------------------------------------------------------------------------
def _stop_or_start(project, action):
    """Main container(s) are stopped before the proxy (nothing left running without its
    egress path) and started after it (common/entrypoint.sh resolves `proxy` at start and
    refuses to come up without it). Returns True on success."""
    proxies, others = [], []
    for cid, svc in ps_rows(f"label=com.docker.compose.project={project}", fields=[ID, SERVICE]):
        (proxies if svc == "proxy" else others).append(cid)
    order = (others, proxies) if action == "stop" else (proxies, others)
    results = [subprocess.run(["docker", action, *group], capture_output=True).returncode == 0 for group in order if group]
    return bool(results) and all(results)


def stop_stack(project):
    return _stop_or_start(project, "stop")


def start_stack(project):
    return _stop_or_start(project, "start")


def cmd_list():
    """`list` — every devcontainer stack/service, regardless of where it was started from."""
    rows = sorted(set(ps_rows("label=devcontainer.env", fields=[PROJECT, ENV, SERVICE, STATE, WORKSPACE])))
    if not rows:
        print("No devcontainer stacks found.")
        return
    print(f"{'PROJECT':<16} {'ENV':<24} {'SERVICE':<10} {'STATUS':<10} WORKSPACE")
    for proj, env, svc, status, src in rows:
        print(f"{proj:<16} {env:<24} {svc:<10} {status:<10} {src}")


def cmd_logs(target, follow):
    """`logs` — tail (or one-shot view) the proxy's access log for the stack mounted from
    `target`. No -t on exec: tail needs no TTY, so this also works piped/scripted."""
    project, env, _workspace = resolve_stack(target)
    proxy_cid = proxy_cid_for_project(project)
    if not proxy_cid:
        die(f"No 'proxy' container found for stack '{project}' ({env}).")
    if not is_running(proxy_cid):
        die(f"Proxy for '{env}' (project {project}) isn't running — './run.py' (Stacks tab, 'a') to start it.")

    if follow:
        print(f"📜 Tailing access log for '{env}' (project {project}) — Ctrl-C to stop ...")
    else:
        print(f"📜 Access log for '{env}' (project {project}):")
    tail = ["tail", "-n", "50"] + (["-f"] if follow else [])
    subprocess.run(["docker", "exec", "-i", proxy_cid, *tail, "/var/log/squid/access.log"])


# ---------------------------------------------------------------------------
# Environment for every docker/compose subprocess: proxy.env + GITHUB_TOKEN.
# ---------------------------------------------------------------------------
def _load_proxy_env():
    env = {}
    proxy_env_file = REPO_ROOT / "proxy.env"
    if proxy_env_file.exists():
        for line in proxy_env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                env[key.strip()] = value.strip()
    return env


def build_env():
    """The current process environment, plus proxy.env's HTTP_PROXY/HTTPS_PROXY/NO_PROXY
    (both cases) if present, plus GITHUB_TOKEN (falling back to GH_TOKEN, always present even
    if empty so compose's `secrets.environment` lookup never fails on an unset var). Raises the
    unauthenticated api.github.com rate limit (60 req/hr per IP) used when resolving "latest"
    tool versions; passed to builds as a BuildKit secret, never baked into image layers."""
    env = {**os.environ, **_load_proxy_env()}
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
def _rust_version():
    return os.environ.get("RUST_VERSION", "stable")


def _hash_base_inputs():
    paths = [REPO_ROOT / rel for rel in ("common/Dockerfile", "common/entrypoint.sh") if (REPO_ROOT / rel).is_file()]
    for rel in ("common/lib", "common/scripts"):
        d = REPO_ROOT / rel
        if d.is_dir():
            paths.extend(f for f in d.rglob("*") if f.is_file())
    paths.sort(key=lambda p: str(p.relative_to(REPO_ROOT)))

    lines = [f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(REPO_ROOT)}\n" for p in paths]
    lines.append(f"RUST_VERSION={_rust_version()}\n")
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
        "--build-arg", f"RUST_VERSION={_rust_version()}",
    ]
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"):
        cmd += ["--build-arg", name]
    cmd += ["--secret", "id=github_token,env=GITHUB_TOKEN", str(REPO_ROOT)]

    if subprocess.run(cmd, env=env).returncode != 0:
        die(f"Failed to build base image {BASE_IMAGE}.")


# ---------------------------------------------------------------------------
# Discovery: every immediate subdirectory of the repo root with a
# docker-compose.yml/.yaml. `*-service` folders are services (see
# discover_service_dirs), everything else a toolbelt; base-toolbelt sorts first.
# ---------------------------------------------------------------------------
SERVICE_SUFFIX = "-service"


def _compose_dirs():
    return sorted(
        child for child in REPO_ROOT.iterdir()
        if child.is_dir() and ((child / "docker-compose.yml").is_file() or (child / "docker-compose.yaml").is_file())
    )


def discover_env_dirs():
    dirs = [d for d in _compose_dirs() if not d.name.endswith(SERVICE_SUFFIX)]
    return sorted(dirs, key=lambda d: d.name != "base-toolbelt")


def discover_service_dirs():
    """Top-level `*-service` folders (e.g. open-webui-service/) — top-level, not nested under
    a `services/` folder, because common/proxy.docker-compose.yml's relative paths resolve
    against the FIRST compose file's directory and assume it is one level below the repo root
    (see AGENTS.md). A service is a long-running app rather than a devcontainer: no
    /workspace, no shell, one instance host-wide."""
    return [d for d in _compose_dirs() if d.name.endswith(SERVICE_SUFFIX)]


def service_project_name(compose_dir):
    """Fixed project name for a service (`open-webui-service` -> `open-webui`) — one instance
    host-wide, so there is nothing to look up or randomize like a toolbelt's `dev-<hex>`."""
    return compose_dir.name[: -len(SERVICE_SUFFIX)]


def service_url(cid, container_port=8080):
    """`http://localhost:<host port>` for a running service container, or None."""
    for line in docker_out("port", cid, f"{container_port}/tcp").splitlines():
        port = line.rpartition(":")[2]
        if port.isdigit():
            return f"http://localhost:{port}"
    return None


# ---------------------------------------------------------------------------
# Building/starting a stack.
# ---------------------------------------------------------------------------
def _compose_runner(compose_dir, project, compose_files, **extra_env):
    """(env, compose) — the env every call for this stack needs, and a `docker compose`
    runner bound to it (cwd = the env folder, so relative paths resolve as AGENTS.md
    describes)."""
    env = build_env()
    env.update(extra_env)
    env["COMPOSE_PROJECT_NAME"] = project
    env["COMPOSE_FILE"] = ":".join(["docker-compose.yml", *map(str, compose_files)])

    def compose(*args, **kw):
        return subprocess.run(["docker", "compose", *args], cwd=compose_dir, env=env, **kw)

    return env, compose


def _rebuild_no_cache(compose, debug):
    """-r: tear down first so --no-cache is never skipped. Returns True on success."""
    print("🔨 Rebuilding from scratch (no cache) ...")
    compose("down")
    progress = ["--progress=plain"] if debug else []
    return compose("build", "--no-cache", *progress).returncode == 0


def start_service(compose_dir, rebuild, debug):
    """Builds (if needed)/starts a `*-service` stack and returns the main container's id (or
    None on failure). No shell, no workspace: the project name is fixed
    (service_project_name), and every external named volume the compose file declares is
    created first (`docker volume create` is idempotent) — services keep their data in
    external volumes precisely so `down -v` (run.py stop, the TUI's 'd') can't delete it."""
    project = service_project_name(compose_dir)
    print(f"📂 Working in: {compose_dir}")
    env, compose = _compose_runner(compose_dir, project, [PROXY_COMPOSE])
    ensure_base_image(rebuild, debug, env)

    cfg = compose("config", "--format", "json", capture_output=True, text=True)
    if cfg.returncode != 0:
        print(cfg.stderr, file=sys.stderr)
        return None
    for vol in json.loads(cfg.stdout).get("volumes", {}).values():
        if vol.get("external") and vol.get("name"):
            subprocess.run(["docker", "volume", "create", vol["name"]], capture_output=True)

    if rebuild and not _rebuild_no_cache(compose, debug):
        print("⚠️  Failed to build service.", file=sys.stderr)
        return None
    if compose("up", "-d", *([] if rebuild else ["--build"])).returncode != 0:
        print("⚠️  Failed to start service.", file=sys.stderr)
        return None

    rows = ps_rows(f"label=com.docker.compose.project={project}", "label=devcontainer.kind=service", fields=[ID], all_=False)
    return rows[0][0] if rows else None


def start_and_open_shell(compose_dir, volume, rebuild, debug):
    """Builds (if needed)/starts the stack for `compose_dir` mounted from `volume`, then opens
    a shell in it — or reconnects straight to a shell if it's already running. Called by the
    Stacks tab's 'o'/'n' after tearing curses down (a real interactive zsh session can't run
    inside the curses alternate screen)."""
    if not (REPO_ROOT / "common" / ".zshrc").is_file():
        die("common/.zshrc not found — run './run.py setup' first.")

    print(f"📂 Working in: {compose_dir}")
    print(f"📁 Mounting volume: {volume}")

    # Project name: random (`dev-<8 hex>`), encodes nothing — a stack is identified by its
    # `devcontainer.env` + `devcontainer.workspace` labels. Reuse the project of an existing
    # stack for this env + directory to reconnect; otherwise mint a new one.
    env_name = compose_dir.name
    existing = ps_rows(f"label=devcontainer.env={env_name}", f"label=devcontainer.workspace={volume}", fields=[PROJECT])
    project = (existing[0][0] if existing else "") or "dev-" + os.urandom(4).hex()

    # container-name override: names the container after the project (launcher-only).
    env, compose = _compose_runner(compose_dir, project, [PROXY_COMPOSE, CONTAINER_NAME_COMPOSE], VOLUME=volume)
    ensure_base_image(rebuild, debug, env)

    if rebuild and not _rebuild_no_cache(compose, debug):
        die("Failed to build stack.")

    if compose("ps", "--status", "running", "-q", capture_output=True, text=True).stdout.strip():
        print("♻️  Stack already running — connecting to the existing container.")
    else:
        if env_name == "java-toolbelt":
            print("☕ Java major version:", file=sys.stderr)
            print("  [1] 8\n  [2] 11\n  [3] 17\n  [4] 21\n  [5] 25", file=sys.stderr)
            print("Select [ENTER for latest LTS]: ", end="", flush=True)
            jv = {"1": "8", "2": "11", "3": "17", "4": "21", "5": "25"}.get(input())
            if jv:
                env["JAVA_VERSION"] = jv
        if compose("up", "-d", *([] if rebuild else ["--build"])).returncode != 0:
            die("Failed to start stack.")

    print("ℹ️  The stack keeps running after you exit the shell — it is not stopped or deleted automatically.")
    print("   Run './run.py stop' (or 'dev stop') to stop & delete it.")

    # `proxy` (from common/proxy.docker-compose.yml) is infrastructure, not a shell target —
    # excluded so environments with a single `dev` service still auto-select it.
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
                print("\n🛑 Stopping stack …")
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

    # -u ubuntu: the container's default user is root (the entrypoint needs it briefly for the
    # egress iptables rules before dropping privileges itself) — exec would land as root too.
    # exec, not subprocess.run: run.py replaces itself with `docker compose exec`, so nothing of
    # it lingers (not even an idle parent) while the user works in the container.
    print(f"🚀 Opening zsh in service '{service}' …", flush=True)
    os.chdir(compose_dir)
    os.execvpe("docker", ["docker", "compose", "exec", "-ti", "-u", "ubuntu", service, "zsh"], env)
