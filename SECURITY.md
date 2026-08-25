# Security Policy

This repository builds Docker images for local development environments. A
vulnerability here typically means something that could let a malicious
actor tamper with what gets installed into those images (e.g. an unverified
download, a broken checksum/signature check, a secret that leaks into an
image layer) or compromise the host running `run.sh`/`setup.sh`.

## Supported Versions

This is a personal project with a single rolling `main` branch — there are
no maintained release branches. Security fixes land on `main` only; please
make sure you're on the latest commit before reporting an issue.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, use GitHub's private vulnerability reporting for this repository:

1. Go to the **Security** tab.
2. Click **Report a vulnerability**.

This opens a private draft advisory visible only to the maintainer — no
public issue, no email address needed. If that option isn't available,
open a regular issue asking to be pointed to a private channel, without
including any vulnerability details.

This is a best-effort, personally maintained project — there's no SLA, but
reports will be acknowledged and addressed as soon as reasonably possible.

## Scope

In scope:

- `common/scripts/*.sh`, `common/agents/*.sh`, `common/lib/download-utils.sh`,
  and every `<env>/scripts/*.sh` — especially anything that downloads and
  executes/installs a binary without verifying a checksum or signature.
- `Dockerfile` / `docker-compose.yml` in any environment — build-arg or
  secret handling, base image pinning, anything that could bake a secret
  into an image layer.
- `run.sh` / `setup.sh` — the host-side launcher and one-time setup script.

Out of scope:

- Vulnerabilities in the third-party tools these scripts install (Go, Rust,
  AWS CLI, Terraform/OpenTofu, etc.) — please report those upstream, to the
  respective project.
- Issues that require an attacker to already control the host running
  `run.sh`, or to control environment variables/build args passed to it
  (these are treated as trusted input by design).
- Missing hardening/best-practice suggestions that aren't concretely
  exploitable — feel free to raise those as a regular issue or PR instead.

## What to Include

- The affected file/script and, if applicable, which environment
  (`csharp`, `go`, `toolbelt-infrastructure`, …).
- Steps to reproduce, or the specific code path that's affected.
- The potential impact (e.g. "an attacker who controls X could achieve Y").
