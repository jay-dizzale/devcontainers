#!/bin/sh
. /usr/local/lib/shell/download-utils.sh

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