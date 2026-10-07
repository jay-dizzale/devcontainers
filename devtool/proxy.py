"""devtool/proxy.py — the two-pane curses app that bare `run.py` launches: Stacks on the left
(1/3 width — every devcontainer stack on the host, not just the current directory's),
proxy settings on the right (2/3 width — Domain Statistics/Global Whitelist/Custom
Whitelist/Access log sub-tabs). 'o'/'n' tear the TUI down first, since a
real interactive zsh session can't run inside curses' alternate screen; the program ends
when that shell exits.
Non-tty: a one-shot Domain Statistics snapshot; `-f`: a passive 2s-redraw loop.

Stdlib only (subprocess/curses — no pip install, no `docker` SDK). Ported from a POSIX-sh
version after real cross-platform bugs on macOS (awk -v with a multi-line value, BSD vs. GNU
`sed -i`) and unreliable hand-parsed arrow keys: whitelist edits here are plain file I/O, and
key input goes through curses (plus _read_key's arrow reassembly). See AGENTS.md's "Egress
proxy and domain whitelist" section for the full architecture.
"""
import contextlib
import curses
import io
import os
import select
import signal
import sys
import time
from pathlib import Path

from . import launcher
from .docker_utils import (
    CONFIG_FILES, ENV, ID, PROJECT, REPO_ROOT, STATE, WORKDIR, WORKSPACE,
    die, docker, docker_engine_version, docker_out, proxy_cid_for_project, ps_rows, resolve_stack,
)

WHITELIST_DIR = REPO_ROOT / "common" / "proxy" / "whitelist.d"
# Where do_allow_domain always writes (see below) — gitignored, so a domain added through the
# TUI/CLI can never again end up committed into a tracked whitelist.d file by accident (that's
# exactly what happened once: a personal domain landed in 00-common.txt via this tool and got
# pushed). A domain meant to be shared with the team still goes into the tracked
# whitelist.d/*.txt files, but only via someone deliberately editing and committing it by hand.
WHITELIST_LOCAL_FILE = WHITELIST_DIR / "local.txt"


def list_all_stacks():
    """One row per devcontainer stack found on the host — any directory, not just the one
    `run.py` happens to be invoked from this time (`dev` is run from all over the place).
    project, env, workspace, and its proxy container's id + status (RUNNING/STOPPED). Backs
    the Stacks tab, which lets the user switch which stack the other tabs operate on, open a
    shell in any of them (`o`), and start/stop any stack's proxy — all without first `cd`-ing
    into its workspace. Starting a brand-new environment is a separate action (`n`, see
    OverviewApp._new_stack), not a row here — this only ever lists what already exists."""
    # Two bulk `docker ps --format` calls total, however many stacks exist.
    seen = {}
    for project, env, workspace, state in ps_rows("label=devcontainer.env", fields=[PROJECT, ENV, WORKSPACE, STATE]):
        if project:
            seen[project] = (env, workspace, state)

    proxy_by_project = {
        project: (cid, state == "running")
        for project, cid, state in ps_rows("label=com.docker.compose.service=proxy", fields=[PROJECT, ID, STATE])
        if project
    }

    stacks = []
    for project, (env, workspace, state) in sorted(seen.items()):
        proxy_cid, running = proxy_by_project.get(project, (None, False))
        stacks.append({
            "project": project,
            "env": env,
            "workspace": workspace,
            "proxy_cid": proxy_cid,
            "status": "RUNNING" if running else "STOPPED",  # the proxy's state
            # The stack's own `dev` container: docker's state word
            # (running/exited/created/paused/restarting) — the card's border color and label.
            "container_state": state or "unknown",
        })

    return stacks


