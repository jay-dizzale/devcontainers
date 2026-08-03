#!/bin/sh
. /usr/local/lib/shell/download-utils.sh

# Install custom CA certificates first so all subsequent wget/curl/apt calls
# trust the proxy's certificate when SSL inspection is active.
if ls /tmp/certs/*.crt 2>/dev/null | grep -q .; then
    echo "Installing custom CA certificates ..."
    cp /tmp/certs/*.crt /usr/local/share/ca-certificates/
    update-ca-certificates
fi

apt-get update -qq
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