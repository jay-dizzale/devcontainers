"""devtool/proxy.py — the two-pane app that bare `run.py` launches by default: Stacks
permanently on the left (1/3 width), proxy settings (Domains/Whitelist/Access log, their own
small sub-tab bar) permanently on the right (2/3 width). There is no separate `proxy`
subcommand anymore. The Stacks pane lists every devcontainer stack that already exists,
host-wide (`dev`/`run.py` gets invoked from all over the place, so this is never scoped to
"the current directory") — `o` on a row opens a shell in it (building/starting first if
needed), `n` starts a brand-new environment for the directory `run.py` was invoked from (the
plain-text picker that used to be bare `run.py`'s whole job). Both tear the TUI down first
since a real interactive zsh session can't run inside curses' alternate screen. start/stop/
clear-log/allow are actions inside whichever pane/sub-tab is focused (Stacks for start/stop,
Access log for clear, Whitelist for allow), so there's exactly one thing to remember how to
invoke: `run.py`.

Moved here from common/proxy/ctl.py when `run.sh`/`setup.sh` were rewritten as the unified
`devtool` package + `run.py` — `common/` stays container-build/runtime material only (the
Squid sidecar's Dockerfile/squid.conf/entrypoint.sh/whitelist.d/ are still there), while this
host-side CLI module lives alongside the rest of the Python tool. `run.py`'s dispatcher
(devtool/cli.py) calls cmd_overview() directly in-process — no subprocess exec, no env-var
indirection needed to cross a shell/Python boundary like the old ctl.py had to.

Stdlib only (subprocess/curses — no pip install, no `docker` SDK). All Docker interaction
shells out to the `docker` CLI, mirroring what a hand-rolled POSIX-sh version did before this
— ported to Python specifically because that shell version hit two real cross-platform bugs on
macOS (an `awk -v` call with an embedded multi-line value failing on macOS's default awk but
not gawk; `sed -i` needing a different flag form on BSD vs. GNU sed) and had an unverified
third risk (hand-parsed arrow-key escape sequences, which aren't identical across every
terminal). Python + the stdlib `curses` module removes all three risk classes structurally: no
awk/sed of any kind is used here, and curses normalizes arrow-key input across terminals
itself.

See AGENTS.md's "Egress proxy and domain whitelist" section for the full architecture this
is one piece of.
"""
import contextlib
import curses
import io
import sys
import time
from pathlib import Path

from . import launcher
from .docker_utils import REPO_ROOT, die, docker, docker_out, proxy_cid_for_project, resolve_stack

WHITELIST_DIR = REPO_ROOT / "common" / "proxy" / "whitelist.d"


def list_all_stacks():
    """One row per devcontainer stack found on the host — any directory, not just the one
    `run.py` happens to be invoked from this time (`dev` is run from all over the place).
    project, env, workspace, and its proxy container's id + status (RUNNING/STOPPED). Backs
    the Stacks tab, which lets the user switch which stack the other tabs operate on, open a
    shell in any of them (`o`), and start/stop any stack's proxy — all without first `cd`-ing
    into its workspace. Starting a brand-new environment is a separate action (`n`, see
    OverviewApp._new_stack), not a row here — this only ever lists what already exists."""
    # Two bulk `docker ps --format` calls total, however many stacks exist — not one
    # `inspect`/`ps` round-trip per stack. `docker ps --format` can read a specific label
    # (`.Label "key"`) and the container's live state (`.State`) directly off the `ps` table
    # itself, so neither loop below needs a follow-up `docker inspect` per row.
    dev_fmt = (
        '{{.Label "com.docker.compose.project"}}|'
        '{{.Label "devcontainer.env"}}|'
        '{{.Label "devcontainer.workspace"}}'
    )
    seen = {}
    for line in docker_out("ps", "-a", "--filter", "label=devcontainer.env", "--format", dev_fmt).splitlines():
        if line.count("|") != 2:
            continue
        project, env, workspace = line.split("|", 2)
        if project:
            seen[project] = (env, workspace)

    proxy_fmt = '{{.Label "com.docker.compose.project"}}|{{.ID}}|{{.State}}'
    proxy_by_project = {}
    for line in docker_out("ps", "-a", "--filter", "label=com.docker.compose.service=proxy", "--format", proxy_fmt).splitlines():
        parts = line.split("|", 2)
        if len(parts) != 3 or not parts[0]:
            continue
        project, cid, state = parts
        proxy_by_project[project] = (cid, state == "running")

    stacks = []
    for project, (env, workspace) in sorted(seen.items()):
        proxy_cid, running = proxy_by_project.get(project, (None, False))
        stacks.append({
            "project": project,
            "env": env,
            "workspace": workspace,
            "proxy_cid": proxy_cid,
            "status": "RUNNING" if running else "STOPPED",
        })

    return stacks


