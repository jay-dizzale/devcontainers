# AGENTS.md — instructions for AI assistants

This file gives AI coding agents (Claude Code, and any other agent that reads
`AGENTS.md`) the context and guardrails needed to work in this repository safely.

## What this repository is

A **collection of DevContainer environments**, not an application. Each top-level
folder (`csharp/`, `go/`, `toolbelt-infrastructure/`, `toolbelt-software/`, `java/`, `latex/`, `pico-development/`,
`python-with-uv/`, `ruby/`, `rust/`, `web/`) is one containerized development environment. All of them
layer on a shared base defined in `common/`. The goal is reproducible toolchains
that developers launch via `run.sh` or VS Code Dev Containers.

There is **no application code to run or test here** — the "product" is the Docker
images and the scripts that build them.

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
│   │   └── versions.env          # Pinned versions for the base tools (most tools resolve latest by default)
│   └── agents/                   # Coding-agent CLIs, installed unconditionally on every image
│       ├── install-agents.sh     # Installs DEFAULT_AGENTS by dispatching to install-<name>.sh below
│       ├── install-claude.sh     # Claude Code CLI (agent "claude", GPG-signature-verified, pinned)
│       └── install-copilot.sh    # GitHub Copilot CLI (agent "copilot", checksum-verified, pinned)
└── <env>/                        # One folder per environment, each with:
    ├── Dockerfile                # FROM ubuntu:noble; runs install-common.sh then env scripts
    ├── docker-compose.yml        # `extends` common base; some tool versions pinned via build args
    ├── devcontainer.json         # VS Code Dev Containers entry point (most envs)
    └── scripts/                  # Env-specific install-*.sh scripts
```

## How the pieces fit together

- Each `<env>/docker-compose.yml` **extends** `common/base.docker-compose.yml`. Where a
  tool's version is pinned, it's set as a build `arg` there (e.g. `JAVA_VERSION` in
  `java/docker-compose.yml`) — change it there, not in the Dockerfile.
- Each `<env>/Dockerfile` uses **build context `..`** (the repo root), so it can `ADD`
  from both `common/` and the env folder. Keep that in mind when adding `ADD`/`COPY` paths.
- Dockerfiles always run `common/scripts/install-common.sh` first, then
  `common/agents/install-agents.sh`, then env-specific `install-*.sh` scripts, then
  `rm -rf /tmp/*`.
- The toolbelt environments intentionally reuse install scripts from **other** env folders.
  `toolbelt-software` combines Java, `uv`, and Node.js.
  `toolbelt-infrastructure` combines the infrastructure tools with Java, Go, `uv`, and Node.js,
  and owns `install-tenv.sh`/`install-terraform-docs.sh`/`install-tflint.sh` directly.
  There is no standalone OpenTofu environment. If you change a shared installer, check the impact
  on both toolbelts as applicable.
- `~/.config/gh`, `~/.config/tea/config.yml` are mounted **read-only**; `~/.claude`,
  `~/.claude.json`, and `~/.copilot` are mounted **read-write** so the agent CLIs can
  persist session/auth state.
- Every RUN step whose script calls the GitHub API to resolve a version (`github_latest_stable`
  / `github_latest_matching` in `common/lib/download-utils.sh`) needs
  `--mount=type=secret,id=github_token` on its `RUN` line, and the env's
  `docker-compose.yml` needs the matching `secrets: github_token: environment: "GITHUB_TOKEN"`
  block wired into `build.secrets`. Setting `GITHUB_TOKEN` (or `GH_TOKEN`) before running
  `run.sh` raises the unauthenticated 60 req/hr rate limit that build otherwise hits.

## Conventions to follow

- **Base images:** `FROM ubuntu:noble`. Final user is `ubuntu` (uid/gid `1000`),
  workdir `/workspace`, which is the mounted volume.
- **Install scripts** are POSIX `sh` (`set -eu`), take the version as `$1` with an
  env-var fallback, and **verify downloads** — reuse `download_and_verify` /
  `download_file` from `common/lib/download-utils.sh` and check GPG signatures or
  SHA256/SHA512 checksums against upstream. Do not add unverified `curl | sh` installs.
- **Versions default to "latest stable" at build time** (see `common/scripts/versions.env`)
  — every install script resolves the newest release via its vendor's API/index when no
  version is given. To pin one instead, wire a `<TOOL>_VERSION` build `arg` through the
  env's `docker-compose.yml` (see `JAVA_VERSION`/`RUST_VERSION` for the pattern); the
  install script already accepts it as `$1`/env-var fallback. Not every env currently has
  this wired for every tool it installs.
- **Match the surrounding style** — comment headers on scripts, the existing section
  banners in Dockerfiles, two-space YAML indentation.

## Adding a new environment

1. Create `<env>/Dockerfile`, `<env>/docker-compose.yml` (extending the common base),
   `<env>/devcontainer.json`, and `<env>/scripts/`.
2. If the tool's version should be pinnable, wire a `<TOOL>_VERSION` build `arg`.
3. `run.sh` auto-discovers any folder containing a `docker-compose.yml` — no launcher
   changes needed.
4. Add a row to the **Available environments** table in `README.md`.

## Adding a new coding-agent CLI

1. Drop a `common/agents/install-<id>.sh` script (same conventions as the others:
   pinned version, checksum/signature verification).
2. Add its id to `DEFAULT_AGENTS` in `common/agents/install-agents.sh`.

No Dockerfile or docker-compose.yml changes are needed — every image already runs
`install-agents.sh` unconditionally.

## Guardrails

- **Do not commit secrets or credentials.** Host secrets (`~/.aws`, `~/.azure`,
  `~/.terraform.d`, `~/.spacelift`, `~/.m2`, gh/tea config, `~/.claude*`, `~/.copilot`)
  are provided at **runtime via volume mounts**, never baked into images.
- **Do not run `docker compose down -v`, `docker system prune`, or delete images/volumes**
  unless the user explicitly asks — these destroy running environments and state.
- **Do not bump pinned versions unprompted.** Version changes are deliberate.
- Prefer editing the **shared** `common/` scripts over duplicating logic per environment.
- Keep changes scoped: touching `common/` or a shared install script affects **all**
  environments — call that out to the user.
