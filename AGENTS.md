# AGENTS.md — instructions for AI assistants

This file gives AI coding agents (Claude Code, and any other agent that reads
`AGENTS.md`) the context and guardrails needed to work in this repository safely.

## What this repository is

A **collection of DevContainer environments**, not an application. Each top-level
folder (`csharp/`, `go/`, `iac/`, `rust/`, …) is one containerized development
environment. All of them layer on a shared base defined in `common/`. The goal is
reproducible, pinned toolchains that developers launch via `run.sh` or VS Code
Dev Containers.

There is **no application code to run or test here** — the "product" is the Docker
images and the scripts that build them.

## Repository layout

```
.
├── run.sh                        # Interactive launcher: pick an env + service, opens a zsh shell
├── common/                       # Shared base for every environment
│   ├── base.docker-compose.yml   # Base compose service (mounts, env, user) that others `extend`
│   ├── .zshrc                    # Shared shell config (history, git config, prompt, gitpush)
│   ├── lib/download-utils.sh     # Shared shell helpers: download_file, download_and_verify, load_env
│   └── scripts/
│       ├── install-common.sh     # apt base packages + gh + tea + Claude Code
│       ├── install-gh.sh         # GitHub CLI
│       ├── install-tea.sh        # Gitea CLI
│       ├── install-claude.sh     # Claude Code (GPG-signature-verified, pinned)
│       └── versions.env          # Pinned versions for the base tools
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
  If you change one of those scripts, check the impact on `iac` too.

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

- **Do not commit secrets or credentials.** Host secrets (`~/.aws`, `~/.azure`,
  `~/.terraform.d`, `~/.spacelift`, `~/.m2`, gh/tea config, `~/.claude*`) are provided
  at **runtime via volume mounts**, never baked into images.
- **Do not run `docker compose down -v`, `docker system prune`, or delete images/volumes**
  unless the user explicitly asks — these destroy running environments and state.
- **Do not bump pinned versions unprompted.** Version changes are deliberate.
- Prefer editing the **shared** `common/` scripts over duplicating logic per environment.
- Keep changes scoped: touching `common/` or a shared install script affects **all**
  environments — call that out to the user.