def restart_running_proxies():
    """Restarts every currently-running proxy container so a whitelist edit applies
    immediately. The `proxy` service carries no `devcontainer.env` label of its own (only
    `dev` does), so this filters on the compose service name, then double-checks each match's
    config-files label actually includes our proxy.docker-compose.yml, so an unrelated
    project's own "proxy" service (if one somehow exists on the host) is never touched."""
    cids = docker_out("ps", "-q", "--filter", "label=com.docker.compose.service=proxy").split()
    running = []
    for cid in cids:
        cfg = docker_out("inspect", cid, "--format", '{{index .Config.Labels "com.docker.compose.project.config_files"}}')
        if "common/proxy.docker-compose.yml" in cfg:
            running.append(cid)

    if not running:
        print("ℹ️  No running proxy containers right now — the change applies the next time a stack starts.")
        return

    print("🔁 Restarting running proxy container(s) so the change takes effect ...")
    for cid in running:
        workdir = docker_out("inspect", cid, "--format", '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')
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
    out = []
    for line in path.read_text().splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            out.append(s)
    return out


def read_whitelist_entries():
    """All configured domains across every whitelist.d/*.txt — for the Whitelist tab. Includes
    domains never yet requested (unlike the access-log-derived Domains tab rows). Each entry
    carries a `group` ("common" for 00-common.txt, "specific" for every per-toolbelt file) so
    the tab can draw them as two visually separated sections rather than one flat,
    alphabetically-interleaved list — sorting puts every "common" entry before any "specific"
    one, domain-alphabetical within each group."""
    entries = []
    for f in whitelist_files():
        group = "common" if f.name == "00-common.txt" else "specific"
        for domain in read_domains(f):
            entries.append({"domain": domain, "file": f.name, "wildcard": domain.startswith("."), "group": group})
    entries.sort(key=lambda e: (0 if e["group"] == "common" else 1, e["domain"]))
    return entries


def do_allow_domain(domain, env=None):
    if env:
        target = WHITELIST_DIR / f"{env}.txt"
        if not target.exists():
            die(f"No whitelist file for '{env}' — expected {target} (name matches the toolbelt directory, e.g. java-toolbelt)")
    else:
        target = WHITELIST_DIR / "00-common.txt"

    hits = [f for f in whitelist_files() if domain in read_domains(f)]
    if hits:
        names = " ".join(f.name for f in hits)
        print(f"ℹ️  '{domain}' is already whitelisted (in {names}).")
    else:
        with target.open("a") as fh:
            fh.write(domain + "\n")
        print(f"✅ Added '{domain}' to {target.name}.")
    restart_running_proxies()


def do_block_domain(domain):
    """Removes a domain from EVERY whitelist.d/*.txt file that lists it exactly (it can be
    covered by more than one — e.g. a shared Apache mirror both java-toolbelt.txt and
    infrastructure-toolbelt.txt list). No-op, clearly reported, if the domain isn't literally
    listed anywhere — e.g. it's only reachable via a broader pattern like the leading-dot
    .amazonaws.com wildcard, which has to be edited by hand."""
    hits = [f for f in whitelist_files() if domain in read_domains(f)]
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
# access.log / live-whitelist parsing — for Tab 1 (per-domain) and Tab 3 (raw).
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
    out = docker_out("exec", cid, "cat", "/etc/squid/whitelist.txt")
    exact, wildcards = set(), []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("."):
            wildcards.append(line)
        else:
            exact.add(line)
    return exact, wildcards


def is_allowed(host, exact, wildcards):
    if host in exact:
        return True
    return any(host.endswith(w) for w in wildcards)


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
        code = parts[3].split("/")[0]
        method = parts[5]
        url = parts[6]
        host = extract_host(url)
        if not host:
            continue
        rows.append({"ts": ts, "code": code, "method": method, "url": url, "host": host})
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
# The bare `proxy` command — three modes: piped/non-tty snapshot, passive --follow, or the
# interactive 4-tab curses app.
# ---------------------------------------------------------------------------
def format_domain_table(rows):
    lines = [f"   {'DOMAIN':<40} {'HITS':>6}  {'STATUS':<9} LAST SEEN"]
    now = time.time()
    for r in rows:
        ago = int(now - r["last"])
        lines.append(f"   {r['host']:<40} {r['count']:>6}  {r['verdict']:<9} {ago}s ago")
    return lines


