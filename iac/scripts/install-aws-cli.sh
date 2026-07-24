#!/bin/sh
# install-aws-cli.sh
# Installs the AWS CLI v2 and the SSM Session Manager Plugin.
#
# AWS CLI v2: downloaded from the official awscli.amazonaws.com endpoint and
# verified via its detached PGP signature against AWS's published public key
# (pinned fingerprint), per:
#   https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
#
# SSM Session Manager Plugin: downloaded over HTTPS from the official AWS S3
# bucket. AWS does not publish a checksum or signature sidecar for this
# artifact (confirmed against the plugin install/verify docs and the
# aws/session-manager-plugin GitHub releases), so no further integrity
# check is possible here beyond TLS.
#
# Dependencies: wget, unzip, dpkg, gpg

set -eu

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
# Temporary directory (cleaned up on exit)
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# AWS CLI v2 — download + PGP signature verification
# ---------------------------------------------------------------------------
AWS_CLI_ZIP="${TMP_DIR}/awscliv2.zip"
AWS_CLI_SIG="${TMP_DIR}/awscliv2.zip.sig"
AWS_CLI_KEY_FILE="${TMP_DIR}/aws-cli-public-key.asc"
AWS_CLI_KEYRING="${TMP_DIR}/aws-cli.gpg"

# Pinned fingerprint of the "AWS CLI Team <aws-cli@amazon.com>" signing key.
# Source: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
EXPECTED_FINGERPRINT="FB5DB77FD5C118B80511ADA8A6310ACC4672475C"

echo "Downloading AWS CLI v2 (${ARCH_CLI}) ..."
wget -q "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_CLI}.zip" -O "${AWS_CLI_ZIP}"
wget -q "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH_CLI}.zip.sig" -O "${AWS_CLI_SIG}"

cat > "${AWS_CLI_KEY_FILE}" <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBF2Cr7UBEADJZHcgusOJl7ENSyumXh85z0TRV0xJorM2B/JL0kHOyigQluUG
ZMLhENaG0bYatdrKP+3H91lvK050pXwnO/R7fB/FSTouki4ciIx5OuLlnJZIxSzx
PqGl0mkxImLNbGWoi6Lto0LYxqHN2iQtzlwTVmq9733zd3XfcXrZ3+LblHAgEt5G
TfNxEKJ8soPLyWmwDH6HWCnjZ/aIQRBTIQ05uVeEoYxSh6wOai7ss/KveoSNBbYz
gbdzoqI2Y8cgH2nbfgp3DSasaLZEdCSsIsK1u05CinE7k2qZ7KgKAUIcT/cR/grk
C6VwsnDU0OUCideXcQ8WeHutqvgZH1JgKDbznoIzeQHJD238GEu+eKhRHcz8/jeG
94zkcgJOz3KbZGYMiTh277Fvj9zzvZsbMBCedV1BTg3TqgvdX4bdkhf5cH+7NtWO
lrFj6UwAsGukBTAOxC0l/dnSmZhJ7Z1KmEWilro/gOrjtOxqRQutlIqG22TaqoPG
fYVN+en3Zwbt97kcgZDwqbuykNt64oZWc4XKCa3mprEGC3IbJTBFqglXmZ7l9ywG
EEUJYOlb2XrSuPWml39beWdKM8kzr1OjnlOm6+lpTRCBfo0wa9F8YZRhHPAkwKkX
XDeOGpWRj4ohOx0d2GWkyV5xyN14p2tQOCdOODmz80yUTgRpPVQUtOEhXQARAQAB
tCFBV1MgQ0xJIFRlYW0gPGF3cy1jbGlAYW1hem9uLmNvbT6JAlQEEwEIAD4CGwMF
CwkIBwIGFQoJCAsCBBYCAwECHgECF4AWIQT7Xbd/1cEYuAURraimMQrMRnJHXAUC
akV0ygUJDqP4lQAKCRCmMQrMRnJHXFHjD/9eyZLYcKuQOlLvtqSDtUBiEZf6ZZjM
i3ygYH8rJNtuToUH+HvSpe819urJCquXhDrlK6N+aqW0hCLtNABJG/vsafIgvIYJ
hSGgpgtNnQyMV1jViRWqPjbouw8OkYKBThUfT1i2Y+wn58ifs6ODBCmTexWtXspA
Si+Gt49xDOW0APmbOPnI+a4HJW6tVEo6MWS0WjzpiBayR3d1A4pt4YrPfSdDgpLo
h2SLQqlRqvvVZJaWBjhkErNFpfsBA06sDcPEOb0G8LBUbR4WOcdvhe5LubJbZuxC
AG9kNPCVeQP1ixwjgjXKysaxeQ6rv0VzIQgRp6tLVLWhy6AKDNvLjFSsmXZ1Wl08
Y/RlOHXlzLuQMRE6sR1wOdRxc9TsrNWTGiBK65cvSWOy03JeBkQQ8pesqltiyxI9
U21kkgiXtTSKNGfKK8pO27D81YANhRqPK7iTp6kuFiY2WtOg90KTMNlIT+Ff85Y2
b1rHj6Z0SrCkJujhWk3IBPic/wJgz01LEc/OAdUPlby90RJZcIBhSlWhT7mXnXIO
c0HWlNQrns2s3CTyYwZSiSlYe9ApeLwhjDo8NhbFuCAy61l6O5UsR4AfZxx/rGKv
2wFb1/RN/P4gNe6vmxZAPjR0AQcwD3tc2McimOLr/22kmPz8IH3I0X7WoSFr0Biz
E91G7bb0hOb/cA==
=knv7
-----END PGP PUBLIC KEY BLOCK-----
EOF

gpg --dearmor < "${AWS_CLI_KEY_FILE}" > "${AWS_CLI_KEYRING}" 2>/dev/null || {
    echo "ERROR: Failed to import AWS CLI release signing key" >&2
    exit 1
}

ACTUAL_FINGERPRINT="$(
    gpg --no-default-keyring --keyring "${AWS_CLI_KEYRING}" \
        --with-colons --fingerprint 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}'
)"

if [ "${ACTUAL_FINGERPRINT}" != "${EXPECTED_FINGERPRINT}" ]; then
    echo "ERROR: AWS CLI release-key fingerprint mismatch" >&2
    echo "  Expected: ${EXPECTED_FINGERPRINT}" >&2
    echo "  Got:      ${ACTUAL_FINGERPRINT}" >&2
    exit 1
fi
echo "OK: AWS CLI release-key fingerprint matches: ${ACTUAL_FINGERPRINT}"

gpg --no-default-keyring --keyring "${AWS_CLI_KEYRING}" \
    --verify "${AWS_CLI_SIG}" "${AWS_CLI_ZIP}" 2>/dev/null || {
    echo "ERROR: PGP signature verification failed for awscliv2.zip" >&2
    exit 1
}
echo "OK: PGP signature verified: awscliv2.zip"

unzip -q "${AWS_CLI_ZIP}" -d "${TMP_DIR}/awscli"
"${TMP_DIR}/awscli/aws/install"

# ---------------------------------------------------------------------------
# SSM Session Manager Plugin
# ---------------------------------------------------------------------------
SSM_BASE_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${ARCH_SSM}"
SSM_DEB="${TMP_DIR}/session-manager-plugin.deb"

echo "Downloading SSM Session Manager Plugin (${ARCH_SSM}) ..."
wget -q "${SSM_BASE_URL}/session-manager-plugin.deb" -O "${SSM_DEB}"
dpkg -i "${SSM_DEB}"
