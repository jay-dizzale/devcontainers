#!/bin/sh
# install-aws-cli.sh
# Installs the AWS CLI v2 and the SSM Session Manager Plugin.
# Downloads directly from official AWS endpoints over HTTPS.
# Dependencies: wget, unzip, dpkg

# ---------------------------------------------------------------------------
# Arch detection
# ---------------------------------------------------------------------------
MACHINE_TYPE="$(uname -m)"
case "${MACHINE_TYPE}" in
    aarch64) ARCH_CLI="aarch64" ; ARCH_SSM="ubuntu_arm64" ;;
    x86_64)  ARCH_CLI="x86_64"  ; ARCH_SSM="ubuntu_64bit" ;;
    *)
        echo "ERROR: Unsupported architecture: ${MACHINE_TYPE}" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# AWS CLI v2
# ---------------------------------------------------------------------------
wget -q --show-progress \
    "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_CLI}.zip" \
    -O /tmp/awscliv2.zip

unzip -q /tmp/awscliv2.zip -d /tmp/awscli
/tmp/awscli/aws/install
rm -rf /tmp/awscliv2.zip /tmp/awscli

# ---------------------------------------------------------------------------
# SSM Session Manager Plugin
# ---------------------------------------------------------------------------
SSM_BASE_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${ARCH_SSM}"

wget -q --show-progress \
    "${SSM_BASE_URL}/session-manager-plugin.deb" \
    -O /tmp/session-manager-plugin.deb

dpkg -i /tmp/session-manager-plugin.deb
rm -f /tmp/session-manager-plugin.deb