def run_snapshot(cid, env, project, workspace):
    rows = fetch_domain_rows(cid)
    print(f"📡 Egress overview — '{env}' (project {project}, {workspace})  [{time.strftime('%H:%M:%S')}]")
    print()
    if not rows:
        print("   (no traffic logged yet)")
    else:
        print("\n".join(format_domain_table(rows)))
    print()
    try:
        new_domain = input(f"➕ Add a domain to '{env}'s whitelist (Enter to skip): ").strip()
    except EOFError:
        new_domain = ""
    if new_domain:
        do_allow_domain(new_domain, env)


def run_follow(cid, env, project, workspace):
    try:
        while True:
            rows = fetch_domain_rows(cid)
            print("\033[2J\033[H", end="")
            print(f"📡 Egress overview — '{env}' (project {project}, {workspace})  [{time.strftime('%H:%M:%S')}]")
            print()
            if not rows:
                print("   (no traffic logged yet)")
            else:
                print("\n".join(format_domain_table(rows)))
            print()
            print("(Ctrl-C to stop watching)")
            sys.stdout.flush()
            time.sleep(2)
    except KeyboardInterrupt:
        print()
        print("👋 Stopped watching.")


TAB_STACKS, TAB_DOMAINS, TAB_WHITELIST, TAB_LOG = range(4)

# The right-hand "proxy settings" pane keeps its own small sub-tab bar — Stacks is no longer
# one of the four tabs, it's the permanent left pane (see OverviewApp.draw).
PROXY_TABS = [TAB_DOMAINS, TAB_WHITELIST, TAB_LOG]
PROXY_TAB_TITLES = [" 1:Domains ", " 2:Whitelist ", " 3:Access log "]


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