def restart_running_proxies():
    """Restarts every currently-running proxy container so a whitelist edit applies
    immediately. The `proxy` service carries no `devcontainer.env` label of its own (only
    `dev` does), so this filters on the compose service name, then double-checks each match's
    config-files label actually includes our proxy.docker-compose.yml, so an unrelated
    project's own "proxy" service (if one somehow exists on the host) is never touched."""
    running = [
        (cid, workdir)
        for cid, cfg, workdir in ps_rows("label=com.docker.compose.service=proxy", fields=[ID, CONFIG_FILES, WORKDIR], all_=False)
        if "common/proxy.docker-compose.yml" in cfg
    ]
    if not running:
        print("ℹ️  No running proxy containers right now — the change applies the next time a stack starts.")
        return

    print("🔁 Restarting running proxy container(s) so the change takes effect ...")
    for cid, workdir in running:
        label = Path(workdir).name if workdir else "?"
        if docker("restart", cid).returncode == 0:
            print(f"   ✅ {label}")
        else:
            print(f"   ⚠️  failed to restart {label}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Whitelist file helpers — plain Python file I/O. No sed/grep portability
# question exists here (that bug class is gone structurally, not patched).
# ---------------------------------------------------------------------------
def whitelist_files():
    return sorted(WHITELIST_DIR.glob("*.txt"))


def read_domains(path):
    return [s for s in (line.strip() for line in path.read_text().splitlines()) if s and not s.startswith("#")]


def read_global_whitelist_entries():
    """Entries from the TRACKED whitelist.d files only (00-common.txt + per-env
    *-toolbelt.txt) — excludes the gitignored local.txt. Backs the Global Whitelist tab, which
    is for deliberately editing/committing shared config, not quick local additions. Each
    entry carries a `group` ("common" for 00-common.txt, "specific" for every per-toolbelt
    file) so the tab can draw them as two visually separated sections — sorting puts every
    "common" entry before any "specific" one, domain-alphabetical within each group."""
    entries = []
    for f in whitelist_files():
        if f == WHITELIST_LOCAL_FILE:
            continue
        group = "common" if f.name == "00-common.txt" else "specific"
        for domain in read_domains(f):
            entries.append({"domain": domain, "file": f.name, "wildcard": domain.startswith("."), "group": group})
    entries.sort(key=lambda e: (0 if e["group"] == "common" else 1, e["domain"]))
    return entries


def read_custom_whitelist_entries():
    """Entries from the gitignored local.txt only — backs the Custom Whitelist tab (personal,
    never-committed additions; see WHITELIST_LOCAL_FILE's module-level comment)."""
    if not WHITELIST_LOCAL_FILE.exists():
        return []
    return [
        {"domain": d, "file": WHITELIST_LOCAL_FILE.name, "wildcard": d.startswith(".")}
        for d in read_domains(WHITELIST_LOCAL_FILE)
    ]


def _files_listing(domain):
    return [f for f in whitelist_files() if domain in read_domains(f)]


def _write_new_domain(target, domain):
    hits = _files_listing(domain)
    if hits:
        names = " ".join(f.name for f in hits)
        print(f"ℹ️  '{domain}' is already whitelisted (in {names}).")
        return
    with target.open("a") as fh:
        fh.write(domain + "\n")
    print(f"✅ Added '{domain}' to {target.name}.")
    restart_running_proxies()


def do_allow_domain(domain):
    """Local/personal only — always writes to the gitignored WHITELIST_LOCAL_FILE. Used by the
    Domain Statistics tab's quick 'allow' action and the Custom Whitelist tab's 'n' — see
    WHITELIST_LOCAL_FILE's module-level comment for why this tool never writes to a tracked
    whitelist.d file through either of those."""
    _write_new_domain(WHITELIST_LOCAL_FILE, domain)


def do_allow_domain_global(domain, env=None):
    """Deliberately edits a TRACKED whitelist file — only the Global Whitelist tab's 'n'
    action calls this, after asking whether the domain belongs in the shared 00-common.txt or
    this stack's own <env>-toolbelt.txt. Never used for a quick/local allow (do_allow_domain
    above is for that)."""
    if env:
        target = WHITELIST_DIR / f"{env}.txt"
        if not target.exists():
            die(f"No whitelist file for '{env}' — expected {target} (name matches the toolbelt directory, e.g. java-toolbelt)")
    else:
        target = WHITELIST_DIR / "00-common.txt"
    _write_new_domain(target, domain)


def do_block_domain(domain):
    """Removes a domain from EVERY whitelist.d/*.txt file that lists it exactly (it can be
    covered by more than one — e.g. a shared Apache mirror both java-toolbelt.txt and
    infrastructure-toolbelt.txt list). No-op, clearly reported, if the domain isn't literally
    listed anywhere — e.g. it's only reachable via a broader pattern like the leading-dot
    .amazonaws.com wildcard, which has to be edited by hand."""
    hits = _files_listing(domain)
    if not hits:
        print(f"⚠️  '{domain}' isn't literally listed in any whitelist.d file — it's likely allowed by a")
        print("   broader pattern (e.g. a leading-dot wildcard like .amazonaws.com); edit that by hand.")
        return False

    for f in hits:
        lines = f.read_text().splitlines(keepends=True)
        kept = [ln for ln in lines if ln.rstrip("\n") != domain]
        f.write_text("".join(kept))

    names = " ".join(f.name for f in hits)
    print(f"🚫 Removed '{domain}' from: {names}")
    restart_running_proxies()
    return True


# ---------------------------------------------------------------------------
# access.log / live-whitelist parsing — for the Domain Statistics (per-domain) and
# Access log (raw) sub-tabs.
# Squid's log fields: <epoch>.<ms> <elapsed> <client> <code>/<status> <bytes>
# <method> <url> <ident> <hierarchy>/<peer> <mime-type>. See
# common/proxy/squid.conf for the full layout.
# ---------------------------------------------------------------------------
def extract_host(url):
    host = url
    if "://" in host:
        host = host.split("://", 1)[1]
    host = host.split("/", 1)[0]
    if ":" in host:
        host = host.rsplit(":", 1)[0]
    return host


def read_live_whitelist(cid):
    entries = docker_out("exec", cid, "cat", "/etc/squid/whitelist.txt").split()
    return {e for e in entries if not e.startswith(".")}, [e for e in entries if e.startswith(".")]


def is_allowed(host, exact, wildcards):
    return host in exact or any(host.endswith(w) for w in wildcards)


def parse_access_log(cid):
    """Raw per-line rows, oldest first: {ts, code, method, url, host}."""
    out = docker_out("exec", cid, "cat", "/var/log/squid/access.log")
    rows = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 7:
            continue
        try:
            ts = float(parts[0])
        except ValueError:
            continue
        host = extract_host(parts[6])
        if host:
            rows.append({"ts": ts, "code": parts[3].split("/")[0], "method": parts[5], "url": parts[6], "host": host})
    rows.sort(key=lambda r: r["ts"])
    return rows


def fetch_domain_rows(cid, log_rows=None):
    """Aggregated per-domain rows for Tab 1: STATUS is checked against the *live* merged
    whitelist (exact or leading-dot wildcard), not the log's last-recorded verdict — otherwise
    pressing a/b doesn't visibly change a row until fresh traffic re-proves it, which looks
    like the action silently did nothing. `log_rows` lets a caller that already fetched
    access.log (refresh() also needs it for the Access log tab) pass it in instead of this
    re-running `docker exec cat access.log` a second time."""
    exact, wildcards = read_live_whitelist(cid)
    agg = {}
    for r in (log_rows if log_rows is not None else parse_access_log(cid)):
        e = agg.setdefault(r["host"], {"count": 0, "last": 0.0})
        e["count"] += 1
        e["last"] = max(e["last"], r["ts"])
    rows = [
        {
            "host": host,
            "verdict": "ALLOWED" if is_allowed(host, exact, wildcards) else "BLOCKED",
            "count": e["count"],
            "last": e["last"],
        }
        for host, e in agg.items()
    ]
    rows.sort(key=lambda r: r["host"])
    return rows


# ---------------------------------------------------------------------------
# Plain-text modes: piped/non-tty snapshot and passive --follow.
# ---------------------------------------------------------------------------
def _overview_text(cid, env, project, workspace):
    rows = fetch_domain_rows(cid)
    lines = [f"📡 Egress overview — '{env}' (project {project}, {workspace})  [{time.strftime('%H:%M:%S')}]", ""]
    if not rows:
        lines.append("   (no traffic logged yet)")
    else:
        now = time.time()
        lines.append(f"   {'DOMAIN':<40} {'HITS':>6}  {'STATUS':<9} LAST SEEN")
        lines += [f"   {r['host']:<40} {r['count']:>6}  {r['verdict']:<9} {int(now - r['last'])}s ago" for r in rows]
    return "\n".join(lines) + "\n"


def run_snapshot(cid, env, project, workspace):
    print(_overview_text(cid, env, project, workspace))
    try:
        new_domain = input("➕ Add a domain to local.txt (not tracked by git; Enter to skip): ").strip()
    except EOFError:
        new_domain = ""
    if new_domain:
        do_allow_domain(new_domain)


def run_follow(cid, env, project, workspace):
    try:
        while True:
            # Fetch first, then clear + print in one go — no blank-screen flicker per redraw.
            text = _overview_text(cid, env, project, workspace)
            print("\033[2J\033[H" + text + "\n(Ctrl-C to stop watching)", flush=True)
            time.sleep(2)
    except KeyboardInterrupt:
        print("\n👋 Stopped watching.")


TAB_STACKS, TAB_DOMAINS, TAB_WHITELIST, TAB_CUSTOM, TAB_LOG = range(5)

# The right-hand "proxy settings" pane keeps its own small sub-tab bar — Stacks is the
# permanent left pane (see OverviewApp.draw), not one of these. TAB_WHITELIST ("Global
# Whitelist") shows/edits only the TRACKED whitelist.d files (00-common.txt + per-env
# *-toolbelt.txt); TAB_CUSTOM ("Custom Whitelist") shows/edits only the gitignored local.txt
# — see read_global_whitelist_entries/read_custom_whitelist_entries and
# do_allow_domain/do_allow_domain_global.
PROXY_TABS = [TAB_DOMAINS, TAB_WHITELIST, TAB_CUSTOM, TAB_LOG]
PROXY_TAB_TITLES = [" 1:Domain Stats ", " 2:Global WL ", " 3:Custom WL ", " 4:Access log "]


@contextlib.contextmanager
def _quiet_stdout():
    """do_allow_domain/do_block_domain print status lines meant for the plain-text fallback
    paths (run_snapshot, run_follow). Inside the curses app those prints bypass
    curses' own buffer and go straight to the real terminal underneath the alternate
    screen, corrupting the display until torn down and redrawn — confirmed: pressing
    a/b/n visibly scrambled the screen. The curses call sites already surface the same
    information via self.message, so stdout is simply discarded here."""
    with contextlib.redirect_stdout(io.StringIO()):
        yield


def _safe_addnstr(stdscr, y, x, s, n, attr=0):
    """addnstr wrapper that no-ops instead of raising when the write would fall outside the
    window. `max(0, width - x)`-style clamping at a call site only protects the *length*
    (`n`); ncurses still returns ERR (uncaught -> crash) when the *start* column/row itself is
    already at or past the last valid one — confirmed via a real crash: the sub-tab bar's
    running `x` offset walks past the right edge in a narrow terminal (or even a moderately
    narrow one with several tabs), and every title drawn after that point raised
    `_curses.error: addnwstr() returned ERR` with nothing to catch it. Centralizing the bounds
    check here means every draw call site is safe by construction instead of each one needing
    its own — the same class of bug that already motivated the try/except around the Stacks
    tab's card borders, just applied everywhere `addnstr` is used."""
    h, w = stdscr.getmaxyx()
    if y < 0 or y >= h or x < 0 or x >= w or n <= 0:
        return
    try:
        stdscr.addnstr(y, x, s, min(n, w - x), attr)
    except curses.error:
        pass


def _draw_box(stdscr, y0, x0, box_h, box_w, title):
    """An empty bordered box with a centered title — the frame of every modal."""
    for yy in range(box_h):
        if yy == 0:
            line = "┌" + "─" * (box_w - 2) + "┐"
        elif yy == box_h - 1:
            line = "└" + "─" * (box_w - 2) + "┘"
        else:
            line = "│" + " " * (box_w - 2) + "│"
        _safe_addnstr(stdscr, y0 + yy, x0, line, box_w, curses.color_pair(3))
    title = f" {title} "
    _safe_addnstr(stdscr, y0, x0 + max(1, (box_w - len(title)) // 2), title, box_w - 2, curses.color_pair(3) | curses.A_BOLD)


class OverviewApp:
    """The interactive curses app bare `run.py` opens: a permanent two-pane split — Stacks
    always visible on the left 1/3, the proxy settings (Domain Statistics/Global Whitelist/
    Custom Whitelist/Access log, switchable via their own sub-tab bar) on the right 2/3.
    Exactly one pane has input focus at a time (self.focus); Tab/←/→ moves focus."""

    def __init__(self, cid, env, project, workspace, target_dir):
        self.cid = cid
        self.env = env
        self.project = project
        self.workspace = workspace
        self.target_dir = target_dir  # fixed: where 'n' (new stack) builds/starts into
        self.focus = "stacks"         # "stacks" (left pane) or "proxy" (right pane)
        self.proxy_tab = TAB_DOMAINS  # which sub-tab the right pane currently shows
        self.idx = [0, 0, 0, 0, 0]    # selected row, per tab (log tab unused — it scrolls)
        self.scroll = [0, 0, 0, 0]    # stacks/domains/whitelist/custom: first visible row (viewport top)
        self.log_offset = 0           # log tab: 0 = pinned to newest ("following")
        self.rows = [[], [], [], [], []]
        self.message = ""
        self.last_refresh = 0.0
        self.pending_action = None    # set by 'o' (open shell) — breaks the main loop to act on
        self.docker_version = None    # Docker engine version, None = daemon not reachable (title bar)

    def current_tab(self):
        """Which tab's rows/selection respond to ↑/↓ and action keys right now — the
        focused pane's tab (Stacks for the left pane, whichever sub-tab is showing for the
        right pane)."""
        return TAB_STACKS if self.focus == "stacks" else self.proxy_tab

    def _pane_pos(self):
        """Linear position along Stacks(0) → Domain Stats(1) → Global WL(2) → Custom WL(3) →
        Access log(4), so ←/→ can walk through all five one step at a time — all the way
        right into the last sub-tab, then back out to Stacks by going left — instead of only
        toggling between the two panes."""
        if self.focus == "stacks":
            return 0
        return 1 + PROXY_TABS.index(self.proxy_tab)

    def _set_pane_pos(self, pos):
        pos = max(0, min(len(PROXY_TABS), pos))
        if pos == 0:
            self.focus = "stacks"
        else:
            self.focus = "proxy"
            self.proxy_tab = PROXY_TABS[pos - 1]

    def refresh(self):
        self.docker_version = docker_engine_version()
        self.rows[TAB_STACKS] = list_all_stacks()
        log_rows = parse_access_log(self.cid) if self.cid else []
        self.rows[TAB_LOG] = log_rows
        self.rows[TAB_DOMAINS] = fetch_domain_rows(self.cid, log_rows) if self.cid else []
        self.rows[TAB_WHITELIST] = read_global_whitelist_entries()
        self.rows[TAB_CUSTOM] = read_custom_whitelist_entries()
        self.last_refresh = time.time()
        for i in (TAB_DOMAINS, TAB_WHITELIST, TAB_CUSTOM):
            if self.rows[i]:
                self.idx[i] = min(self.idx[i], len(self.rows[i]) - 1)
            else:
                self.idx[i] = 0
        # Stacks: +1 slot for the trailing "+ New stack" row, which always exists even with
        # zero real stacks — clamping to len(rows) - 1 like the other tabs would make it
        # unreachable.
        self.idx[TAB_STACKS] = max(0, min(self.idx[TAB_STACKS], len(self.rows[TAB_STACKS])))

    # -- drawing ------------------------------------------------------
    def draw(self, stdscr):
        stdscr.erase()
        h, w = stdscr.getmaxyx()

        name = " devcontainers "
        pad = max(0, w - len(name))
        sep = ("─" * (pad // 2)) + name + ("─" * (pad - pad // 2))
        _safe_addnstr(stdscr, 0, 0, sep[:w], w, curses.color_pair(3) | curses.A_BOLD)

        # Docker engine status, top-left: when the daemon is down every docker call quietly
        # returns nothing, so without this an empty Stacks pane looks like "no stacks" rather
        # than "Docker isn't running".
        if self.docker_version:
            engine, engine_attr = f" ● Docker running (v{self.docker_version}) ", curses.color_pair(1) | curses.A_BOLD
        else:
            engine, engine_attr = " ● Docker stopped ", curses.color_pair(2) | curses.A_BOLD | curses.A_REVERSE
        _safe_addnstr(stdscr, 0, 1, engine, max(0, w - 2), engine_attr)

        credit = " made by jay-dizzale 🐳 "
        if len(credit) < w:
            _safe_addnstr(stdscr, 0, w - len(credit), credit, len(credit), curses.color_pair(4) | curses.A_DIM)

        left_w = max(18, w // 3)
        divider_x = min(left_w, w - 1)
        right_x = divider_x + 1
        right_w = max(5, w - right_x)

        stacks_attr = (curses.color_pair(3) | curses.A_REVERSE) if self.focus == "stacks" else (curses.color_pair(3) | curses.A_BOLD)
        _safe_addnstr(stdscr, 1, 0, " STACKS ".ljust(left_w), left_w, stacks_attr)

        proxy_attr = (curses.color_pair(3) | curses.A_REVERSE) if self.focus == "proxy" else (curses.color_pair(3) | curses.A_BOLD)
        _safe_addnstr(stdscr, 1, right_x, " PROXY ".ljust(right_w), max(0, right_w), proxy_attr)

        x = right_x
        for tab_const, title in zip(PROXY_TABS, PROXY_TAB_TITLES):
            focused_here = self.focus == "proxy" and tab_const == self.proxy_tab
            attr = (curses.color_pair(3) | curses.A_REVERSE) if focused_here else curses.color_pair(3)
            _safe_addnstr(stdscr, 2, x, title, max(0, right_x + right_w - x), attr)
            x += len(title) + 1

        body_top = 4
        body_h = h - body_top - 2
        for y in range(1, body_top + body_h):
            try:
                stdscr.addch(y, divider_x, "│", curses.color_pair(3) | curses.A_DIM)
            except curses.error:
                pass  # bottom-right-cell write restriction — harmless to skip

        self._draw_stacks_tab(stdscr, body_top, body_h, 0, left_w)

        if self.proxy_tab == TAB_DOMAINS:
            self._draw_domain_tab(stdscr, body_top, body_h, right_x, right_w)
        elif self.proxy_tab == TAB_WHITELIST:
            self._draw_whitelist_tab(stdscr, body_top, body_h, right_x, right_w)
        elif self.proxy_tab == TAB_CUSTOM:
            self._draw_custom_whitelist_tab(stdscr, body_top, body_h, right_x, right_w)
        else:
            self._draw_log_tab(stdscr, body_top, body_h, right_x, right_w)

        footer = self.message or self._footer_hint()
        _safe_addnstr(stdscr, h - 1, 0, footer[: w - 1], w - 1)
        stdscr.refresh()

    def _footer_hint(self):
        common = "←/→ move · Tab jump pane · q quit"
        tab = self.current_tab()
        if tab == TAB_STACKS:
            return f"↑/↓ select · o open shell · n new stack · Enter switch/new · s start/stop stack · a start proxy · b stop proxy · d delete stack · {common}"
        sub = "1/2/3/4 sub-tab · "
        if tab == TAB_DOMAINS:
            return f"↑/↓ select · a allow (→ local.txt) · b block · {sub}{common}"
        if tab == TAB_WHITELIST:
            return f"↑/↓ select · n new (common/env, tracked) · b remove · {sub}{common}"
        if tab == TAB_CUSTOM:
            return f"↑/↓ select · n new (local.txt) · b remove · {sub}{common}"
        return f"↑/↓ scroll · c clear log · {sub}{common}"

    def _visible_window(self, tab, n_rows, height, lines_per_row=1, header_rows=1, idx=None):
        """Clamp-to-view scrolling: keeps self.idx[tab] inside [scroll, scroll+visible)
        by adjusting self.scroll[tab], then returns (start, visible) for the caller to
        slice rows[start:start+visible]. Without this, a selection moved past the first
        screenful of rows was simply never drawn — the row count and height could each
        change between calls (fresh traffic, terminal resize), so both are re-clamped
        every draw rather than cached. `lines_per_row` lets a caller whose entries span
        several terminal lines (the Stacks tab's card layout) count scroll position in
        entries while still budgeting the right number of terminal rows. `header_rows`
        reserves that many rows for a column header the caller draws at `top` — the Stacks
        tab passes 0 since its cards have no such header (the type is in the card's own
        border instead). `idx` overrides the selection's position when the caller scrolls in
        its own display-line space (the Global Whitelist tab, whose group headers take up
        lines too)."""
        visible = max(1, (height - header_rows) // lines_per_row)
        scroll = self.scroll[tab]
        idx = self.idx[tab] if idx is None else idx
        if idx < scroll:
            scroll = idx
        elif idx >= scroll + visible:
            scroll = idx - visible + 1
        scroll = max(0, min(scroll, max(0, n_rows - visible)))
        self.scroll[tab] = scroll
        return scroll, visible

    # bordered card: top border, ID title (+ proxy state), id, FOLDER title, value, bottom border
    _STACK_ENTRY_LINES = 6

    # Light box-drawing for normal cards, heavy for the selected one — selection can't be a
    # border color any more, since the color now carries the container's state (green/red).
    _BOX_LIGHT = {"tl": "┌", "tr": "┐", "bl": "└", "br": "┘", "h": "─", "v": "│"}
    _BOX_HEAVY = {"tl": "┏", "tr": "┓", "bl": "┗", "br": "┛", "h": "━", "v": "┃"}

    @staticmethod
    def _card_top_border(card_w, label, box=_BOX_LIGHT):
        """The top border with the stack's env type embedded top-right (" java-toolbelt ")
        instead of a separate TYPE column header, which never fit a card layout (it described
        a single column while each card spans the whole row). No label (the "+ New stack"
        pseudo-card) falls back to a plain border."""
        avail = max(0, card_w - 2)
        if not label:
            return box["tl"] + box["h"] * avail + box["tr"]
        text = f" {label} "[: max(0, avail - 1)]  # keep >=1 dash before the right corner
        left_len = max(0, avail - len(text) - 1)
        return box["tl"] + box["h"] * left_len + text + box["h"] + box["tr"]

    def _draw_stacks_tab(self, stdscr, top, height, x0, w):
        """The list always has one extra trailing row — "+ New stack" — past the real stacks,
        so starting a new one is just another list item (Enter on it) rather than only a
        separate key ('n' still works too, from anywhere in this pane). Each stack is its own
        bordered card: its env type sits in the top border (top-right, see
        _card_top_border), its first content line has the ➤ active-stack marker and the
        stack id together on the left and the proxy's live state ("PROXY ACTIVE"/"PROXY
        INACTIVE", colored) right-aligned, then the workspace folder on its own line. No
        plain column header above the cards — a single-column header never matched a card
        layout. The border's color is the stack's own container state — green when it's
        running, red otherwise — and that state is also spelled out top-left in the border
        (" RUNNING "/" EXITED "), so the proxy's state (line 1) and the container's are both
        visible. Selection is a heavy bold border (shape, not color, since color is taken) —
        a reverse-video border looked like a filled shadow block, and reversing the content
        too (status colors, dimmed id/workspace) looked noisy on top of that."""
        rows = self.rows[TAB_STACKS]
        total = len(rows) + 1
        lines = self._STACK_ENTRY_LINES
        start, visible = self._visible_window(TAB_STACKS, total, height, lines_per_row=lines, header_rows=0)
        card_w = max(4, w - 3)

        for row_i in range(start, min(start + visible, total)):
            y = top + (row_i - start) * lines
            selected = row_i == self.idx[TAB_STACKS]
            is_new_row = row_i == len(rows)
            box = self._BOX_HEAVY if selected else self._BOX_LIGHT
            if is_new_row:
                border_attr = (curses.color_pair(4) | curses.A_BOLD) if selected else curses.color_pair(3)
                label = None
            else:
                container_up = rows[row_i]["container_state"] == "running"
                border_attr = curses.color_pair(1 if container_up else 2) | (curses.A_BOLD if selected else 0)
                label = rows[row_i]["env"]
            try:
                _safe_addnstr(stdscr, y, x0 + 1, self._card_top_border(card_w, label, box), card_w, border_attr)
                _safe_addnstr(stdscr, y + lines - 1, x0 + 1, box["bl"] + box["h"] * (card_w - 2) + box["br"], card_w, border_attr)
                for ln in range(1, lines - 1):
                    stdscr.addstr(y + ln, x0 + 1, box["v"], border_attr)
                    stdscr.addstr(y + ln, x0 + card_w, box["v"], border_attr)
            except curses.error:
                pass  # card clipped by the pane edge — harmless to skip

            if not is_new_row:
                # Container state top-left in the border, only where it doesn't collide with
                # the env label on the right (narrow pane: the label wins).
                state_text = f" {rows[row_i]['container_state'].upper()} "
                if 3 + len(state_text) + len(label) + 4 <= card_w:
                    _safe_addnstr(stdscr, y, x0 + 3, state_text, len(state_text), border_attr | curses.A_BOLD)

            if is_new_row:
                _safe_addnstr(stdscr, y + 2, x0 + 3, "+ New stack", max(0, card_w - 4), curses.color_pair(4) | curses.A_BOLD)
                continue

            s = rows[row_i]
            is_active = s["project"] and s["project"] == self.project
            running = s["status"] == "RUNNING"
            # Labeled fields: a title line (cyan, bold) with its value on the line below (bold,
            # not dimmed) — ID, then FOLDER. Content attrs never change
            # with selection — only the border (above) does, so the highlight reads as "this
            # card" rather than painting the text too.
            title_attr = curses.color_pair(3) | curses.A_BOLD
            value_attr = curses.A_BOLD
            status_attr = curses.color_pair(1) if running else curses.color_pair(2)
            marker_attr = curses.color_pair(4) | curses.A_BOLD if is_active else curses.A_NORMAL
            inner_w = max(0, card_w - 6)  # value column: x0+5 .. inside the right border

            _safe_addnstr(stdscr, y + 1, x0 + 3, "➤ " if is_active else "  ", 2, marker_attr)
            _safe_addnstr(stdscr, y + 1, x0 + 5, "ID", inner_w, title_attr)
            status_text = "PROXY ACTIVE" if running else "PROXY INACTIVE"
            status_x = max(x0 + 8, x0 + card_w - 1 - len(status_text))
            _safe_addnstr(stdscr, y + 1, status_x, status_text, max(0, x0 + card_w - status_x), status_attr)
            _safe_addnstr(stdscr, y + 2, x0 + 5, s["project"], inner_w, value_attr)

            _safe_addnstr(stdscr, y + 3, x0 + 5, "FOLDER", inner_w, title_attr)
            _safe_addnstr(stdscr, y + 4, x0 + 5, self._tail(s["workspace"], inner_w), inner_w, value_attr)

    @staticmethod
    def _tail(text, width):
        """Clip from the LEFT ("…/end/of/path") — the end of a folder path is the part that
        tells stacks apart, so it's the part that has to stay visible in a narrow pane."""
        if width <= 0 or len(text) <= width:
            return text
        return "…" + text[-(width - 1):] if width > 1 else text[-1:]

    def _draw_domain_tab(self, stdscr, top, height, x0, w):
        rows = self.rows[TAB_DOMAINS]
        _safe_addnstr(stdscr, top, x0 + 2, f"{'DOMAIN':<40} {'HITS':>6}  {'STATUS':<9} LAST SEEN", max(0, w - 2), curses.color_pair(3) | curses.A_UNDERLINE)
        if not rows:
            _safe_addnstr(stdscr, top + 2, x0 + 2, "(no traffic logged yet)", max(0, w - 2))
            return
        now = time.time()
        start, visible = self._visible_window(TAB_DOMAINS, len(rows), height)
        for row_i, r in enumerate(rows[start : start + visible]):
            y = top + 1 + row_i
            ago = int(now - r["last"])
            text = f"{r['host']:<40} {r['count']:>6}  {r['verdict']:<9} {ago}s ago"
            attr = curses.A_REVERSE if start + row_i == self.idx[TAB_DOMAINS] else (
                curses.color_pair(1) if r["verdict"] == "ALLOWED" else curses.color_pair(2)
            )
            _safe_addnstr(stdscr, y, x0 + 2, text, max(0, w - 2), attr)

    _WHITELIST_GROUP_LABEL = {
        "common": "── Common (00-common.txt — every environment) ──",
        "specific": "── Specific (per-environment whitelist.d/*.txt) ──",
    }

    def _draw_whitelist_tab(self, stdscr, top, height, x0, w):
        """Global Whitelist tab — the TRACKED whitelist.d files only (see
        read_global_whitelist_entries); local.txt entries live in the separate Custom
        Whitelist tab (_draw_custom_whitelist_tab) instead of a third group here."""
        rows = self.rows[TAB_WHITELIST]
        _safe_addnstr(stdscr, top, x0 + 2, f"{'DOMAIN':<40} {'TYPE':<8} FILE", max(0, w - 2), curses.color_pair(3) | curses.A_UNDERLINE)
        if not rows:
            _safe_addnstr(stdscr, top + 2, x0 + 2, "(no tracked whitelist.d entries)", max(0, w - 2))
            return

        # Build the actual display lines (group headers interspersed with rows) and scroll
        # in *that* space, not row-index space — otherwise _visible_window's row-count-based
        # budget doesn't know headers eat into it too, and with enough rows the selected one
        # could fall past the bottom of what actually gets drawn: the view "thinks" it
        # scrolled far enough, but a header line it didn't account for pushes the real
        # selection out of the rendered area, so the highlight silently never appears.
        lines = []  # ("header", label) | ("row", entry, row_index)
        last_group = None
        selected_i = 0
        for i, e in enumerate(rows):
            if e["group"] != last_group:
                lines.append(("header", self._WHITELIST_GROUP_LABEL[e["group"]]))
                last_group = e["group"]
            lines.append(("row", e, i))
            if i == self.idx[TAB_WHITELIST]:
                selected_i = len(lines) - 1

        # self.scroll[TAB_WHITELIST] is in display lines here, not rows.
        scroll, visible = self._visible_window(TAB_WHITELIST, len(lines), height, idx=selected_i)
        for row_i, line in enumerate(lines[scroll : scroll + visible]):
            y = top + 1 + row_i
            if line[0] == "header":
                _safe_addnstr(stdscr, y, x0 + 2, line[1], max(0, w - 2), curses.color_pair(3) | curses.A_DIM)
                continue
            _, e, real_i = line
            kind = "wildcard" if e["wildcard"] else "exact"
            text = f"{e['domain']:<40} {kind:<8} {e['file']}"
            if real_i == self.idx[TAB_WHITELIST]:
                attr = curses.A_REVERSE
            else:
                attr = curses.color_pair(4) if e["wildcard"] else curses.A_NORMAL
            _safe_addnstr(stdscr, y, x0 + 2, text, max(0, w - 2), attr)

    def _draw_custom_whitelist_tab(self, stdscr, top, height, x0, w):
        """Custom Whitelist tab — the gitignored local.txt only (see
        read_custom_whitelist_entries). No group headers needed, unlike the Global Whitelist
        tab, since there's only ever this one source file."""
        rows = self.rows[TAB_CUSTOM]
        _safe_addnstr(stdscr, top, x0 + 2, f"{'DOMAIN':<40} TYPE", max(0, w - 2), curses.color_pair(3) | curses.A_UNDERLINE)
        if not rows:
            _safe_addnstr(stdscr, top + 2, x0 + 2, "(local.txt is empty — 'n' to add a domain)", max(0, w - 2))
            return
        start, visible = self._visible_window(TAB_CUSTOM, len(rows), height)
        for row_i, e in enumerate(rows[start : start + visible]):
            y = top + 1 + row_i
            kind = "wildcard" if e["wildcard"] else "exact"
            text = f"{e['domain']:<40} {kind}"
            if start + row_i == self.idx[TAB_CUSTOM]:
                attr = curses.A_REVERSE
            else:
                attr = curses.color_pair(4) if e["wildcard"] else curses.A_NORMAL
            _safe_addnstr(stdscr, y, x0 + 2, text, max(0, w - 2), attr)

    def _draw_log_tab(self, stdscr, top, height, x0, w):
        rows = self.rows[TAB_LOG]
        if not rows:
            _safe_addnstr(stdscr, top, x0 + 2, "(no traffic logged yet)", max(0, w - 2))
            return
        visible = height
        end = len(rows) - self.log_offset
        start = max(0, end - visible)
        for row_i, r in enumerate(rows[start:end]):
            y = top + row_i
            ts = time.strftime("%H:%M:%S", time.localtime(r["ts"]))
            denied = "DENIED" in r["code"]
            text = f"{ts}  {r['method']:<8} {r['host']:<35} {r['code']}"
            attr = curses.color_pair(2) if denied else curses.color_pair(1)
            _safe_addnstr(stdscr, y, x0 + 2, text, max(0, w - 2), attr)
        if self.log_offset > 0:
            _safe_addnstr(stdscr, top + visible, x0 + 2, f"-- scrolled back {self.log_offset} — ↓ to catch up --", max(0, w - 2), curses.color_pair(3) | curses.A_DIM)

    # -- input ----------------------------------------------------------
    def _bindings(self, stdscr):
        """Action keys per tab (case-insensitive). A handler returning False quits the main
        loop (with self.pending_action set when the caller should act on something)."""
        return {
            TAB_STACKS: {
                "o": self._open_shell_selected,
                "n": lambda: self._new_stack(stdscr),
                "s": lambda: self._toggle_selected_stack(stdscr),
                "a": lambda: self._set_selected_proxy(True),
                "b": lambda: self._set_selected_proxy(False),
                "d": lambda: self._delete_selected_stack(stdscr),
            },
            TAB_DOMAINS: {"a": self._allow_selected, "b": self._block_selected_domain},
            TAB_WHITELIST: {"b": lambda: self._remove_selected_entry(TAB_WHITELIST), "n": lambda: self._prompt_new_global_domain(stdscr)},
            TAB_CUSTOM: {"b": lambda: self._remove_selected_entry(TAB_CUSTOM), "n": lambda: self._prompt_new_domain(stdscr)},
            TAB_LOG: {"c": self._clear_log},
        }

    def handle_key(self, stdscr, key):
        self.message = ""
        tab = self.current_tab()
        if key in (ord("q"), ord("Q")):
            return False
        if key == curses.KEY_RIGHT:
            self._set_pane_pos(self._pane_pos() + 1)
        elif key == curses.KEY_LEFT:
            self._set_pane_pos(self._pane_pos() - 1)
        elif key == 9:  # Tab — quick jump straight between the two panes
            self._set_pane_pos(0 if self.focus == "proxy" else 1)
        elif ord("1") <= key <= ord("4"):
            self.focus = "proxy"
            self.proxy_tab = PROXY_TABS[key - ord("1")]
        elif key in (curses.KEY_UP, curses.KEY_DOWN):
            self._move(-1 if key == curses.KEY_UP else 1)
        elif key in (10, 13, curses.KEY_ENTER) and tab == TAB_STACKS:
            if self.idx[TAB_STACKS] == len(self.rows[TAB_STACKS]):  # the "+ New stack" row
                return self._new_stack(stdscr) is not False
            self._switch_to_selected_stack()
        elif 0 <= key < 256:
            handler = self._bindings(stdscr)[tab].get(chr(key).lower())
            if handler and handler() is False:
                return False
        return True

    def _move(self, delta):
        tab = self.current_tab()
        if tab == TAB_STACKS:
            n = len(self.rows[TAB_STACKS]) + 1  # +1 for the trailing "+ New stack" row
            self.idx[TAB_STACKS] = max(0, min(n - 1, self.idx[TAB_STACKS] + delta))
        elif tab in (TAB_DOMAINS, TAB_WHITELIST, TAB_CUSTOM):
            n = len(self.rows[tab])
            if n:
                self.idx[tab] = max(0, min(n - 1, self.idx[tab] + delta))
        else:
            n = len(self.rows[TAB_LOG])
            self.log_offset = max(0, min(max(0, n - 1), self.log_offset - delta))

    # -- Stacks tab -------------------------------------------------------
    def _selected(self, tab):
        """The selected row of `tab`, or None (empty list / the Stacks "+ New stack" row)."""
        rows = self.rows[tab]
        return rows[self.idx[tab]] if self.idx[tab] < len(rows) else None

    def _selected_stack(self):
        return self._selected(TAB_STACKS)

    def _switch_to_selected_stack(self):
        s = self._selected_stack()
        if not s:
            return
        if not s["proxy_cid"]:
            self.message = f"⚠️  '{s['env']}' has no proxy container."
            return
        self.cid = s["proxy_cid"]
        self.env = s["env"]
        self.project = s["project"]
        self.workspace = s["workspace"]
        self.refresh()
        self.message = f"🔀 Switched to '{s['env']}' (project {s['project']})."

    def _open_shell_selected(self):
        """'o': build/start (if needed) and open a shell in the selected existing stack.
        Can't exec an interactive zsh session inside curses' alternate screen, so this just
        records the request and exits the main loop; the caller (cmd_overview) acts on it
        once curses.wrapper has torn the TUI down and restored the normal terminal."""
        s = self._selected_stack()
        if not s:
            return None
        self.pending_action = ("open_shell", s)
        return False

    def _new_stack(self, stdscr):
        """'n': a centered modal (see _new_stack_modal) to pick an environment type and a
        target folder (default: the directory `run.py` was invoked from), replacing the old
        plain-text stderr/stdin picker. Esc inside the modal cancels and returns to the
        Stacks tab without doing anything. Confirming tears curses down (same handoff as
        'o' — a real interactive zsh session can't run inside curses' alternate screen) and
        hands the choice to cmd_overview to build/start/open a shell in."""
        choice = self._new_stack_modal(stdscr)
        if choice is None:
            self.message = "Cancelled."
            return None
        self.pending_action = ("new_stack", choice)
        return False

    def _new_stack_modal(self, stdscr):
        """Runs its own small blocking event loop — like _prompt_new_domain — rather than
        wiring into draw()/handle_key(), since it's a one-shot modal that owns input until
        confirmed or cancelled. Returns
        {"compose_dir": Path, "folder": str} or None (Esc)."""
        env_dirs = launcher.discover_env_dirs()
        if not env_dirs:
            self.message = "⚠️  No docker-compose files found — nothing to pick from."
            return None

        names = [d.name for d in env_dirs]
        idx = names.index(self.env) if self.env in names else 0
        folder = self.target_dir
        focus = "type"

        stdscr.timeout(100)
        try:
            while True:
                self._draw_new_stack_modal(stdscr, names, idx, folder, focus)
                key = _read_key(stdscr)
                if key == -1:
                    continue
                if key == 27:
                    return None
                if key == 9:  # Tab — switch between the type list and the folder field
                    focus = "folder" if focus == "type" else "type"
                elif key in (10, 13, curses.KEY_ENTER):
                    return {"compose_dir": env_dirs[idx], "folder": folder.strip() or self.target_dir}
                elif focus == "type":
                    if key == curses.KEY_UP:
                        idx = (idx - 1) % len(names)
                    elif key == curses.KEY_DOWN:
                        idx = (idx + 1) % len(names)
                else:
                    if key in (curses.KEY_BACKSPACE, 127, 8):
                        folder = folder[:-1]
                    elif 32 <= key < 127:
                        folder += chr(key)
        finally:
            curses.curs_set(0)
            stdscr.timeout(200)

    def _draw_new_stack_modal(self, stdscr, names, idx, folder, focus):
        h, w = stdscr.getmaxyx()
        box_w = max(40, min(64, w - 4))
        inner_w = box_w - 4
        n_visible = max(1, min(len(names), h - 10))
        box_h = min(7 + n_visible, h - 2)
        y0 = max(0, (h - box_h) // 2)
        x0 = max(0, (w - box_w) // 2)

        _draw_box(stdscr, y0, x0, box_h, box_w, "New stack")

        list_top = y0 + 2
        # Keep the selection in view when the list is taller than the box.
        first = max(0, min(idx - n_visible + 1, len(names) - n_visible)) if idx >= n_visible else 0
        for i, name in enumerate(names[first : first + n_visible]):
            line_i = first + i
            cursor = "→ " if line_i == idx else "  "
            if line_i == idx:
                attr = curses.A_REVERSE if focus == "type" else (curses.color_pair(4) | curses.A_BOLD)
            else:
                attr = curses.A_NORMAL
            _safe_addnstr(stdscr, list_top + i, x0 + 2, f"{cursor}{name}", inner_w, attr)

        folder_row = list_top + n_visible + 1
        label = "Folder: "
        _safe_addnstr(stdscr, folder_row, x0 + 2, label, inner_w)
        field_w = max(1, inner_w - len(label))
        field_attr = curses.A_UNDERLINE | (curses.A_REVERSE if focus == "folder" else 0)
        _safe_addnstr(stdscr, folder_row, x0 + 2 + len(label), folder[-field_w:], field_w, field_attr)

        hint_row = min(folder_row + 2, y0 + box_h - 2)
        hint = "↑/↓ pick type · Tab switch field · Enter confirm · Esc cancel"
        _safe_addnstr(stdscr, hint_row, x0 + 2, hint, inner_w, curses.color_pair(3) | curses.A_DIM)

        if focus == "folder":
            curses.curs_set(1)
            cursor_x = x0 + 2 + len(label) + min(len(folder), field_w)
            try:
                stdscr.move(folder_row, cursor_x)
            except curses.error:
                pass
        else:
            curses.curs_set(0)
        stdscr.refresh()

    def _show_output_modal(self, stdscr, title, text):
        """A centered, scrollable modal for showing captured subprocess output (e.g. 'd'
        delete's `docker compose down -v` result) instead of a one-line footer message or
        letting the subprocess print straight to the real terminal underneath curses (which
        is what corrupted the Stacks tab's view before teardown's output was captured —
        see launcher._teardown). Blocks until dismissed (Enter/Esc/q)."""
        lines = text.splitlines() or ["(no output)"]
        offset = 0

        stdscr.timeout(100)
        try:
            while True:
                h, w = stdscr.getmaxyx()
                box_w = max(40, min(100, w - 4))
                inner_w = box_w - 4
                box_h = max(8, min(h - 2, 20))
                inner_h = max(1, box_h - 5)
                y0 = max(0, (h - box_h) // 2)
                x0 = max(0, (w - box_w) // 2)

                _draw_box(stdscr, y0, x0, box_h, box_w, title)

                max_offset = max(0, len(lines) - inner_h)
                offset = max(0, min(offset, max_offset))
                for i, ln in enumerate(lines[offset : offset + inner_h]):
                    if "FAILED" in ln:
                        line_attr = curses.color_pair(2) | curses.A_BOLD
                    elif ln.startswith("[ok]"):
                        line_attr = curses.color_pair(1) | curses.A_BOLD
                    else:
                        line_attr = curses.A_NORMAL
                    _safe_addnstr(stdscr, y0 + 2 + i, x0 + 2, ln, inner_w, line_attr)

                hint = "↑/↓ scroll · Enter/Esc/q close" if len(lines) > inner_h else "Enter/Esc/q close"
                _safe_addnstr(stdscr, y0 + box_h - 2, x0 + 2, hint, inner_w, curses.color_pair(3) | curses.A_DIM)
                stdscr.refresh()

                key = _read_key(stdscr)
                if key == -1:
                    continue
                if key in (10, 13, curses.KEY_ENTER, 27, ord("q"), ord("Q")):
                    return
                if key == curses.KEY_UP:
                    offset -= 1
                elif key == curses.KEY_DOWN:
                    offset += 1
        finally:
            stdscr.timeout(200)

    def _toggle_selected_stack(self, stdscr):
        """'s': stop the whole selected stack if its container is running, start it otherwise —
        every container in the project, nothing deleted (that's 'd'). Unlike 'a'/'b', which
        only touch the proxy. Blocking (`docker stop` can take a few seconds), so the footer
        says what's happening before the call."""
        s = self._selected_stack()
        if not s:
            return
        h, w = stdscr.getmaxyx()
        stopping = s["container_state"] == "running"
        verb = "Stopping" if stopping else "Starting"
        _safe_addnstr(stdscr, h - 1, 0, f"⏳ {verb} '{s['env']}' (project {s['project']}) …".ljust(w - 1), w - 1, curses.color_pair(4) | curses.A_BOLD)
        stdscr.refresh()
        ok = launcher.stop_stack(s["project"]) if stopping else launcher.start_stack(s["project"])
        self.refresh()
        if stopping:
            self.message = f"⏹️  Stopped '{s['env']}' — 's' starts it again." if ok else f"⚠️  Failed to stop '{s['env']}'."
        else:
            self.message = f"▶️  Started '{s['env']}'." if ok else f"⚠️  Failed to start '{s['env']}' — see docker logs."

    def _set_selected_proxy(self, start):
        """'a'/'b': start/stop only the selected stack's proxy (stopping it blocks that
        stack's egress until started again)."""
        s = self._selected_stack()
        if not s:
            return
        name = s["env"]
        if not s["proxy_cid"]:
            self.message = f"⚠️  '{name}' has no proxy container."
            return
        if (s["status"] == "RUNNING") == start:
            self.message = f"ℹ️  '{name}' is already {'running' if start else 'stopped'}."
            return
        ok = docker("start" if start else "stop", s["proxy_cid"]).returncode == 0
        self.refresh()
        if not ok:
            self.message = f"⚠️  Failed to {'start' if start else 'stop'} proxy for '{name}'."
        elif start:
            self.message = f"✅ Started proxy for '{name}'."
        else:
            self.message = f"🚫 Stopped proxy for '{name}' — its egress is blocked until started again."

    def _footer_choice(self, stdscr, prompt, keys, attr):
        """Show `prompt` on the footer row and block for one of `keys` (lowercase chars) or a
        bare Esc. Returns the chosen char, or None on Esc."""
        h, w = stdscr.getmaxyx()
        _safe_addnstr(stdscr, h - 1, 0, prompt[: w - 1].ljust(w - 1), w - 1, attr)
        stdscr.refresh()
        stdscr.timeout(-1)  # block for the choice — resumed by the caller's loop afterward
        try:
            while True:
                key = _getch(stdscr)
                if key == 27:  # bare Esc — no arrow-sequence follow-up expected here
                    return None
                if 0 <= key < 256 and chr(key).lower() in keys:
                    return chr(key).lower()
        finally:
            stdscr.timeout(200)

    def _delete_selected_stack(self, stdscr):
        """'d': the same teardown as `dev stop`/`run.py stop` (containers, networks, and
        anonymous volumes removed) — unlike 'b', which only stops the proxy container and
        leaves everything else in place. Destructive and irreversible, so it asks for
        confirmation first (bare Esc — no arrow-sequence follow-up expected here)."""
        s = self._selected_stack()
        if not s:
            return
        prompt = f"Delete stack '{s['env']}' (project {s['project']})? Removes containers, networks & volumes.  [y] confirm   [Esc] cancel"
        if self._footer_choice(stdscr, prompt, "yn", curses.color_pair(2) | curses.A_BOLD) != "y":
            self.message = "Cancelled."
            return

        with _quiet_stdout():
            results = launcher.teardown_stack(s["project"])
        if self.project == s["project"]:
            self.cid, self.project, self.env, self.workspace = None, None, None, None
        self.refresh()

        ok = bool(results) and all(r["ok"] for r in results)
        self.message = (
            f"🗑️  Deleted stack '{s['env']}' (project {s['project']})." if ok
            else f"⚠️  Problem tearing down '{s['env']}' — see output."
        )
        body = "\n\n".join(
            f"[{'ok' if r['ok'] else 'FAILED'}] {r['project']} (in {r['workdir']})\n{r['output'] or '(no output)'}"
            for r in results
        ) or "(no output)"
        self._show_output_modal(stdscr, f"docker compose down -v — {s['env']}", body)

    # -- Domains tab --------------------------------------------------------
    def _allow_selected(self):
        r = self._selected(TAB_DOMAINS)
        if not r:
            return
        if r["verdict"] != "BLOCKED":
            self.message = f"ℹ️  '{r['host']}' is already allowed."
            return
        with _quiet_stdout():
            do_allow_domain(r["host"])
        self.refresh()
        self.message = f"✅ Allowed '{r['host']}' (local.txt — not tracked by git)."

    def _block_selected_domain(self):
        r = self._selected(TAB_DOMAINS)
        if not r:
            return
        if r["verdict"] != "ALLOWED":
            self.message = f"ℹ️  '{r['host']}' is already blocked."
            return
        with _quiet_stdout():
            ok = do_block_domain(r["host"])
        self.refresh()
        self.message = f"🚫 Blocked '{r['host']}'." if ok else f"⚠️  '{r['host']}' isn't a literal entry — covered by a wildcard."

    # -- Global/Custom Whitelist tabs ------------------------------------------
    def _remove_selected_entry(self, tab):
        """Shared by both whitelist tabs' 'b' — each tab's rows already only ever contain
        entries from that tab's own file(s) (tracked files for TAB_WHITELIST, local.txt for
        TAB_CUSTOM — see read_global_whitelist_entries/read_custom_whitelist_entries), so the
        domain being removed is always scoped correctly by virtue of which tab it was
        selected in."""
        e = self._selected(tab)
        if not e:
            return
        domain = e["domain"]
        with _quiet_stdout():
            do_block_domain(domain)
        self.refresh()
        self.message = f"🚫 Removed '{domain}'."

    # -- Access log tab -----------------------------------------------------
    def _clear_log(self):
        ok = docker("exec", "-u", "root", self.cid, "sh", "-c", ": > /var/log/squid/access.log").returncode == 0
        self.refresh()
        self.log_offset = 0
        self.message = "🧹 Cleared access.log." if ok else "⚠️  Failed to clear access.log."

    def _prompt_text(self, stdscr, prompt):
        """Blocking single-line text prompt on the footer row — shared by _prompt_new_domain
        and _prompt_new_global_domain. Returns the typed, stripped string, or "" on Esc/empty."""
        h, w = stdscr.getmaxyx()
        _safe_addnstr(stdscr, h - 1, 0, prompt[: w - 1].ljust(w - 1), w - 1)
        stdscr.refresh()

        curses.curs_set(1)
        curses.echo()
        stdscr.timeout(-1)  # block while typing — resumed by the caller's loop afterward
        try:
            raw = stdscr.getstr(h - 1, len(prompt), max(1, w - len(prompt) - 1))
            return raw.decode(errors="replace").strip()
        except Exception:
            return ""
        finally:
            curses.noecho()
            curses.curs_set(0)
            stdscr.timeout(200)

    def _prompt_new_domain(self, stdscr):
        """Custom Whitelist tab's 'n' — always local.txt, no further prompt needed since
        there's only one possible target file."""
        domain = self._prompt_text(stdscr, "New domain for local.txt (Enter to confirm, Esc to cancel): ")
        if not domain:
            return
        with _quiet_stdout():
            do_allow_domain(domain)
        self.refresh()
        self.message = f"✅ Added '{domain}' to local.txt (not tracked by git)."

    def _prompt_new_global_domain(self, stdscr):
        """Global Whitelist tab's 'n' — deliberately edits a TRACKED whitelist file. Asks for
        the domain, then whether it belongs in the shared 00-common.txt (every environment)
        or this stack's own <env>-toolbelt.txt — picking wrong silently over- or under-shares
        a domain, so this is a required step rather than a default."""
        domain = self._prompt_text(stdscr, "New domain for the GLOBAL whitelist (Enter to confirm, Esc to cancel): ")
        if not domain:
            return

        prompt = f"Add '{domain}' to:  [c] 00-common.txt (every environment)"
        if self.env:
            prompt += f"   [s] {self.env}.txt (this one only)"
        choice = self._footer_choice(stdscr, prompt + "   [Esc] cancel", "cs" if self.env else "c", curses.color_pair(3) | curses.A_BOLD)
        if choice is None:
            self.message = "Cancelled."
            return

        target_env = self.env if choice == "s" else None
        with _quiet_stdout():
            do_allow_domain_global(domain, target_env)
        self.refresh()
        dest = "00-common.txt" if target_env is None else f"{target_env}.txt"
        self.message = f"✅ Added '{domain}' to {dest} (tracked — remember to commit it)."


_ARROW_BY_FINAL_BYTE = {
    ord("A"): curses.KEY_UP,
    ord("B"): curses.KEY_DOWN,
    ord("C"): curses.KEY_RIGHT,
    ord("D"): curses.KEY_LEFT,
}


class _TerminalGone(Exception):
    """The controlling terminal went away (window closed, SSH dropped) — see _getch."""


def _tty_hung_up():
    """True if stdin's tty is dead: readable but yields EOF/EIO. A real pending byte (an
    unlikely race with curses' own read) is pushed back with ungetch rather than lost."""
    fd = sys.stdin.fileno()
    try:
        ready, _, _ = select.select([fd], [], [], 0)
        if not ready:
            return False
        data = os.read(fd, 1)
    except OSError:
        return True
    if not data:
        return True
    curses.ungetch(data[0])
    return False


def _getch(stdscr):
    """stdscr.getch() that notices a vanished terminal. Once the tty is gone, getch() stops
    honoring its timeout and returns -1 instantly, forever — so every `if key == -1:
    continue` loop in this module spun at ~100% CPU after the terminal window was closed
    (seen for real: orphaned `run.py` processes pegging a core each). A -1 that came back
    far sooner than any timeout we set (100/200ms, or blocking) triggers a real check."""
    start = time.monotonic()
    key = stdscr.getch()
    if key == -1 and time.monotonic() - start < 0.01 and _tty_hung_up():
        raise _TerminalGone()
    return key


def _read_key(stdscr):
    """stdscr.getch() wrapper that manually reassembles `ESC [ <letter>` arrow-key
    sequences. With stdscr.timeout() set (needed here for the idle refresh tick), ncurses'
    own keypad(True) escape-sequence disambiguation does not reliably combine them into
    KEY_UP/KEY_DOWN/KEY_LEFT/KEY_RIGHT in this environment — confirmed via an isolated
    repro (arrow key arrives as three separate getch() calls: 27, '[', then the final
    letter) that persisted even after curses.set_escdelay(). This reassembly is the actual
    fix; a bare lone ESC (nothing follows within the timeout window) is returned as-is.
    """
    key = _getch(stdscr)
    if key != 27:
        return key
    k2 = _getch(stdscr)
    if k2 != ord("["):
        return key if k2 == -1 else k2
    k3 = _getch(stdscr)
    return _ARROW_BY_FINAL_BYTE.get(k3, key)


def run_app(stdscr, cid, env, project, workspace, target_dir):
    curses.curs_set(0)
    # ncurses waits ESCDELAY (default 1s) after a bare Esc for a possible escape sequence,
    # which made Esc at every prompt/modal feel laggy. Arrow keys don't depend on it: their
    # bytes arrive together, and _read_key reassembles `ESC [ <letter>` itself anyway.
    if hasattr(curses, "set_escdelay"):  # Python 3.9+
        curses.set_escdelay(25)
    try:
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)   # good/running/allowed
        curses.init_pair(2, curses.COLOR_RED, -1)      # bad/stopped/blocked/denied
        curses.init_pair(3, curses.COLOR_CYAN, -1)     # structural chrome: titles, headers, tab bar, dividers
        curses.init_pair(4, curses.COLOR_YELLOW, -1)   # accents: markers, wildcards, call-to-action rows
    except curses.error:
        pass  # terminal without color support — fall back to no color, still usable
    stdscr.timeout(200)

    app = OverviewApp(cid, env, project, workspace, target_dir)
    app.refresh()

    while True:
        if time.time() - app.last_refresh >= 2:
            app.refresh()
        app.draw(stdscr)

        key = _read_key(stdscr)
        if key == -1:
            continue
        if not app.handle_key(stdscr, key):
            break

    return app.pending_action


def cmd_overview(target, follow, rebuild=False, debug=False):
    """The default `run.py` entry point (no subcommand). `dev`/`run.py` is invoked from all
    over the place, so `target` (the directory it was invoked from) only matters for: (a)
    picking which existing stack is initially "active" for the Domain Statistics/Global
    Whitelist/Custom Whitelist/Access log tabs, if any exists for this exact directory, and
    (b) where a brand-new environment gets
    created when the Stacks tab's 'n' action is used. It does NOT filter which existing
    stacks the Stacks tab lists — that's always every stack on the host, any directory."""
    project, env, workspace, cid = None, None, None, None

    resolved = resolve_stack(target, required=False)
    if resolved:
        project, env, workspace = resolved
        cid = proxy_cid_for_project(project)

    if not cid:
        for s in list_all_stacks():
            if s["proxy_cid"]:
                project, env, workspace, cid = s["project"], s["env"], s["workspace"], s["proxy_cid"]
                break

    if follow:
        if not cid:
            die("No devcontainer stacks found anywhere yet — run without -f for the interactive Stacks tab.")
        run_follow(cid, env, project, workspace)
        return

    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        if not cid:
            die("No devcontainer stacks found anywhere yet — run interactively for the Stacks tab.")
        run_snapshot(cid, env, project, workspace)
        return

    # Closing the terminal must end the app. SIGHUP is set explicitly in case it was inherited
    # as ignored; _getch covers terminals that vanish without delivering one at all.
    def _on_hangup(signum, frame):
        raise _TerminalGone()
    signal.signal(signal.SIGHUP, _on_hangup)

    # 'o'/'n' tear curses down (a real interactive zsh session can't run inside its alternate
    # screen) and hand the request back here; start_and_open_shell then exec's into the shell,
    # replacing this process. Exiting the shell drops the user back into their own terminal
    # rather than into the TUI again — bare `dev` reopens it when it's actually wanted.
    try:
        pending = curses.wrapper(run_app, cid, env, project, workspace, target)
    except _TerminalGone:
        os._exit(129)  # nothing left to draw to or clean up on — 128 + SIGHUP
    except curses.error:
        # curses.wrapper's endwin() on a dead tty raises too, masking the _TerminalGone.
        if not os.isatty(sys.stdin.fileno()) or select.select([sys.stdin], [], [], 0)[0]:
            os._exit(129)
        raise
    if not pending:
        return
    action, row = pending
    if action == "open_shell":
        launcher.start_and_open_shell(REPO_ROOT / row["env"], row["workspace"], rebuild, debug)
    else:
        launcher.start_and_open_shell(row["compose_dir"], row["folder"], rebuild, debug)
