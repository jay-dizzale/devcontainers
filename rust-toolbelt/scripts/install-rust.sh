#!/bin/sh
# install-rust.sh
# Installs rustup (from the Ubuntu archive, so it's verified by apt's own signed
# repository metadata). The toolchain itself is per-user (~/.rustup, ~/.cargo), so
# rust-toolbelt/Dockerfile installs it in a separate step as `ubuntu`, not here as root.
# Dependencies: apt-get

set -eu

apt-get update
apt-get install -y --no-install-recommends rustup
rm -rf /var/lib/apt/lists/*
