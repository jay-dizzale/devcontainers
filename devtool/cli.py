"""devtool/cli.py — top-level argument dispatch for `run.py`, a direct port of the previous
run.sh's own flag-parsing/dispatch logic. Deliberately NOT argparse-based for the top-level
loop: flags can appear in any order/repetition exactly as before, and `setup` must be either
the very first token or immediately follow a single leading `-v`/`--volume <path>` (to match
what the `dev()` shell function set up by `run.py setup` always prepends:
`dev() { "<repo>/run.py" -v "$(pwd)" "$@"; }`, so `dev setup` arrives here as `-v <cwd> setup`)
— argparse's subparsers don't model that shape naturally, so a manual walk mirrors run.sh's
own loop instead.

There is no `proxy` subcommand: bare `run.py` (no subcommand at all) launches the 4-tab
Stacks/Domains/Whitelist/Access-log app directly (devtool/proxy.py). Its Stacks tab lists
every existing devcontainer stack host-wide (`dev` is invoked from all over the place, so this
is never scoped to "the current directory") and its 'n' action is now the environment picker
that used to be a separate plain-text prompt here, for whichever directory `run.py` itself was
invoked from.
"""
import os
from pathlib import Path

from . import hostsetup, launcher, proxy
from .docker_utils import die

HELP_TEXT = """\
run.py — Interactive launcher for docker-compose devcontainer stacks.

Usage:
  ./run.py [-v /path/to/mount] [-r] [--debug] [-f]
      Opens a 4-tab app (←/→ or 1-4 to switch, q/Ctrl-C to quit):
        1 Stacks     — every devcontainer stack that already exists,
                       host-wide (not just this directory — `dev` gets
                       run from all over the place), RUNNING/STOPPED; ➤
                       marks the one the other tabs operate on, → marks
                       the cursor. ↑/↓ select, `o` open a shell in the
                       selected one (builds/starts it first if needed),
                       `n` start a brand-new environment for the current
                       directory (prompts which toolbelt), Enter switch
                       the active stack without opening a shell, `a`
                       start its proxy, `b` stop it (blocks that stack's
                       dev egress until started again).
        2 Domains    — every domain seen for the active stack, hits, live
                       ALLOWED/BLOCKED, last seen. ↑/↓ select, `a` allow if
                       BLOCKED, `b` block if ALLOWED.
        3 Whitelist  — every domain actually configured (not just ones
                       seen), which file, exact vs. wildcard. ↑/↓ select,
                       `b` removes it, `n` prompts for a brand-new domain
                       (then asks: common to every environment, or just
                       this one?).
        4 Access log — the raw, timestamped log for the active stack,
                       auto-following until you scroll up (↑/↓); `c`
                       clears it in place.
      -r/--debug apply to whatever environment you `o`-pen. -f: passive —
      redraws Tab 2's table every 2s, no key handling, for piping/logging
      or just watching without the controls (Ctrl-C to stop).
      Piped/non-terminal output (and no -f): one-shot snapshot of Tab 2
      plus an "add a domain" prompt.

  ./run.py setup
      One-time host setup: git identity, container shell config, CA
      certificate bundle, proxy settings, and the `dev` shell function.

  ./run.py stop [-v /path/to/mount]
      Stop & delete stacks mounted from that directory (default: cwd).

  ./run.py stop --all
      Stop & delete every devcontainer stack, from any directory.

  ./run.py list
      List every devcontainer stack (project, env, service, status, workspace).

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

    # No subcommand: the unified Stacks/Domains/Whitelist/Access-log app. Its Stacks tab's 'n'
    # action now covers what the old plain-text environment picker did, so there's nothing
    # further to branch on here.
    proxy.cmd_overview(volume, follow, rebuild, debug)
    return 0
