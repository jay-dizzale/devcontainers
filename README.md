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
| `csharp`    | .NET development | .NET SDK `10.0.105`, .NET Runtime `10.0.5` |
| `gcc`       | Raspberry Pi Pico / RP2040 firmware | `arm-none-eabi` GCC toolchain, `pico-sdk` `2.2.0`, `pico-extras`, `pico-examples` |
| `go`        | Go development | Go `1.24.2` |
| `iac`       | Infrastructure-as-Code on AWS & Azure | `tenv` (Terraform/OpenTofu), `terraform-docs`, `tflint`, AWS CLI, AWS SSM plugin, Azure CLI, `spacectl` (Spacelift), Amazon Corretto JDK `21`, Kafka + MSK IAM auth, Go, `uv`, Node.js `22` |
| `java`      | Java development | Amazon Corretto JDK `25`, Apache Maven `3.9.11` |
| `latex`     | Document authoring | `texlive-full` (with Perl/Tk GUI support) |
| `opentofu`  | OpenTofu / Terraform | `tenv`, `terraform-docs`, `tflint` |
| `ruby`      | Ruby development | Ruby `4.0.2` (built from source) |
| `rust`      | Rust development | `rustup` + Rust toolchain `1.87.0`, `build-essential` |
| `uv`        | Python development | `uv` `0.6.14` (Python version & venv manager) |
| `web`       | Web / Node.js development | Node.js `22` (incl. npm) |

> Tool versions are pinned in each environment's `docker-compose.yml` (build `args`).
> The `iac` environment is the "kitchen sink" — it composes many of the others into a
> single image for platform/DevOps work.

## The common base

Everything in `common/` is shared by all environments (`common/base.docker-compose.yml`
+ `common/scripts/install-common.sh`). Every container therefore ships with:

- **Base OS & build tooling** — Ubuntu `noble`, `build-essential`, `make`, `git`,
  `curl`/`wget`, `jq`, `unzip`/`zip`, `vim`, `zsh`, plus the common `-dev` headers
  needed to build languages from source.
- **`gh`** — GitHub CLI.
- **`tea`** — Gitea CLI.
- **Claude Code** — installed from a GPG-signature-verified, pinned release
  (`common/scripts/install-claude.sh`), so AI assistance is available out of the box.
- **A preconfigured `zsh`** — history, git config, prompt and a `gitpush` helper
  (`common/.zshrc`). Drop a `.zshrc2` into an environment to extend it.

The base also mounts useful host config **read-only** into the container
(`~/.config/gh`, `~/.config/tea/config.yml`) and your **workspace** at `/workspace`.
`~/.claude` and `~/.claude.json` are mounted **read-write** so Claude Code can persist
its session/auth state.

Pinned base versions live in `common/scripts/versions.env`.

## Preconditions

- Docker (with the Compose plugin) and a container runtime.
- For VS Code usage: the *Dev Containers* extension.

## Run it (interactive launcher)

`run.sh` discovers every `docker-compose.yml`, lets you pick an environment and a
service, builds/reuses the container, and drops you into a `zsh` shell.

```sh
# 1. Clone and enter the repository
git clone <this-repo> && cd <this-repo>

# 2. Launch — mounts the current directory into /workspace by default
sh run.sh

# ...or mount a specific project directory into /workspace
sh run.sh -v /path/to/your/project
```

You'll be prompted to:
1. **Select an environment** (e.g. `go`, `iac`, `rust`…).
2. **Select a service** (auto-selected when there's only one; enter `s` to keep the
   stack running without opening a shell).
3. **Choose an exit strategy** — bring the stack down on shell exit, or leave it running.

The same host directory always maps to the same container, so re-running `run.sh`
reconnects to your existing stack instead of rebuilding.

## Run it (VS Code / DevContainers)

Open the environment's folder (e.g. `iac/`) in VS Code and choose
**"Reopen in Container"**. The environment's `devcontainer.json` handles the rest.

## Configure it

- **Versions** — edit the build `args` in an environment's `docker-compose.yml`
  (or `common/scripts/versions.env` for base tools).
- **Identity** — the git user is set in `common/.zshrc`; update it to your own
  name/email.
- **Per-environment shell tweaks** — add a `.zshrc2` (already wired up for `iac`,
  `opentofu`, `uv`).
- **Trim it down** — remove environment folders you don't need.

## Stop it

```sh
exit                 # if you're inside the container shell
docker compose down  # from the environment's directory, to remove the stack
```

## For AI assistants

Working in this repo with an AI agent? See [`AGENTS.md`](AGENTS.md) for repository
conventions, structure, and guardrails.

## License

Apache License, Version 2.0 — see [`LICENSE.md`](LICENSE.md) or
<http://www.apache.org/licenses/LICENSE-2.0>.
