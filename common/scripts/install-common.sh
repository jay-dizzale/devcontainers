#!/bin/sh
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

localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

sh install-gh.sh
sh install-tea.sh

install -m 755 /tmp/motd.sh /usr/local/bin/motd