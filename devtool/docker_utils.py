"""devtool/docker_utils.py — shared Docker CLI subprocess helpers and stack-resolution logic
used by both devtool/launcher.py and devtool/proxy.py. Every Docker interaction shells out to
the `docker` CLI (stdlib subprocess only — no SDK), matching the rest of this package.
"""
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# `docker ps --format` fields read straight off the ps table — no per-container `inspect`.
PROJECT = '{{.Label "com.docker.compose.project"}}'
SERVICE = '{{.Label "com.docker.compose.service"}}'
WORKDIR = '{{.Label "com.docker.compose.project.working_dir"}}'
CONFIG_FILES = '{{.Label "com.docker.compose.project.config_files"}}'
ENV = '{{.Label "devcontainer.env"}}'
WORKSPACE = '{{.Label "devcontainer.workspace"}}'
KIND = '{{.Label "devcontainer.kind"}}'
ID, STATE, PORTS = "{{.ID}}", "{{.State}}", "{{.Ports}}"


def die(msg):
    print(f"❌ ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def docker(*args, timeout=None):
    return subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout)


def docker_out(*args):
    r = docker(*args)
    return r.stdout.strip() if r.returncode == 0 else ""


def ps_rows(*filters, fields, all_=True):
    """`docker ps [-a] --filter ... --format <fields joined by |>`, one tuple per container.
    One CLI call however many containers match."""
    args = ["ps", "-a"] if all_ else ["ps"]
    for f in filters:
        args += ["--filter", f]
    out = docker_out(*args, "--format", "|".join(fields))
    n = len(fields) - 1
    return [tuple(line.split("|", n)) for line in out.splitlines() if line.count("|") >= n]


def docker_engine_version():
    """The Docker engine's server version if the daemon answers, else None (daemon stopped,
    Docker Desktop not started, or no `docker` CLI at all). Bounded by a timeout so a hung
    daemon socket can't freeze the TUI, which polls this on every refresh."""
    try:
        r = docker("version", "--format", "{{.Server.Version}}", timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return (r.stdout.strip() or None) if r.returncode == 0 else None


def is_running(cid):
    return docker_out("inspect", cid, "--format", "{{.State.Running}}") == "true"


def proxy_cid_for_project(project):
    """The `proxy` container ID for a compose project, running or not — callers check
    is_running() themselves."""
    rows = ps_rows(f"label=com.docker.compose.project={project}", "label=com.docker.compose.service=proxy", fields=[ID])
    return rows[0][0] if rows else None


def resolve_stack(target_dir, required=True):
    """Returns (project, env, workspace) for the stack mounted from target_dir, found by its
    `devcontainer.workspace` label (set to the same absolute path as the /workspace mount).
    Prompts (plain input()) if more than one stack is running from that directory. With
    `required=False`, returns None instead of dying when nothing matches — used by the Stacks
    tab, where "no stack yet for this directory" is an expected, recoverable state."""
    print(f"🔍 Looking for containers mounted from: {target_dir}", file=sys.stderr)
    triples = sorted(set(ps_rows(f"label=devcontainer.workspace={target_dir}", fields=[PROJECT, ENV, WORKSPACE])))
    if not triples:
        if not required:
            return None
        die(f"No containers mounted from {target_dir}.")
    if len(triples) == 1:
        return triples[0]

    print("🐳 Multiple stacks running from this directory:", file=sys.stderr)
    for i, (_, env, _) in enumerate(triples, 1):
        print(f"  [{i}] {env}", file=sys.stderr)
    choice = input("Select: ")
    try:
        return triples[int(choice) - 1]
    except (ValueError, IndexError):
        die(f"Invalid selection: {choice}")
