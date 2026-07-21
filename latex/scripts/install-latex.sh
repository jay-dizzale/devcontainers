#!/bin/sh
# install-latex.sh
# Installs a full LaTeX environment with Perl/Tk GUI support.
# All packages are installed via APT — no external downloads, no verification needed.
# Dependencies: apt-get

apt-get update -qq
apt-get install -qqy \
    perl-tk \
    texlive-full \
    latexmk