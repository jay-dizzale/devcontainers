#!/bin/sh
# install-common.sh runs a chain of `sh install-X.sh` sub-scripts (each of which already has
# its own `set -eu`). Without `set -e` here too, a failing apt-get or a failing sub-script
# doesn't stop this script — it just keeps going, and the real error (e.g. apt-get's
# "Temporary failure resolving ..." for a transient DNS/proxy blip while fetching `rustup`)
# scrolls past unnoticed. The build then only fails several steps later, at the Dockerfile's
# separate `RUN rustup toolchain install` step, with the misleading "rustup: not found" —
# nowhere near the actual cause. `set -eu` makes it fail loudly at the real failing command.
set -eu
. /usr/local/lib/shell/download-utils.sh

# Bootstrap: get ca-certificates so update-ca-certificates is available.
# Ubuntu mirrors use HTTP so no proxy cert is needed for this step.
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates

# Install custom CA certificates before any HTTPS calls so a
# SSL-inspecting proxy is trusted for all subsequent steps.
if ls /tmp/certs/*.crt 2>/dev/null | grep -q .; then
    echo "Installing custom CA certificates ..."
    mkdir -p /usr/local/share/ca-certificates/
    cp /tmp/certs/*.crt /usr/local/share/ca-certificates/
    update-ca-certificates
fi

apt-get install -qqy apt-transport-https \
  curl \
  git \
  gnupg \
  gpg \
  gpg \
  iptables \
  jq \
  libbz2-dev \
  libffi-dev \
  liblzma-dev \
  libncursesw5-dev \
  libreadline-dev \
  libsqlite3-dev \
  libssl-dev \
  libxml2-dev \
  libxmlsec1-dev \
  libzstd-dev \
  locales \
  lsb-release \
  make \
  make build-essential \
  mandoc \
  rustup \
  socat \
  software-properties-common \
  tk-dev \
  unzip \
  vim \
  wget \
  xz-utils \
  zip \
  zlib1g-dev \
  zsh

# No -A /usr/share/locale/locale.alias: that file doesn't exist on Ubuntu 26.04's glibc
# (dropped upstream) — localedef errored out trying to update it. Silently ignored before
# `set -e` above was added; genuinely unnecessary for generating the locale itself.
localedef -i en_US -c -f UTF-8 en_US.UTF-8

sh install-gh.sh
sh install-tea.sh
sh install-trivy.sh
sh install-shfmt.sh

## Ruby, Go, and uv (Python) are part of the common base so every toolbelt
## gets them, not just base-toolbelt. The dev headers above (libssl-dev,
## libreadline-dev, ...) are ruby-build's standard dependencies.
sh install-ruby.sh
sh install-go.sh
sh install-uv.sh

install -m 755 /tmp/motd.sh /usr/local/bin/motd