class OverviewApp:
    """The interactive curses app behind the bare `proxy` command: a permanent two-pane
    split — Stacks always visible on the left 1/3, the proxy settings (Domains/Whitelist/
    Access log, switchable via their own sub-tab bar) on the right 2/3. Exactly one pane has
    input focus at a time (self.focus); Tab/←/→ moves focus between the two panes."""

    def __init__(self, cid, env, project, workspace, target_dir):
        self.cid = cid
        self.env = env
        self.project = project
        self.workspace = workspace
        self.target_dir = target_dir  # fixed: where 'n' (new stack) builds/starts into
        self.focus = "stacks"         # "stacks" (left pane) or "proxy" (right pane)
        self.proxy_tab = TAB_DOMAINS  # which sub-tab the right pane currently shows
        self.idx = [0, 0, 0, 0]       # selected row, per tab (log tab unused — it scrolls)
        self.scroll = [0, 0, 0]       # stacks/domains/whitelist: first visible row (viewport top)
        self.log_offset = 0           # log tab: 0 = pinned to newest ("following")
        self.rows = [[], [], [], []]
        self.message = ""
        self.last_refresh = 0.0
        self.pending_action = None    # set by 'o' (open shell) — breaks the main loop to act on

    def current_tab(self):
        """Which tab's rows/selection respond to ↑/↓ and action keys right now — the
        focused pane's tab (Stacks for the left pane, whichever sub-tab is showing for the
        right pane)."""
        return TAB_STACKS if self.focus == "stacks" else self.proxy_tab

    def _pane_pos(self):
        """Linear position along Stacks(0) → Domains(1) → Whitelist(2) → Access log(3), so
        ←/→ can walk through all four one step at a time — all the way right into the last
        sub-tab, then back out to Stacks by going left — instead of only toggling between
        the two panes."""
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
        self.rows[TAB_STACKS] = list_all_stacks()
        log_rows = parse_access_log(self.cid) if self.cid else []
        self.rows[TAB_LOG] = log_rows
        self.rows[TAB_DOMAINS] = fetch_domain_rows(self.cid, log_rows) if self.cid else []
        self.rows[TAB_WHITELIST] = read_whitelist_entries()
        self.last_refresh = time.time()
        for i in (TAB_DOMAINS, TAB_WHITELIST):
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
        stdscr.addnstr(0, 0, sep[:w], w, curses.A_BOLD)

        credit = " made by jay-dizzale 🐳 "
        if len(credit) < w:
            stdscr.addnstr(0, w - len(credit), credit, len(credit), curses.A_DIM)

        left_w = max(18, w // 3)
        divider_x = min(left_w, w - 1)
        right_x = divider_x + 1
        right_w = max(5, w - right_x)

        stacks_attr = curses.A_REVERSE if self.focus == "stacks" else curses.A_BOLD
        stdscr.addnstr(1, 0, " STACKS ".ljust(left_w), left_w, stacks_attr)

        proxy_attr = curses.A_REVERSE if self.focus == "proxy" else curses.A_BOLD
        stdscr.addnstr(1, right_x, " PROXY ".ljust(right_w), max(0, right_w), proxy_attr)

        x = right_x
        for tab_const, title in zip(PROXY_TABS, PROXY_TAB_TITLES):
            focused_here = self.focus == "proxy" and tab_const == self.proxy_tab
            attr = curses.A_REVERSE if focused_here else curses.A_NORMAL
            stdscr.addnstr(2, x, title, max(0, right_x + right_w - x), attr)
            x += len(title) + 1

        body_top = 4
        body_h = h - body_top - 2
        for y in range(1, body_top + body_h):
            try:
                stdscr.addch(y, divider_x, "│")
            except curses.error:
                pass  # bottom-right-cell write restriction — harmless to skip

        self._draw_stacks_tab(stdscr, body_top, body_h, 0, left_w)

        if self.proxy_tab == TAB_DOMAINS:
            self._draw_domain_tab(stdscr, body_top, body_h, right_x, right_w)
        elif self.proxy_tab == TAB_WHITELIST:
            self._draw_whitelist_tab(stdscr, body_top, body_h, right_x, right_w)
        else:
            self._draw_log_tab(stdscr, body_top, body_h, right_x, right_w)

        footer = self.message or self._footer_hint()
        stdscr.addnstr(h - 1, 0, footer[: w - 1], w - 1)
        stdscr.refresh()

    def _footer_hint(self):
        common = "←/→ move · Tab jump pane · q quit"
        tab = self.current_tab()
        if tab == TAB_STACKS:
            return f"↑/↓ select · o open shell · n new stack · Enter switch/new · a start proxy · b stop proxy · d delete stack · {common}"
        sub = "1/2/3 sub-tab · "
        if tab == TAB_DOMAINS:
            return f"↑/↓ select · a allow · b block · {sub}{common}"
        if tab == TAB_WHITELIST:
            return f"↑/↓ select · b remove · n new domain · {sub}{common}"
        return f"↑/↓ scroll · c clear log · {sub}{common}"

    def _visible_window(self, tab, n_rows, height, lines_per_row=1):
        """Clamp-to-view scrolling: keeps self.idx[tab] inside [scroll, scroll+visible)
        by adjusting self.scroll[tab], then returns (start, visible) for the caller to
        slice rows[start:start+visible]. Without this, a selection moved past the first
        screenful of rows was simply never drawn — the row count and height could each
        change between calls (fresh traffic, terminal resize), so both are re-clamped
        every draw rather than cached. `lines_per_row` lets a caller whose entries span
        several terminal lines (the Stacks tab's 3-line-per-stack layout) count scroll
        position in entries while still budgeting the right number of terminal rows."""
        visible = max(1, (height - 1) // lines_per_row)
        scroll = self.scroll[tab]
        idx = self.idx[tab]
        if idx < scroll:
            scroll = idx
        elif idx >= scroll + visible:
            scroll = idx - visible + 1
        scroll = max(0, min(scroll, max(0, n_rows - visible)))
        self.scroll[tab] = scroll
        return scroll, visible

    _STACK_ENTRY_LINES = 5  # bordered card: top border, type/status, id, workspace, bottom border

    def _draw_stacks_tab(self, stdscr, top, height, x0, w):
        """The list always has one extra trailing row — "+ New stack" — past the real stacks,
        so starting a new one is just another list item (Enter on it) rather than only a
        separate key ('n' still works too, from anywhere in this pane). Each stack is its own
        bordered card (type/status, stack id, workspace folder) rather than a plain row, for
        visual separation in the narrow left pane. Selection reverses only the card's border —
        reversing the content too (status colors, dimmed id/workspace) looked noisy."""
        rows = self.rows[TAB_STACKS]
        stdscr.addnstr(top, x0 + 2, f"{'TYPE':<20} STATUS", max(0, w - 2), curses.A_UNDERLINE)
        total = len(rows) + 1
        lines = self._STACK_ENTRY_LINES
        start, visible = self._visible_window(TAB_STACKS, total, height, lines_per_row=lines)
        card_w = max(4, w - 3)

        for row_i in range(start, min(start + visible, total)):
            y = top + 1 + (row_i - start) * lines
            selected = row_i == self.idx[TAB_STACKS]
            border_attr = curses.A_REVERSE if selected else curses.A_NORMAL
            try:
                stdscr.addnstr(y, x0 + 1, "┌" + "─" * (card_w - 2) + "┐", card_w, border_attr)
                stdscr.addnstr(y + 4, x0 + 1, "└" + "─" * (card_w - 2) + "┘", card_w, border_attr)
                for ln in range(1, 4):
                    stdscr.addch(y + ln, x0 + 1, "│", border_attr)
                    stdscr.addch(y + ln, x0 + card_w, "│", border_attr)
            except curses.error:
                pass  # card clipped by the pane edge — harmless to skip

            if row_i == len(rows):
                stdscr.addnstr(y + 2, x0 + 3, "+ New stack", max(0, card_w - 4), curses.A_BOLD)
                continue

            s = rows[row_i]
            marker = "➤" if s["project"] and s["project"] == self.project else " "
            # Content attrs never change with selection — only the border (above) does, so
            # the highlight reads as "this card" rather than painting the text too.
            main_attr = curses.color_pair(1) if s["status"] == "RUNNING" else curses.color_pair(2)
            detail_attr = curses.A_DIM
            stdscr.addnstr(y + 1, x0 + 3, f"{marker}{s['env']:<16} {s['status']}", max(0, card_w - 4), main_attr)
            stdscr.addnstr(y + 2, x0 + 3, f"id: {s['project']}", max(0, card_w - 4), detail_attr)
            stdscr.addnstr(y + 3, x0 + 3, s["workspace"], max(0, card_w - 4), detail_attr)

    def _draw_domain_tab(self, stdscr, top, height, x0, w):
        rows = self.rows[TAB_DOMAINS]
        stdscr.addnstr(top, x0 + 2, f"{'DOMAIN':<40} {'HITS':>6}  {'STATUS':<9} LAST SEEN", max(0, w - 2), curses.A_UNDERLINE)
        if not rows:
            stdscr.addnstr(top + 2, x0 + 2, "(no traffic logged yet)", max(0, w - 2))
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
            stdscr.addnstr(y, x0 + 2, text, max(0, w - 2), attr)

    _WHITELIST_GROUP_LABEL = {
        "common": "── Common (00-common.txt — every environment) ──",
        "specific": "── Specific (per-environment whitelist.d/*.txt) ──",
    }

    def _draw_whitelist_tab(self, stdscr, top, height, x0, w):
        rows = self.rows[TAB_WHITELIST]
        stdscr.addnstr(top, x0 + 2, f"{'DOMAIN':<40} {'TYPE':<8} FILE", max(0, w - 2), curses.A_UNDERLINE)
        if not rows:
            stdscr.addnstr(top + 2, x0 + 2, "(whitelist.d has no entries)", max(0, w - 2))
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

        visible = max(1, height - 1)
        scroll = self.scroll[TAB_WHITELIST]  # here: first visible *display line*, not row
        if selected_i < scroll:
            scroll = selected_i
        elif selected_i >= scroll + visible:
            scroll = selected_i - visible + 1
        scroll = max(0, min(scroll, max(0, len(lines) - visible)))
        self.scroll[TAB_WHITELIST] = scroll

        for row_i, line in enumerate(lines[scroll : scroll + visible]):
            y = top + 1 + row_i
            if line[0] == "header":
                stdscr.addnstr(y, x0 + 2, line[1], max(0, w - 2), curses.A_DIM)
                continue
            _, e, real_i = line
            kind = "wildcard" if e["wildcard"] else "exact"
            text = f"{e['domain']:<40} {kind:<8} {e['file']}"
            attr = curses.A_REVERSE if real_i == self.idx[TAB_WHITELIST] else curses.A_NORMAL
            stdscr.addnstr(y, x0 + 2, text, max(0, w - 2), attr)

    def _draw_log_tab(self, stdscr, top, height, x0, w):
        rows = self.rows[TAB_LOG]
        if not rows:
            stdscr.addnstr(top, x0 + 2, "(no traffic logged yet)", max(0, w - 2))
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
            stdscr.addnstr(y, x0 + 2, text, max(0, w - 2), attr)
        if self.log_offset > 0:
            stdscr.addnstr(top + visible, x0 + 2, f"-- scrolled back {self.log_offset} — ↓ to catch up --", max(0, w - 2), curses.A_DIM)

    # -- input ----------------------------------------------------------
    def handle_key(self, stdscr, key):
        self.message = ""
        if key in (ord("q"), ord("Q")):
            return False
        if key == curses.KEY_RIGHT:
            self._set_pane_pos(self._pane_pos() + 1)
        elif key == curses.KEY_LEFT:
            self._set_pane_pos(self._pane_pos() - 1)
        elif key == 9:  # Tab — quick jump straight between the two panes
            self._set_pane_pos(0 if self.focus == "proxy" else 1)
        elif key in (ord("1"), ord("2"), ord("3")):
            self.focus = "proxy"
            self.proxy_tab = PROXY_TABS[key - ord("1")]
        elif key == curses.KEY_UP:
            self._move(-1)
        elif key == curses.KEY_DOWN:
            self._move(1)
        elif key in (10, 13, curses.KEY_ENTER) and self.current_tab() == TAB_STACKS:
            if self.idx[TAB_STACKS] == len(self.rows[TAB_STACKS]):  # the "+ New stack" row
                return self._new_stack(stdscr)
            self._switch_to_selected_stack()
        elif key in (ord("o"), ord("O")) and self.current_tab() == TAB_STACKS:
            return self._open_shell_selected()
        elif key in (ord("n"), ord("N")) and self.current_tab() == TAB_STACKS:
            return self._new_stack(stdscr)
        elif key in (ord("a"), ord("A")) and self.current_tab() == TAB_STACKS:
            self._start_selected_stack()
        elif key in (ord("b"), ord("B")) and self.current_tab() == TAB_STACKS:
            self._stop_selected_stack()
        elif key in (ord("d"), ord("D")) and self.current_tab() == TAB_STACKS:
            self._delete_selected_stack(stdscr)
        elif key in (ord("a"), ord("A")) and self.current_tab() == TAB_DOMAINS:
            self._allow_selected(stdscr)
        elif key in (ord("b"), ord("B")) and self.current_tab() == TAB_DOMAINS:
            self._block_selected_domain()
        elif key in (ord("b"), ord("B")) and self.current_tab() == TAB_WHITELIST:
            self._remove_selected_whitelist_entry()
        elif key in (ord("n"), ord("N")) and self.current_tab() == TAB_WHITELIST:
            self._prompt_new_domain(stdscr)
        elif key in (ord("c"), ord("C")) and self.current_tab() == TAB_LOG:
            self._clear_log()
        return True

    def _move(self, delta):
        tab = self.current_tab()
        if tab == TAB_STACKS:
            n = len(self.rows[TAB_STACKS]) + 1  # +1 for the trailing "+ New stack" row
            self.idx[TAB_STACKS] = max(0, min(n - 1, self.idx[TAB_STACKS] + delta))
        elif tab in (TAB_DOMAINS, TAB_WHITELIST):
            n = len(self.rows[tab])
            if n:
                self.idx[tab] = max(0, min(n - 1, self.idx[tab] + delta))
        else:
            n = len(self.rows[TAB_LOG])
            self.log_offset = max(0, min(max(0, n - 1), self.log_offset - delta))

    # -- Stacks tab -------------------------------------------------------
    def _selected_stack(self):
        rows = self.rows[TAB_STACKS]
        if not rows or self.idx[TAB_STACKS] >= len(rows):
            return None
        return rows[self.idx[TAB_STACKS]]

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
            return True
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
            return True
        self.pending_action = ("new_stack", choice)
        return False

    def _new_stack_modal(self, stdscr):
        """Runs its own small blocking event loop — like _prompt_new_domain/
        _prompt_new_domain_target — rather than wiring into draw()/handle_key(), since it's a
        one-shot modal that owns input until confirmed or cancelled. Returns
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

        for yy in range(box_h):
            if yy == 0:
                line = "┌" + "─" * (box_w - 2) + "┐"
            elif yy == box_h - 1:
                line = "└" + "─" * (box_w - 2) + "┘"
            else:
                line = "│" + " " * (box_w - 2) + "│"
            try:
                stdscr.addnstr(y0 + yy, x0, line, box_w)
            except curses.error:
                pass

        title = " New devcontainer stack "
        stdscr.addnstr(y0, x0 + max(1, (box_w - len(title)) // 2), title, box_w - 2, curses.A_BOLD)

        list_top = y0 + 2
        for i, name in enumerate(names[:n_visible]):
            cursor = "→ " if i == idx else "  "
            if i == idx:
                attr = curses.A_REVERSE if focus == "type" else curses.A_BOLD
            else:
                attr = curses.A_NORMAL
            stdscr.addnstr(list_top + i, x0 + 2, f"{cursor}{name}", inner_w, attr)

        folder_row = list_top + n_visible + 1
        label = "Folder: "
        stdscr.addnstr(folder_row, x0 + 2, label, inner_w)
        field_w = max(1, inner_w - len(label))
        field_attr = curses.A_UNDERLINE | (curses.A_REVERSE if focus == "folder" else 0)
        stdscr.addnstr(folder_row, x0 + 2 + len(label), folder[-field_w:], field_w, field_attr)

        hint_row = min(folder_row + 2, y0 + box_h - 2)
        hint = "↑/↓ pick type · Tab switch field · Enter confirm · Esc cancel"
        stdscr.addnstr(hint_row, x0 + 2, hint, inner_w, curses.A_DIM)

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
        see launcher._teardown_containers). Blocks until dismissed (Enter/Esc/q)."""
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

                for yy in range(box_h):
                    if yy == 0:
                        line = "┌" + "─" * (box_w - 2) + "┐"
                    elif yy == box_h - 1:
                        line = "└" + "─" * (box_w - 2) + "┘"
                    else:
                        line = "│" + " " * (box_w - 2) + "│"
                    try:
                        stdscr.addnstr(y0 + yy, x0, line, box_w)
                    except curses.error:
                        pass

                shown_title = f" {title} "
                stdscr.addnstr(y0, x0 + max(1, (box_w - len(shown_title)) // 2), shown_title, box_w - 2, curses.A_BOLD)

                max_offset = max(0, len(lines) - inner_h)
                offset = max(0, min(offset, max_offset))
                for i, ln in enumerate(lines[offset : offset + inner_h]):
                    stdscr.addnstr(y0 + 2 + i, x0 + 2, ln, inner_w)

                hint = "↑/↓ scroll · Enter/Esc/q close" if len(lines) > inner_h else "Enter/Esc/q close"
                stdscr.addnstr(y0 + box_h - 2, x0 + 2, hint, inner_w, curses.A_DIM)
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

    def _start_selected_stack(self):
        s = self._selected_stack()
        if not s:
            return
        if not s["proxy_cid"]:
            self.message = f"⚠️  '{s['env']}' has no proxy container."
            return
        if s["status"] == "RUNNING":
            self.message = f"ℹ️  '{s['env']}' is already running."
            return
        ok = docker("start", s["proxy_cid"]).returncode == 0
        self.refresh()
        self.message = f"✅ Started proxy for '{s['env']}'." if ok else f"⚠️  Failed to start proxy for '{s['env']}'."

    def _stop_selected_stack(self):
        s = self._selected_stack()
        if not s:
            return
        if not s["proxy_cid"]:
            self.message = f"⚠️  '{s['env']}' has no proxy container."
            return
        if s["status"] != "RUNNING":
            self.message = f"ℹ️  '{s['env']}' is already stopped."
            return
        ok = docker("stop", s["proxy_cid"]).returncode == 0
        self.refresh()
        self.message = (
            f"🚫 Stopped proxy for '{s['env']}' — its egress is blocked until started again."
            if ok else f"⚠️  Failed to stop proxy for '{s['env']}'."
        )

    def _delete_selected_stack(self, stdscr):
        """'d': the same teardown as `dev stop`/`run.py stop` (containers, networks, and
        anonymous volumes removed) — unlike 'b', which only stops the proxy container and
        leaves everything else in place. Destructive and irreversible, so it asks for
        confirmation first (bare Esc — no arrow-sequence follow-up expected here, same as
        _prompt_new_domain_target)."""
        s = self._selected_stack()
        if not s:
            return
        if not s["proxy_cid"]:
            self.message = f"⚠️  '{s['env']}' has no container to tear down."
            return

        h, w = stdscr.getmaxyx()
        prompt = f"Delete stack '{s['env']}' (project {s['project']})? Removes containers, networks & volumes.  [y] confirm   [Esc] cancel"
        stdscr.addnstr(h - 1, 0, " " * (w - 1), w - 1)
        stdscr.addnstr(h - 1, 0, prompt[: w - 1], w - 1, curses.A_BOLD)
        stdscr.refresh()
        stdscr.timeout(-1)
        try:
            while True:
                key = stdscr.getch()
                if key in (ord("y"), ord("Y")):
                    break
                if key in (27, ord("n"), ord("N")):
                    self.message = "Cancelled."
                    return
        finally:
            stdscr.timeout(200)

        with _quiet_stdout():
            results = launcher.teardown_stack(s["proxy_cid"])
        if self.project == s["project"]:
            self.cid, self.project, self.env, self.workspace = None, None, None, None
        self.refresh()

        ok = all(r["ok"] for r in results) if results else False
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
    def _allow_selected(self, stdscr):
        rows = self.rows[TAB_DOMAINS]
        if not rows or self.idx[TAB_DOMAINS] >= len(rows):
            return
        r = rows[self.idx[TAB_DOMAINS]]
        if r["verdict"] != "BLOCKED":
            self.message = f"ℹ️  '{r['host']}' is already allowed."
            return
        choice = self._prompt_new_domain_target(stdscr, r["host"])
        if choice is None:
            self.message = "Cancelled."
            return
        target_env = None if choice == "__common__" else choice
        with _quiet_stdout():
            do_allow_domain(r["host"], target_env)
        self.refresh()
        self.message = f"✅ Allowed '{r['host']}'."

    def _block_selected_domain(self):
        rows = self.rows[TAB_DOMAINS]
        if not rows or self.idx[TAB_DOMAINS] >= len(rows):
            return
        r = rows[self.idx[TAB_DOMAINS]]
        if r["verdict"] != "ALLOWED":
            self.message = f"ℹ️  '{r['host']}' is already blocked."
            return
        with _quiet_stdout():
            ok = do_block_domain(r["host"])
        self.refresh()
        self.message = f"🚫 Blocked '{r['host']}'." if ok else f"⚠️  '{r['host']}' isn't a literal entry — covered by a wildcard."

    # -- Whitelist tab --------------------------------------------------------
    def _remove_selected_whitelist_entry(self):
        rows = self.rows[TAB_WHITELIST]
        if not rows or self.idx[TAB_WHITELIST] >= len(rows):
            return
        domain = rows[self.idx[TAB_WHITELIST]]["domain"]
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

    def _prompt_new_domain(self, stdscr):
        h, w = stdscr.getmaxyx()
        prompt = "New domain (Enter to confirm, Esc to cancel): "
        stdscr.addnstr(h - 1, 0, " " * (w - 1), w - 1)
        stdscr.addnstr(h - 1, 0, prompt, w - 1)
        stdscr.refresh()

        curses.curs_set(1)
        curses.echo()
        stdscr.timeout(-1)  # block while typing — resumed by the caller's loop afterward
        try:
            raw = stdscr.getstr(h - 1, len(prompt), max(1, w - len(prompt) - 1))
            domain = raw.decode(errors="replace").strip()
        except Exception:
            domain = ""
        finally:
            curses.noecho()
            curses.curs_set(0)
            stdscr.timeout(200)

        if not domain:
            return

        choice = self._prompt_new_domain_target(stdscr, domain)
        if choice is None:
            self.message = "Cancelled."
            return

        target_env = None if choice == "__common__" else choice
        with _quiet_stdout():
            do_allow_domain(domain, target_env)
        self.refresh()
        dest = "00-common.txt" if target_env is None else f"{target_env}.txt"
        self.message = f"✅ Added '{domain}' to {dest}."

    def _prompt_new_domain_target(self, stdscr, domain):
        """Asks whether `domain` belongs in the shared 00-common.txt (every environment) or
        this stack's own <env>-toolbelt.txt — picking wrong silently over- or under-shares a
        domain, so this is a required step rather than a default. Returns None for common
        (matching do_allow_domain's own env=None convention), self.env for this environment's
        file, or "cancel" sentinel turned into None by the caller on Esc."""
        h, w = stdscr.getmaxyx()
        prompt = f"Add '{domain}' to:  [c] 00-common.txt (every environment)   [s] {self.env}.txt (this one only)   [Esc] cancel"
        stdscr.addnstr(h - 1, 0, " " * (w - 1), w - 1)
        stdscr.addnstr(h - 1, 0, prompt, w - 1, curses.A_BOLD)
        stdscr.refresh()

        stdscr.timeout(-1)  # block for the choice — resumed by the caller's loop afterward
        try:
            while True:
                key = stdscr.getch()
                if key in (ord("c"), ord("C")):
                    return "__common__"
                if key in (ord("s"), ord("S")):
                    return self.env
                if key == 27:  # bare Esc — no arrow-sequence follow-up expected here
                    return None
        finally:
            stdscr.timeout(200)


_ARROW_BY_FINAL_BYTE = {
    ord("A"): curses.KEY_UP,
    ord("B"): curses.KEY_DOWN,
    ord("C"): curses.KEY_RIGHT,
    ord("D"): curses.KEY_LEFT,
}


def _read_key(stdscr):
    """stdscr.getch() wrapper that manually reassembles `ESC [ <letter>` arrow-key
    sequences. With stdscr.timeout() set (needed here for the idle refresh tick), ncurses'
    own keypad(True) escape-sequence disambiguation does not reliably combine them into
    KEY_UP/KEY_DOWN/KEY_LEFT/KEY_RIGHT in this environment — confirmed via an isolated
    repro (arrow key arrives as three separate getch() calls: 27, '[', then the final
    letter) that persisted even after curses.set_escdelay(). This reassembly is the actual
    fix; a bare lone ESC (nothing follows within the timeout window) is returned as-is.
    """
    key = stdscr.getch()
    if key != 27:
        return key
    k2 = stdscr.getch()
    if k2 != ord("["):
        return key if k2 == -1 else k2
    k3 = stdscr.getch()
    return _ARROW_BY_FINAL_BYTE.get(k3, key)


def run_app(stdscr, cid, env, project, workspace, target_dir):
    curses.curs_set(0)
    try:
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)
        curses.init_pair(2, curses.COLOR_RED, -1)
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
    picking which existing stack is initially "active" for the Domains/Whitelist/Access log
    tabs, if any exists for this exact directory, and (b) where a brand-new environment gets
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

    pending = curses.wrapper(run_app, cid, env, project, workspace, target)
    if pending:
        action, row = pending
        if action == "open_shell":
            compose_dir = REPO_ROOT / row["env"]
            launcher.start_and_open_shell(compose_dir, row["workspace"], rebuild, debug)
        elif action == "new_stack":
            launcher.start_and_open_shell(row["compose_dir"], row["folder"], rebuild, debug)
