"""devtool/hostsetup.py - one-time host setup (`run.py setup`), replacing the old standalone
setup.sh: git identity, the generated common/.zshrc, an optional CA certificate bundle,
captured proxy settings, and the `dev` shell function in ~/.zshrc.

The git identity, CA bundle path, and proxy settings are collected through a single curses
form (see _setup_wizard), not a sequence of plain input() prompts - an enterprise proxy setup
needs all three of CA bundle + proxy URL + no_proxy filled in together, and a plain-text
wizard that marches through them one at a time with no way to jump back to fix an earlier
answer made that fiddly. Re-running `run.py setup` pre-fills the form with whatever is
already configured (git config, proxy.env, and which cert files are already installed), so
it reads as "review/edit current settings" the second time, not "answer the same questions
again from scratch". Tab (or ↑/↓) moves freely between fields; Enter applies all of them,
Esc cancels without changing anything.
"""
import curses
import os
import subprocess
import sys
from pathlib import Path

from .docker_utils import REPO_ROOT, die
from .proxy import _draw_box, _read_key, _safe_addnstr, init_curses_chrome

CERTS_DIR = REPO_ROOT / "common" / "scripts" / "certs"
PROXY_ENV_FILE = REPO_ROOT / "proxy.env"

# Order fields appear in the form, and the order Tab/↓ walks through them.
FIELDS = ["name", "email", "ca_cert", "proxy_url", "no_proxy"]
FIELD_LABELS = {
    "name": "Git name",
    "email": "Git email",
    "ca_cert": "CA cert bundle (path)",
    "proxy_url": "Proxy URL",
    "no_proxy": "No proxy",
}


def _step(msg):
    print(f"\n▶ {msg}")


def _ok(msg):
    print(f"✅ {msg}")


def _info(msg):
    print(f"   {msg}")


def _git_config_get(key):
    r = subprocess.run(["git", "config", "--global", key], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def _read_proxy_env():
    """Parses the KEY=value lines `run.py setup` itself wrote last time (commented-out lines
    are an unset variable - see _proxy_line) - this, not the current shell's environment, is
    what makes a second `run.py setup` show the proxy settings you actually have configured,
    even in a fresh shell that never exported them."""
    if not PROXY_ENV_FILE.is_file():
        return {}
    values = {}
    for line in PROXY_ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key] = value
    return values


def _current_defaults():
    """Form field defaults: git config for name/email, proxy.env (falling back to the current
    shell's proxy variables, for a first-ever run before proxy.env exists) for proxy_url/
    no_proxy. ca_cert always starts blank - the bundle actually gets copied into
    common/scripts/certs/ (see _apply_ca_bundle), so there's no original source path left to
    recall; _installed_certs() below is shown alongside the field instead, so "what's already
    configured" is still visible even though the field itself can't pre-fill it."""
    proxy_vals = _read_proxy_env()
    http_ = proxy_vals.get("HTTP_PROXY") or os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy") or ""
    no_proxy_ = proxy_vals.get("NO_PROXY") or os.environ.get("NO_PROXY") or os.environ.get("no_proxy") or ""
    return {
        "name": _git_config_get("user.name"),
        "email": _git_config_get("user.email"),
        "ca_cert": "",
        "proxy_url": http_,
        "no_proxy": no_proxy_,
    }


def _installed_certs():
    if not CERTS_DIR.is_dir():
        return []
    return sorted(p.name for p in CERTS_DIR.glob("*.crt"))


# ---------------------------------------------------------------------------
# Curses form
# ---------------------------------------------------------------------------
def _setup_wizard(stdscr, defaults, installed_certs):
    init_curses_chrome(stdscr, timeout_ms=100)
    values = dict(defaults)
    focus = 0
    error = ""

    try:
        while True:
            _draw_setup_form(stdscr, values, focus, error, installed_certs)
            key = _read_key(stdscr)
            if key == -1:
                continue
            if key == 27:
                return None
            if key == 9 or key == curses.KEY_DOWN:  # Tab / Down - next field
                focus = (focus + 1) % len(FIELDS)
                error = ""
            elif key == curses.KEY_UP:  # Up - previous field
                focus = (focus - 1) % len(FIELDS)
                error = ""
            elif key in (10, 13, curses.KEY_ENTER):
                ca_cert = values["ca_cert"].strip()
                if ca_cert and not Path(ca_cert).expanduser().is_file():
                    error = f"File not found: {ca_cert}"
                    continue
                return values
            elif key in (curses.KEY_BACKSPACE, 127, 8):
                values[FIELDS[focus]] = values[FIELDS[focus]][:-1]
            elif 32 <= key < 127:
                values[FIELDS[focus]] += chr(key)
    finally:
        curses.curs_set(0)


