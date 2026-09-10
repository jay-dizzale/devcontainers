# `🧰 DevContainers — a toolbox of ready-to-use development environments`

A collection of self-contained [DevContainer](https://containers.dev/) environments.
Each one bundles a language runtime and its typical tooling on a shared Ubuntu
base, so you can drop into a fully equipped shell for whatever you're working on —
without installing anything on your host.

Pick an environment with the interactive launcher (`sh run.sh`) or open it directly
in VS Code / any DevContainer-aware editor.

## Available environments

Every environment builds on the **common base** (see below) and adds its own tools:

| Environment | Focus | Tools installed on top of the base |
|-------------|-------|------------------------------------|
| `toolbelt-software` | General software development | Amazon Corretto JDK, Apache Maven, `uv`, Node.js |
| `toolbelt-infrastructure` | Infrastructure-as-Code on AWS & Azure | `tenv` (Terraform/OpenTofu), `terraform-docs`, `tflint`, AWS CLI, AWS SSM plugin, Azure CLI, `spacectl` (Spacelift), Amazon Corretto JDK, Kafka + MSK IAM auth, Go, `uv`, Node.js |
| `ai-notebook` | AI/ML projects | `uv`, JupyterLab (auto-starts in the background on port 8888) |
| `csharp`    | .NET development | .NET SDK, .NET Runtime |
| `pico-development` | Raspberry Pi Pico / RP2040 firmware | `arm-none-eabi` GCC toolchain, `pico-sdk`, `pico-extras`, `pico-examples` |
| `go`        | Go development | Go |
| `java`      | Java development | Amazon Corretto JDK, Apache Maven |
| `latex`     | Document authoring | `texlive-full` (with Perl/Tk GUI support) |
| `ruby`      | Ruby development | Ruby (built from source) |
| `rust`      | Rust development | `rustup` + Rust toolchain, `build-essential` |
| `python-with-uv` | Python development | `uv` (Python version & venv manager) |
| `web`       | Web / Node.js development | Node.js (incl. npm) |

> By default every tool resolves the **latest stable release** at build time (see
> `common/scripts/versions.env`) — nothing above is pinned to a fixed version number.
> To pin one, pass its `<TOOL>_VERSION` build arg in that environment's
> `docker-compose.yml` (e.g. `JAVA_VERSION`, `RUST_VERSION`); each install script
> accepts it as `$1`/env-var fallback. Not every tool has that arg wired through yet —
> check the env's `docker-compose.yml` before assuming one is reachable.
> The launcher lists the two toolbelts first. `toolbelt-software` combines
> Java, Python via `uv`, and Node.js. `toolbelt-infrastructure` covers
> OpenTofu/Terraform, AWS/Azure, Kafka, Go, Python via `uv`, and Node.js.
> The focused environments remain available below them.

## The common base

Everything in `common/` is shared by all environments (`common/base.docker-compose.yml`
+ `common/scripts/install-common.sh`). Every container therefore ships with:

- **Base OS & build tooling** — Ubuntu `noble`, `build-essential`, `make`, `git`,
  `curl`/`wget`, `jq`, `unzip`/`zip`, `vim`, `zsh`, plus the common `-dev` headers
  needed to build languages from source.
- **`gh`** — GitHub CLI.
- **`tea`** — Gitea CLI.
- **A preconfigured `zsh`** — history, git config, prompt and a `gitpush` helper
  (`common/.zshrc`). Drop a `.zshrc2` into an environment to extend it.

The base also mounts useful host config **read-only** into the container
(`~/.config/gh`, `~/.config/tea/config.yml`) and your **workspace** at `/workspace`.
`~/.claude` and `~/.claude.json` are mounted **read-write** so Claude Code can persist
its session/auth state.

### Coding-agent CLIs

**Claude Code** and **GitHub Copilot CLI** are installed on every image, each from a
pinned, checksum/signature-verified release (`common/agents/install-claude.sh`,
`common/agents/install-copilot.sh`), dispatched by `common/agents/install-agents.sh`.

Adding a future agent needs no Dockerfile/docker-compose.yml changes — just a new
`common/agents/install-<name>.sh` and its id added to `DEFAULT_AGENTS` in
`common/agents/install-agents.sh`.

Pinned base versions live in `common/scripts/versions.env`.

### AI Notebook

`ai-notebook` is a sandbox for AI-assisted work: it deliberately limits what an
AI tool running inside it can reach, without limiting what it can *do* to the
files you're actually working on.

**Idle pattern**: unlike every other environment's `sleep infinity`, its
`docker-compose.yml` overrides `command` to run `start-jupyter.sh`, which
launches `jupyter lab` in the background (log at `~/.jupyter-lab.log` inside
the container), then idles like everything else so `run.sh`/`docker compose
exec` still work normally. JupyterLab is reachable at <http://localhost:8888>
(no token — the port is bound to `127.0.0.1` only).

**Two host bridges, both explicit**: `/workspace` (aka `~/workspace` in
JupyterLab's file browser) is the data your notebooks edit; `~/notebooks` is
an optional second bind mount for your notebook-scripts folder, kept
separate so you can version it independently (its own git repo, your normal
host editor/IDE) without mixing it into the data being worked on. `sh
setup.sh` asks for the host path and writes it to `ai-notebook/.env`
(gitignored — Compose auto-loads it for the `NOTEBOOKS_PATH` variable);
re-run it to change the path, or edit that file directly. Leave it empty to
skip this — mounts an empty placeholder folder instead, and you can still
work directly in `/workspace` via JupyterLab.

**Local LLM inference (Ollama, etc.)**: run it natively on the host, not
inside the container — no container runtime on macOS (Docker, Colima, or
Apple's own `container`) can pass through Metal/Neural-Engine acceleration to
a Linux guest, so a containerized Ollama falls back to CPU-only. Keep Ollama
bound to its default `127.0.0.1` (verify with `lsof -iTCP -sTCP:LISTEN -P |
grep 11434`) — do **not** bind it to `0.0.0.0` to make it reachable, since
that exposes it to your whole LAN. Colima's networking can reach a
host-loopback-bound service directly via `host.docker.internal`, so the
notebook just calls `http://host.docker.internal:11434`, and Ollama never
needs to leave its safe default.

Only `uv` + JupyterLab are preinstalled; add your project's own dependencies
(numpy, pandas, torch, …) via `uv add`, then register that venv as a Jupyter
kernel with `uv run --with ipykernel python -m ipykernel install --user
--name <project>` so it shows up in JupyterLab's kernel picker.

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
1. **Select a toolbelt or focused environment** (e.g. `toolbelt-software`, `go`, `rust`…).
2. **Select a service** (auto-selected when there's only one; enter `s` to keep the
   stack running without opening a shell).

The same host directory always maps to the same container, so re-running `run.sh`
reconnects to your existing stack instead of rebuilding. Exiting the shell does
**not** stop or delete the stack — it keeps running so reconnecting is instant. Use
`sh run.sh stop` (below) when you actually want to tear it down.

### Stop & delete a stack

```sh
sh run.sh stop                    # tear down stacks mounted from the current directory
sh run.sh stop -v /path/to/project
sh run.sh stop --all               # tear down every devcontainer stack, from any directory
```

This finds every container whose `/workspace` mount points at that directory (or,
with `--all`, every container with a `/workspace` mount at all) and runs
`docker compose down -v` for each matching stack (containers, networks and
anonymous volumes removed).

### List running stacks

```sh
sh run.sh list
```

Shows every devcontainer stack (project, service, status, mounted workspace
directory), regardless of which directory it was started from.

## Run it (VS Code / DevContainers)

Open the environment's folder (e.g. `toolbelt-infrastructure/`) in VS Code and choose
**"Reopen in Container"**. The environment's `devcontainer.json` handles the rest.

## Configure it

- **Versions** — edit the build `args` in an environment's `docker-compose.yml`
  (or `common/scripts/versions.env` for base tools).
- **Identity** — `sh setup.sh` generates `common/.zshrc` from
  `common/zshrc-template` with the name/email you give it. `common/.zshrc`
  is gitignored (it holds your real identity); only the template is
  checked in. Re-run `setup.sh` to change it, or edit `common/.zshrc`
  directly for a one-off tweak.
- **Per-environment shell tweaks** — add a `.zshrc2` (already wired up for both toolbelts and `python-with-uv`).
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
