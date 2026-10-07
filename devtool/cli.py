"""devtool/cli.py — top-level argument dispatch for `run.py`. Deliberately NOT argparse: flags
can appear in any order/repetition, and `setup` must be either the very first token or
immediately follow a single leading `-v`/`--volume <path>` — the `dev()` shell function set up
by `run.py setup` always prepends one (`dev() { "<repo>/run.py" -v "$(pwd)" "$@"; }`), so
`dev setup` arrives here as `-v <cwd> setup`. argparse's subparsers don't model that shape.

No subcommand: bare `run.py` launches the two-pane Stacks / proxy-settings app
(devtool/proxy.py).
"""
import os
from pathlib import Path

from . import hostsetup, launcher, proxy
from .docker_utils import die

HELP_TEXT = """\
run.py — Interactive launcher for docker-compose devcontainer stacks and services.

Usage:
  ./run.py [-v /path/to/mount] [-r] [--debug] [-f]
      Opens a two-pane app — Stacks on the left, Proxy settings on the
      right (Tab/←/→ move between the 5 positions, 1-4 jump straight to a
      proxy sub-tab, q/Ctrl-C quit). The title bar shows whether Docker
      itself is running.
        Stacks           — every stack and service on the host (not just
                       this directory), one card each: border green while
                       its container runs, red otherwise; ID, FOLDER (or a
                       service's URL), proxy state; ➤ marks the one the
                       Proxy pane shows. ↑/↓ select, `o` open a shell
                       (a service: start it and show its URL), `n` (or
                       Enter on "+ New stack") pick a toolbelt or service
                       to start, Enter make it the active stack, `s`
                       stop/start the whole stack (nothing deleted),
                       `a`/`b` start/stop only its proxy, `d` delete the
                       stack (confirm first; same as `dev stop`).
        1 Domain Stats   — every domain seen for the active stack, hits,
                       live ALLOWED/BLOCKED, last seen. `a` allow (into
                       your gitignored local.txt), `b` block.
        2 Global WL      — the shared, committed whitelist files. `b` remove,
                       `n` add (then: common to every environment, or just
                       this one?).
        3 Custom WL      — your gitignored local.txt. `n` add, `b` remove.
        4 Access log     — the raw log for the active stack, following
                       until you scroll up (↑/↓); `c` clears it.
      -r/--debug apply to whatever you start from the app. -f: passive —
      redraws the Domain Stats table every 2s, no key handling. Piped/
      non-terminal output (and no -f): one-shot Domain Stats snapshot plus
      an "add a domain" prompt (also always local.txt).

  ./run.py setup
      One-time host setup: git identity, container shell config, CA
      certificate bundle, proxy settings, and the `dev` shell function.

  ./run.py stop [-v /path/to/mount]
      Stop & delete stacks mounted from that directory (default: cwd).

  ./run.py stop --all
      Stop & delete every devcontainer stack and service, from any directory
      (a service's external data volume is kept).

  ./run.py list
      List every stack and service (project, env, service, status, workspace).

  ./run.py logs [-v /path/to/mount] [-f]
      Show the whitelist proxy's access log (allowed + denied domains) for
      the stack mounted from that directory (default: cwd). -f follows it
      live; prompts if more than one stack is running from that directory.

  ./run.py build-base [-r] [--debug]
      Build the shared base image (toolbelt-base:latest) and exit. Only
      rebuilds if common/ changed since it was last built; -r forces a
      from-scratch rebuild. Honours RUST_VERSION from the environment.

  ./run.py -h | --help | help
      Show this help.

Options:
  -v, --volume <path>   Directory to mount at /workspace (default: cwd).
  -r, --rebuild         Force a from-scratch rebuild (--no-cache).
  -f, --follow          Passive/follow mode instead of the interactive app or a one-shot view.
  --debug               Verbose docker build output (--progress=plain).

If installed via `run.py setup`, all of the above also work as `dev ...`
(e.g. `dev stop --all`, `dev list`).
"""


def main(argv):
    invocation_dir = os.getcwd()

    args = list(argv)
    pre_volume = None
    if args and args[0] in ("-v", "--volume"):
        if len(args) < 2:
            die("--volume requires a value")
        pre_volume = args[1]
        args = args[2:]

    if args and args[0] == "setup":
        hostsetup.run()
        return 0

    if pre_volume is not None:
        args = ["-v", pre_volume] + args

    return _run_generic(args, invocation_dir)


def _run_generic(args, invocation_dir):
    stop = stop_all = do_list = do_logs = follow = rebuild = debug = build_base = False
    volume_in = invocation_dir

    i = 0
    while i < len(args):
        tok = args[i]
        if tok in ("-h", "--help", "help"):
            print(HELP_TEXT, end="")
            return 0
        elif tok == "stop":
            stop = True; i += 1
        elif tok == "list":
            do_list = True; i += 1
        elif tok == "logs":
            do_logs = True; i += 1
        elif tok == "build-base":
            build_base = True; i += 1
        elif tok == "--all":
            stop_all = True; i += 1
        elif tok in ("-v", "--volume"):
            if i + 1 >= len(args):
                die("--volume requires a value")
            volume_in = args[i + 1]; i += 2
        elif tok in ("-r", "--rebuild"):
            rebuild = True; i += 1
        elif tok in ("-f", "--follow"):
            follow = True; i += 1
        elif tok == "--debug":
            debug = True; i += 1
        else:
            die(f"Unknown argument: {tok}")

    if not Path(volume_in).is_dir():
        die(f"Volume directory not found: {volume_in}")
    volume = str(Path(volume_in).resolve())

    if do_list:
        launcher.cmd_list()
        return 0
    if do_logs:
        launcher.cmd_logs(volume, follow)
        return 0
    if stop_all:
        if not stop:
            die("--all is only valid with 'stop'")
        launcher.cmd_stop_all()
        return 0
    if stop:
        launcher.cmd_stop(volume)
        return 0
    if build_base:
        env = launcher.build_env()
        launcher.ensure_base_image(rebuild, debug, env)
        print(f"✅ Base image {launcher.BASE_IMAGE} is ready.")
        return 0

    # No subcommand: the two-pane Stacks / proxy-settings app.
    proxy.cmd_overview(volume, follow, rebuild, debug)
    return 0