def _draw_setup_form(stdscr, values, focus, error, installed_certs):
    h, w = stdscr.getmaxyx()
    label_w = max(len(lbl) for lbl in FIELD_LABELS.values()) + 2
    box_w = max(54, min(76, w - 4))
    inner_w = box_w - 4
    field_w = max(1, inner_w - label_w)
    hint_rows = 2 if installed_certs else 1
    box_h = min(4 + len(FIELDS) + hint_rows + (1 if error else 0), h - 2)
    y0 = max(0, (h - box_h) // 2)
    x0 = max(0, (w - box_w) // 2)

    _draw_box(stdscr, y0, x0, box_h, box_w, "Setup")

    row = y0 + 2
    for i, key in enumerate(FIELDS):
        label = f"{FIELD_LABELS[key]}:"
        is_focus = i == focus
        _safe_addnstr(stdscr, row, x0 + 2, label, label_w, curses.color_pair(3) if not is_focus else curses.color_pair(3) | curses.A_BOLD)
        value = values[key]
        display = value[-field_w:] if len(value) > field_w else value
        attr = curses.A_UNDERLINE | (curses.A_REVERSE if is_focus else 0)
        _safe_addnstr(stdscr, row, x0 + 2 + label_w, display.ljust(field_w), field_w, attr)
        row += 1
        if key == "ca_cert" and installed_certs:
            hint = f"Installed: {', '.join(installed_certs)} (blank keeps as-is)"
            _safe_addnstr(stdscr, row, x0 + 2 + label_w, hint, field_w, curses.color_pair(3) | curses.A_DIM)
            row += 1

    if error:
        _safe_addnstr(stdscr, row, x0 + 2, error, inner_w, curses.color_pair(2) | curses.A_BOLD)
        row += 1

    hint = "Tab/↑/↓ switch field · Enter apply · Esc cancel"
    _safe_addnstr(stdscr, y0 + box_h - 2, x0 + 2, hint, inner_w, curses.color_pair(3) | curses.A_DIM)

    focus_row = y0 + 2 + sum(1 + (1 if FIELDS[i] == "ca_cert" and installed_certs else 0) for i in range(focus))
    label_for_focus = f"{FIELD_LABELS[FIELDS[focus]]}:"
    cursor_x = x0 + 2 + label_w + min(len(values[FIELDS[focus]]), field_w)
    curses.curs_set(1)
    try:
        stdscr.move(focus_row, cursor_x)
    except curses.error:
        pass
    stdscr.refresh()


# ---------------------------------------------------------------------------
# Applying the confirmed form
# ---------------------------------------------------------------------------
def _apply_git_identity(name, email):
    _step("Git identity")
    if name:
        subprocess.run(["git", "config", "--global", "user.name", name])
    if email:
        subprocess.run(["git", "config", "--global", "user.email", email])
    _ok(f"Git identity: {name} <{email}>" if (name or email) else "Git identity left unset.")


def _apply_zshrc(name, email):
    _step("Container shell config (common/.zshrc)")
    template = REPO_ROOT / "common" / "zshrc-template"
    out = REPO_ROOT / "common" / ".zshrc"

    if name and email:
        text = template.read_text()
        text = text.replace("CHANGE_ME@example.com", email).replace("Change Me", name)
        out.write_text(text)
        _ok("common/.zshrc generated with your git identity.")
    else:
        out.write_text(template.read_text())
        _info("No name/email set - common/.zshrc generated with placeholder identity.")


def _apply_ca_bundle(bundle):
    _step("CA certificate bundle")
    if not bundle:
        _info("No new bundle given - leaving common/scripts/certs/ as-is.")
        return

    src = Path(bundle).expanduser()
    if not src.is_file():
        die(f"File not found: {bundle}")  # the form already validated this, but stay safe

    dest_name = src.name
    if dest_name.endswith(".pem"):
        dest_name = dest_name[: -len(".pem")] + ".crt"
    elif not dest_name.endswith(".crt"):
        dest_name = dest_name + ".crt"

    dest = CERTS_DIR / dest_name
    dest.write_bytes(src.read_bytes())
    _ok(f"Certificate bundle copied to {dest}")
    _info("It will be installed into containers on the next build.")


def _proxy_line(key, value):
    return f"{key}={value}\n" if value else f"# {key}=\n"


def _apply_proxy_env(proxy_url, no_proxy):
    _step("Proxy")
    content = (
        "# Proxy configuration - generated by `run.py setup`\n"
        "# Edit this file to change proxy settings, then rebuild your containers.\n"
        + _proxy_line("HTTP_PROXY", proxy_url)
        + _proxy_line("HTTPS_PROXY", proxy_url)
        + _proxy_line("NO_PROXY", no_proxy)
        + _proxy_line("http_proxy", proxy_url)
        + _proxy_line("https_proxy", proxy_url)
        + _proxy_line("no_proxy", no_proxy)
    )
    PROXY_ENV_FILE.write_text(content)

    if proxy_url:
        _ok(f"Proxy written to proxy.env ({proxy_url})")
        if no_proxy:
            _info(f"No proxy: {no_proxy}")
    else:
        _ok("proxy.env written - no proxy URL set.")


def _apply_dev_function():
    _step("'dev' command")
    zshrc = Path.home() / ".zshrc"
    marker = "# devcontainer dev()"

    existing = zshrc.read_text() if zshrc.exists() else ""
    if marker in existing:
        _info(f"dev() already present in {zshrc} - skipping.")
        return

    run_py = REPO_ROOT / "run.py"
    block = f'\n{marker}\ndev() {{ "{run_py}" -v "$(pwd)" "$@"; }}\n'
    with zshrc.open("a") as fh:
        fh.write(block)
    _ok(f"dev() added to {zshrc}")
    _info("Run 'source ~/.zshrc' or open a new shell to activate it.")


def run():
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        die("'run.py setup' needs an interactive terminal.")

    values = curses.wrapper(_setup_wizard, _current_defaults(), _installed_certs())
    if values is None:
        print("Setup cancelled - nothing changed.")
        return

    name, email = values["name"].strip(), values["email"].strip()
    _apply_git_identity(name, email)
    _apply_zshrc(name, email)
    _apply_ca_bundle(values["ca_cert"].strip())
    _apply_proxy_env(values["proxy_url"].strip(), values["no_proxy"].strip())
    _apply_dev_function()

    print("\n🎉 Setup complete. Open any project with:\n")
    print("   cd /path/to/your/project")
    print("   dev\n")
