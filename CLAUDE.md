# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A **collection of DevContainer environments**, not an application. Each top-level
folder (`csharp/`, `gcc/`, `go/`, `iac/`, `java/`, `latex/`, `opentofu/`, `ruby/`,
`rust/`, `uv/`, `web/`) is one containerized development environment. All of them
layer on a shared base defined in `common/`. The goal is reproducible, pinned
toolchains that developers launch via `run.sh` or VS Code Dev Containers.

There is **no application code to build/test/lint here** — the "product" is the
Docker images and the scripts that build them. Verification means building the
image and confirming the tooling installs work (see Commands below).

## Repository layout

```
.
├── run.sh                        # Interactive launcher: pick an env + service, opens a zsh shell
├── setup.sh                      # One-time host setup: git identity, CA bundle, proxy.env, `dev` shell function
├── common/                       # Shared base for every environment
│   ├── base.docker-compose.yml   # Base compose service (mounts, env, user) that others `extend`
│   ├── .zshrc                    # Shared shell config (history, git config, prompt, gitpush)
│   ├── lib/download-utils.sh     # Shared shell helpers: download_file, download_and_verify, load_env
│   ├── scripts/
│   │   ├── install-common.sh     # apt base packages + gh + tea + trivy
│   │   ├── install-gh.sh         # GitHub CLI
│   │   ├── install-tea.sh        # Gitea CLI
│   │   └── versions.env          # Pinned versions for the base tools
│   └── agents/                   # Optional coding-agent CLIs (see below)
│       ├── install-agents.sh     # Dispatches the AGENTS build arg to install-<name>.sh below
│       ├── install-claude.sh     # Claude Code CLI (agent "claude", GPG-signature-verified, pinned)
│       └── install-copilot.sh    # GitHub Copilot CLI (agent "copilot", checksum-verified, pinned)
└── <env>/                        # One folder per environment, each with:
    ├── Dockerfile                # FROM ubuntu:noble; runs install-common.sh then env scripts
    ├── docker-compose.yml        # `extends` common base; pins tool versions via build args
    ├── devcontainer.json         # VS Code Dev Containers entry point (most envs)
    └── scripts/                  # Env-specific install-*.sh scripts
```

## How the pieces fit together

- Each `<env>/docker-compose.yml` **extends** `common/base.docker-compose.yml` and
  sets **tool versions as build `args`**. Change a version there, not in the Dockerfile.
- Each `<env>/Dockerfile` uses **build context `..`** (the repo root), so it can `ADD`
  from both `common/` and the env folder. Keep that in mind when adding `ADD`/`COPY` paths.
- Dockerfiles always run `common/scripts/install-common.sh` first, then env-specific
  `install-*.sh` scripts, then `rm -rf /tmp/*`.
- The `iac` environment intentionally reuses install scripts from **other** env folders
  (`../go/scripts`, `../uv/scripts`, `../web/scripts`, `../java/scripts`, `../opentofu/scripts`).
  It is the "kitchen sink" that composes many of the others into one image. If you change
  one of those scripts, check the impact on `iac` too.
- The container's mounted workspace (`/workspace`) is bound to `${VOLUME}`, which
  `run.sh` sets to the directory it was invoked from (or `-v <path>`). The compose
  project name is derived as `<env>_<parent-dir>_<current-dir>` so the same host
  directory always reconnects to the same stack.
- `~/.config/gh`, `~/.config/tea/config.yml` are mounted **read-only**; `~/.claude`
  and `~/.claude.json` are mounted **read-write** so Claude Code can persist session/auth
  state. Never bake host secrets (`~/.aws`, `~/.azure`, `~/.terraform.d`, `~/.spacelift`,
  `~/.m2`, gh/tea config, `~/.claude*`) into images — they're runtime volume mounts only.
- **Optional coding-agent CLIs** are selected at `run.sh` time (none/one/many), not
  hardcoded per environment. `run.sh` prompts from `AGENTS_AVAILABLE` (an `id:Label`
  list) and exports a single `AGENTS` build arg (e.g. `AGENTS=claude,copilot`,
  respected non-interactively too). Every Dockerfile `ADD`s `common/agents/` to
  `/tmp/agents/` (separate from `common/scripts/` → `/tmp/`) and forwards the arg via
  `RUN --mount=type=secret,id=github_token AGENTS="${AGENTS}" sh /tmp/agents/install-agents.sh`,
  which dispatches each selected id to `common/agents/install-<id>.sh`. **To add a new
  agent: add one `install-<id>.sh` script in `common/agents/` + one `AGENTS_AVAILABLE`
  line in `run.sh` — no Dockerfile or docker-compose.yml changes needed.**

## Commands

```sh
# One-time host setup (git identity, CA bundle, proxy.env, `dev` shell function)
sh setup.sh

# Interactive launcher — pick an environment + service, opens a zsh shell
sh run.sh
sh run.sh -v /path/to/your/project   # mount a different directory into /workspace
sh run.sh -r                         # force a from-scratch rebuild (--no-cache)
sh run.sh --debug                    # verbose docker build output (--progress=plain)

# Stop & delete the stack(s) mounted from a directory (containers, networks, anon volumes)
sh run.sh stop
sh run.sh stop -v /path/to/your/project

# Manually build/run a single environment without the launcher
cd <env> && docker compose up -d --build
docker compose exec -ti <service> zsh
docker compose down -v               # tear down
```

There are no linters or test suites to run; validate changes by building the affected
environment's image (`docker compose build` in that env's directory) and, where
relevant, checking the `iac` build still succeeds since it reuses other envs' scripts.

## Conventions to follow

- **Base images:** `FROM ubuntu:noble`. Final user is `ubuntu` (uid/gid `1000`),
  workdir `/workspace`, which is the mounted volume.
- **Install scripts** are POSIX `sh` (`set -eu`), take the version as `$1` with an
  env-var fallback, and **verify downloads** — reuse `download_and_verify` /
  `download_file` from `common/lib/download-utils.sh` and check GPG signatures or
  SHA256/SHA512 checksums against upstream. Do not add unverified `curl | sh` installs.
- **Pin every version.** New tools get a build `arg` in the env's `docker-compose.yml`
  (or an entry in `common/scripts/versions.env` for base tools). No `latest` tags.
- **Match the surrounding style** — comment headers on scripts, the existing section
  banners in Dockerfiles, two-space YAML indentation.

## Adding a new environment

1. Create `<env>/Dockerfile`, `<env>/docker-compose.yml` (extending the common base),
   `<env>/devcontainer.json`, and `<env>/scripts/`.
2. Pin tool versions via build `args`.
3. `run.sh` auto-discovers any folder containing a `docker-compose.yml` — no launcher
   changes needed.
4. Add a row to the **Available environments** table in `README.md`.

## Guardrails

- **Do not commit secrets or credentials.** Host secrets are provided at **runtime
  via volume mounts**, never baked into images.
- **Do not run `docker compose down -v`, `docker system prune`, or delete images/volumes**
  unless the user explicitly asks — these destroy running environments and state.
- **Do not bump pinned versions unprompted.** Version changes are deliberate.
- Prefer editing the **shared** `common/` scripts over duplicating logic per environment.
- Keep changes scoped: touching `common/` or a shared install script affects **all**
  environments — call that out to the user.
