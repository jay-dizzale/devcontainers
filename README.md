# `🛠️ DevContainers — a toolbox of ready-to-use development environments`

A collection of self-contained [DevContainer](https://containers.dev/) environments.
Each one bundles a language runtime and its typical tooling on a shared Ubuntu
base, so you can drop into a fully equipped shell for whatever you're working on —
without installing anything on your host.

Pick an environment with the interactive launcher (`./run.py`) or open it directly
in VS Code / any DevContainer-aware editor.

## Available environments

Every environment builds on the **common base** (see below), which now includes
Ruby, Rust, Go, and Python/`uv`, and adds its own tools on top:

| Environment | Focus | Tools installed on top of the base |
|-------------|-------|------------------------------------|
| `base-toolbelt` | Ruby, Rust, Go, Python & C development | Nothing extra — the plain common base, with dev-server/debugger port mappings for these languages |
| `infrastructure-toolbelt` | Infrastructure-as-Code on AWS & Azure | `tenv` (Terraform/OpenTofu), `terraform-docs`, `tflint`, AWS CLI, AWS SSM plugin, Azure CLI, `spacectl` (Spacelift), Kafka + MSK IAM auth |
| `java-toolbelt` | Java development | Amazon Corretto JDK, Apache Maven |
| `latex-toolbelt` | Document authoring | `texlive-full` (with Perl/Tk GUI support) |
| `pico-toolbelt` | Raspberry Pi Pico / RP2040 firmware | `arm-none-eabi` GCC toolchain, `pico-sdk`, `pico-extras`, `pico-examples` |
| `web-toolbelt` | Web / Node.js development | Node.js (incl. npm) |

> By default every tool resolves the **latest stable release** at build time —
> nothing above is pinned to a fixed version number. To pin one, pass its
> `<TOOL>_VERSION` build arg in that environment's `docker-compose.yml` (e.g.
> `JAVA_VERSION`); each install script accepts it as `$1`/env-var fallback.
> `RUST_VERSION` is the exception: it is read from your shell environment by
> `run.py` when it builds the shared base image. Not every tool has that arg wired through yet —
> check the env's `docker-compose.yml` before assuming one is reachable.
> The launcher lists `base-toolbelt` first, in its own category, followed by
> the other toolbelts alphabetically.

## Services

Besides the toolbelts, `run.py` can start long-running **services**, listed under their
own "Services" heading in the `n` (new stack) modal. A service is not a devcontainer:
no workspace is mounted and no shell is opened — it just runs, behind the same egress
proxy, and its card in the Stacks pane shows the URL to open.

