"""devtool/docker_utils.py — shared Docker CLI subprocess helpers and stack-resolution logic
used by both devtool/launcher.py and devtool/proxy.py. Every Docker interaction shells out to
the `docker` CLI (stdlib subprocess only — no SDK), matching the rest of this package.
"""
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def die(msg):
    print(f"❌ ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def docker(*args):
    return subprocess.run(["docker", *args], capture_output=True, text=True)


def docker_out(*args):
    r = docker(*args)
    return r.stdout.strip() if r.returncode == 0 else ""


def is_running(cid):
    return docker_out("inspect", cid, "--format", "{{.State.Running}}") == "true"


def proxy_cid_for_project(project):
    """The `proxy` container ID for a compose project, running or not — callers check
    is_running() themselves."""
    out = docker_out(
        "ps", "-a", "-q",
        "--filter", f"label=com.docker.compose.project={project}",
        "--filter", "label=com.docker.compose.service=proxy",
    )
    cids = out.split()
    return cids[0] if cids else None


def resolve_stack(target_dir, required=True):
    """Returns (project, env, workspace) for the stack mounted from target_dir. `workspace`
    comes from the container's own `devcontainer.workspace` label (not just echoed back from
    target_dir) so it reflects exactly what Docker recorded. Prompts (plain input()) if more
    than one stack is running from that directory. With `required=False`, returns None instead
    of dying when nothing matches — used by the Stacks tab, where "no stack yet for this
    directory" is an expected, recoverable state, not an error."""
    print(f"🔍 Looking for containers mounted from: {target_dir}", file=sys.stderr)
    candidates = docker_out("ps", "-a", "-q", "--filter", "label=devcontainer.env").split()
    if not candidates:
        if not required:
            return None
        die("No devcontainer stacks found.")

    mount_fmt = '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}'
    matches = [cid for cid in candidates if docker_out("inspect", cid, "--format", mount_fmt) == target_dir]
    if not matches:
        if not required:
            return None
        die(f"No containers mounted from {target_dir}.")

    info_fmt = (
        '{{index .Config.Labels "com.docker.compose.project"}}|'
        '{{index .Config.Labels "devcontainer.env"}}|'
        '{{index .Config.Labels "devcontainer.workspace"}}'
    )
    triples = sorted({docker_out("inspect", cid, "--format", info_fmt) for cid in matches})

    if len(triples) == 1:
        project, env, workspace = triples[0].split("|", 2)
        return project, env, workspace

    print("🐳 Multiple stacks running from this directory:", file=sys.stderr)
    for i, pe in enumerate(triples, 1):
        _, env, _ = pe.split("|", 2)
        print(f"  [{i}] {env}", file=sys.stderr)
    choice = input("Select: ")
    try:
        project, env, workspace = triples[int(choice) - 1].split("|", 2)
        return project, env, workspace
    except (ValueError, IndexError):
        die(f"Invalid selection: {choice}")
