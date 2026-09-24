# `🛠️ DevContainers — a toolbox of ready-to-use development environments`

A collection of self-contained [DevContainer](https://containers.dev/) environments.
Each one bundles a language runtime and its typical tooling on a shared Ubuntu
base, so you can drop into a fully equipped shell for whatever you're working on —
without installing anything on your host.

Pick an environment with the interactive launcher (`sh run.sh`) or open it directly
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
> `run.sh` when it builds the shared base image. Not every tool has that arg wired through yet —
> check the env's `docker-compose.yml` before assuming one is reachable.
> The launcher lists `base-toolbelt` first, in its own category, followed by
> the other five toolbelts alphabetically.

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
`~/.claude` and `~/.claude.json` are mounted **read-write** so Claude Code can persist
its session/auth state.

### Coding-agent CLIs

**Claude Code**, **GitHub Copilot CLI** and **opencode** are installed on every image, each
from a checksum/signature-verified release (`common/agents/install-claude.sh`,
`common/agents/install-copilot.sh`, `common/agents/install-opencode.sh`), dispatched by `common/agents/install-agents.sh`.

Adding a future agent needs no Dockerfile/docker-compose.yml changes — just a new
`common/agents/install-<name>.sh` and its id added to `DEFAULT_AGENTS` in
`common/agents/install-agents.sh`.

## Preconditions

- Docker (with the Compose plugin) and a container runtime.
- For VS Code usage: the *Dev Containers* extension.

## Run it (interactive launcher)

`run.sh` discovers every `docker-compose.yml`, lets you pick an environment and a
service, builds/reuses the container, and drops you into a `zsh` shell.

```sh
# 1. Clone and enter the repository
git clone <this-repo> && cd <this-repo>

# 2. One-time setup — git identity, common/.zshrc, CA bundle, proxy.env, `dev` command
sh setup.sh

# 3. Launch — mounts the current directory into /workspace by default
sh run.sh

# ...or mount a specific project directory into /workspace
sh run.sh -v /path/to/your/project
```

You'll be prompted to:
1. **Select an environment** — `base-toolbelt`, or one of the other toolbelts (e.g. `java-toolbelt`, `web-toolbelt`…).
2. **Select a service** (auto-selected when there's only one; enter `s` to keep the
   stack running without opening a shell).

The same host directory + environment always reconnects to the same stack, so
re-running `run.sh` picks up your existing container instead of rebuilding.
The project name is random (`dev-<8 hex>`) and encodes nothing; stacks are
identified by labels instead: `devcontainer.env` (the toolbelt, set in each
`<env>/docker-compose.yml`) and `devcontainer.workspace` (the exact host
directory, set in `common/base.docker-compose.yml`). `run.sh` looks up an
existing stack by those two labels and reuses its project name, so two
directories that share their last path segments never collide. The
`devcontainer.env` label is also how `run.sh list`/`stop` recognise a
container as belonging to this project. Exiting the shell does **not** stop or
delete the stack — it keeps running so reconnecting is instant. Use
`sh run.sh stop` (below) when you actually want to tear it down.

### Stop & delete a stack

```sh
sh run.sh stop                    # tear down stacks mounted from the current directory
sh run.sh stop -v /path/to/project
sh run.sh stop --all               # tear down every devcontainer stack, from any directory
```

Among containers carrying the `devcontainer.env` label, this finds those whose
`/workspace` mount points at that directory (or, with `--all`, all of them) and runs
`docker compose down -v` for each matching stack (containers, networks and
anonymous volumes removed).

### List running stacks

```sh
sh run.sh list
```

Shows every devcontainer stack (project, env, service, status, mounted workspace
directory), regardless of which directory it was started from.

### Build only the shared base image

```sh
sh run.sh build-base        # build/refresh toolbelt-base:latest, then exit
sh run.sh build-base -r     # force a from-scratch rebuild
```

The base is local-only (never pushed) and is rebuilt automatically only when
`common/` (or `RUST_VERSION`) changed. Run this once before using an
environment from VS Code "Reopen in Container", which doesn't go through `run.sh`.

## Run it (VS Code / DevContainers)

Open the environment's folder (e.g. `infrastructure-toolbelt/`) in VS Code and choose
**"Reopen in Container"**. The environment's `devcontainer.json` handles the rest.

## Configure it

- **Versions** — edit the build `args` in an environment's `docker-compose.yml`
  (or export `RUST_VERSION` before running `run.sh` for the base image).
- **Identity** — `sh setup.sh` generates `common/.zshrc` from
  `common/zshrc-template` with the name/email you give it. `common/.zshrc`
  is gitignored (it holds your real identity); only the template is
  checked in. Re-run `setup.sh` to change it, or edit `common/.zshrc`
  directly for a one-off tweak.
- **Per-environment shell tweaks** — add a `.zshrc2` (already wired up for `infrastructure-toolbelt`).
- **Trim it down** — remove environment folders you don't need.
- **GitHub API rate limit** — optional. Some install scripts fall back to the
  GitHub API to resolve "latest" versions, which is capped at 60 unauthenticated
  requests/hour per IP. Export `GITHUB_TOKEN` (or `GH_TOKEN`) before running
  `run.sh`/`dev` and it's passed to the build as a BuildKit secret — never baked
  into the image layers:
  ```sh
  export GITHUB_TOKEN=ghp_xxx
  sh run.sh
  ```

## Stop it

```sh
exit                 # if you're inside the container shell
docker compose down  # from the environment's directory, to remove the stack
```

## For AI assistants

Working in this repo with an AI agent? See [`AGENTS.md`](AGENTS.md) for repository
conventions, structure, and guardrails.

## Security

Found a vulnerability? See [`SECURITY.md`](SECURITY.md) for how to report it privately.

## License

Apache License, Version 2.0 — see [`LICENSE.md`](LICENSE.md) or
<http://www.apache.org/licenses/LICENSE-2.0>.