| Service | What it is |
|---------|------------|
| `open-webui-service` | [Open WebUI](https://github.com/open-webui/open-webui) on `http://localhost:3080` (override with `OPEN_WEBUI_PORT`), preconfigured for **Ollama on your host** (`host.docker.internal:11434`) and Ollama embeddings (`nomic-embed-text`) for RAG. Data is kept in the `open-webui-data` Docker volume, which `stop`/`d` never deletes. |

Before first use, pull the models on the host: `ollama pull nomic-embed-text` plus a chat
model (e.g. `ollama pull llama3.2`). On a Linux host, Ollama must listen beyond loopback
(`OLLAMA_HOST=0.0.0.0`); Docker Desktop on macOS/Windows works with the default.

## The common base

Everything in `common/` is shared by all environments (`common/base.docker-compose.yml`
+ `common/scripts/install-common.sh`). Every container therefore ships with:

- **Base OS & build tooling** — Ubuntu 26.04, `build-essential`, `make`, `git`,
  `curl`/`wget`, `jq`, `unzip`/`zip`, `vim`, `zsh`, plus the common `-dev` headers
  needed to build languages from source.
- **Ruby** (built from source), **`rustup`** + Rust toolchain, **Go**, and **`uv`**
  (Python version & venv manager) — every environment gets these, not just
  `base-toolbelt`.
- **`gh`** — GitHub CLI.
- **`tea`** — Gitea CLI.
- **`trivy`** — vulnerability scanner.
- **`shfmt`** — shell formatter.
- **A preconfigured `zsh`** — history, git config, prompt and a `gitpush` helper
  (`common/.zshrc`). Drop a `.zshrc2` into an environment to extend it.

The base also mounts useful host config **read-only** into the container
(`~/.config/gh`, `~/.config/tea/config.yml`) and your **workspace** at `/workspace`.

## Egress proxy and domain whitelist

Every container's runtime network traffic is forced through a Squid proxy sidecar that only
allows a whitelisted set of domains — anything else is denied, and every connection (allowed
or denied) is logged. This is enforced by iptables rules set inside the container itself at
startup (dropping all outbound traffic except to the proxy), not just by setting `HTTP_PROXY`
— a process that ignores those env vars still can't reach the internet directly.

- **Something you need got blocked?** `./run.py` (or just `dev`) — the same terminal app
  described below: **Stacks** (left pane, always visible — every devcontainer stack as its own
  card, start/stop/delete any one, switch which stack the other panes manage, or start a brand
  new one) and, on the right, **Domain Statistics** (every domain seen, green for allowed, red
  for denied, `a`/`b` to allow/block the selected one — `a` here always adds to your personal,
  gitignored `local.txt`), **Global Whitelist** (every domain in the *shared, committed*
  whitelist files, `n` to add one — you'll be asked whether it belongs in the shared list or
  just this environment's — `b` to remove one), **Custom Whitelist** (your own personal,
  gitignored additions — same `n`/`b`, no sharing prompt needed), and **Access log** (the raw,
  timestamped log, `c` to clear it). Add `-f` for a passive, non-interactive view instead
  (redraws every 2s until Ctrl-C).
- **Filtering is domain-level, not a man-in-the-middle** — Squid reads the domain from the
  `CONNECT` request for HTTPS (or the request host for plain HTTP) and either tunnels the
  connection untouched or denies it. It never decrypts traffic, so no certificate needs to be
  installed and certificate pinning keeps working.
- **This governs the running container, not the image build.** `docker compose build` still
  uses `proxy.env` (below) if you've set one, unaffected by the whitelist.
- If `proxy.env` configures a corporate proxy, the whitelist proxy chains to it automatically —
  the two aren't mutually exclusive.

See [`AGENTS.md`](AGENTS.md#egress-proxy-and-domain-whitelist) for the full architecture.

## Preconditions

- Docker (with the Compose plugin) and a container runtime.
- For VS Code usage: the *Dev Containers* extension.

## Run it (interactive launcher)

`run.py` opens straight into its **Stacks** tab — every devcontainer stack already running on
your machine (not just ones from the current directory — `dev` gets run from all over the
place). Pick one and press `o` to open a shell in it (building/starting it first if it isn't
already up), or press `n` to start a brand-new environment for the current directory.

```sh
# 1. Clone and enter the repository
git clone <this-repo> && cd <this-repo>

# 2. One-time setup — git identity, common/.zshrc, CA bundle, proxy.env, `dev` command
./run.py setup

# 3. Launch — mounts the current directory into /workspace by default
./run.py

# ...or mount a specific project directory into /workspace
./run.py -v /path/to/your/project
```

In the Stacks tab:
- **Already have a stack running?** `↑`/`↓` to select it, then `o` to open a shell in it.
- **Starting fresh?** Press `n` — you'll be prompted to pick an environment (`base-toolbelt`,
  or one of the other toolbelts, e.g. `java-toolbelt`, `web-toolbelt`…), then it builds the
  image if needed, starts the stack, and drops you into a `zsh` shell. If the environment
  defines more than one service, you'll be asked which one (enter `s` to keep the stack
  running without opening a shell).
- **Pause a stack without losing it?** `s` stops all of its containers (nothing is deleted);
  `s` again starts it back up. `d` is the one that deletes a stack.

Each card's border is green while the stack's container is running and red when it isn't.

The same host directory + environment always reconnects to the same stack, so
re-running `run.py` picks up your existing container instead of rebuilding.
The project name is random (`dev-<8 hex>`) and encodes nothing; stacks are
identified by labels instead: `devcontainer.env` (the toolbelt, set in each
`<env>/docker-compose.yml`) and `devcontainer.workspace` (the exact host
directory, set in `common/base.docker-compose.yml`). `run.py` looks up an
existing stack by those two labels and reuses its project name, so two
directories that share their last path segments never collide. The
`devcontainer.env` label is also how `run.py list`/`stop` recognise a
container as belonging to this project. Exiting the shell does **not** stop or
delete the stack — it keeps running so reconnecting is instant. Use
`./run.py stop` (below) when you actually want to tear it down.

### Stop & delete a stack

```sh
./run.py stop                    # tear down stacks mounted from the current directory
./run.py stop -v /path/to/project
./run.py stop --all               # tear down every devcontainer stack, from any directory
```

Among containers carrying the `devcontainer.env` label, this finds those whose
`/workspace` mount points at that directory (or, with `--all`, all of them) and runs
`docker compose down -v` for each matching stack (containers, networks and
anonymous volumes removed).

### List running stacks

```sh
./run.py list
```

Shows every devcontainer stack (project, env, service, status, mounted workspace
directory), regardless of which directory it was started from.

### View the egress proxy's access log

```sh
./run.py logs                    # last 50 lines, for the stack mounted from the current directory
./run.py logs -f                 # follow it live
./run.py logs -v /path/to/project
```

Shows every allowed and denied connection Squid has logged. Prompts to pick a stack if more
than one is running from that directory. For a colorized, grouped-by-domain summary instead
of the raw log, use bare `./run.py` (its own Access log tab).

### Build only the shared base image

```sh
./run.py build-base        # build/refresh toolbelt-base:latest, then exit
./run.py build-base -r     # force a from-scratch rebuild
```

The base is local-only (never pushed) and is rebuilt automatically only when
`common/` (or `RUST_VERSION`) changed. Run this once before using an
environment from VS Code "Reopen in Container", which doesn't go through `run.py`.

## Run it (VS Code / DevContainers)

Open the environment's folder (e.g. `infrastructure-toolbelt/`) in VS Code and choose
**"Reopen in Container"**. The environment's `devcontainer.json` handles the rest.

## Configure it

- **Versions** — edit the build `args` in an environment's `docker-compose.yml`
  (or export `RUST_VERSION` before running `run.py` for the base image).
- **Identity** — `./run.py setup` generates `common/.zshrc` from
  `common/zshrc-template` with the name/email you give it. `common/.zshrc`
  is gitignored (it holds your real identity); only the template is
  checked in. Re-run `run.py setup` to change it, or edit `common/.zshrc`
  directly for a one-off tweak.
- **Per-environment shell tweaks** — add a `.zshrc2` (already wired up for `infrastructure-toolbelt`).
- **Trim it down** — remove environment folders you don't need.
- **GitHub API rate limit** — optional. Some install scripts fall back to the
  GitHub API to resolve "latest" versions, which is capped at 60 unauthenticated
  requests/hour per IP. Export `GITHUB_TOKEN` (or `GH_TOKEN`) before running
  `run.py`/`dev` and it's passed to the build as a BuildKit secret — never baked
  into the image layers:
  ```sh
  export GITHUB_TOKEN=ghp_xxx
  ./run.py
  ```

## Stop it

```sh
exit                # if you're inside the container shell
./run.py stop       # or, from the environment's directory (same -f files it was started with):
docker compose -f docker-compose.yml -f ../common/proxy.docker-compose.yml down -v
```

## For AI assistants

Working in this repo with an AI agent? See [`AGENTS.md`](AGENTS.md) for repository
conventions, structure, and guardrails.

## Security

Found a vulnerability? See [`SECURITY.md`](SECURITY.md) for how to report it privately.

## License

Apache License, Version 2.0 — see [`LICENSE.md`](LICENSE.md) or
<http://www.apache.org/licenses/LICENSE-2.0>.
