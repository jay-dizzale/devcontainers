#!/bin/sh
# install-kafka.sh
# Installs Apache Kafka client binaries (bin/ + config/ + libs/) and the
# AWS MSK IAM Auth JAR for connecting to MSK clusters with IAM authentication.
# Versions are expected via ARG/ENV:
#   KAFKA_VERSION           e.g. 4.1.0
#   KAFKA_SCALA_VERSION     e.g. 2.13  (default)
#   MSK_IAM_AUTH_VERSION    e.g. 2.3.5
# Apache Kafka publishes a .sha512 sidecar; aws-msk-iam-auth publishes a .sha256 sidecar.
# Dependencies: wget, sha256sum, sha512sum, tar

. /usr/local/lib/shell/download-utils.sh

KAFKA_VERSION="${KAFKA_VERSION:-}"
if [ -z "${KAFKA_VERSION}" ]; then
    echo "Resolving latest stable Kafka release ..."
    KAFKA_VERSION="$(github_latest_stable apache/kafka)"
    [ -n "${KAFKA_VERSION}" ] || { echo "ERROR: could not resolve latest Kafka version" >&2; exit 1; }
fi
KAFKA_SCALA_VERSION="${KAFKA_SCALA_VERSION:-2.13}"
MSK_IAM_AUTH_VERSION="${MSK_IAM_AUTH_VERSION:-}"
if [ -z "${MSK_IAM_AUTH_VERSION}" ]; then
    echo "Resolving latest stable aws-msk-iam-auth release ..."
    MSK_IAM_AUTH_VERSION="$(github_latest_stable aws/aws-msk-iam-auth)"
    [ -n "${MSK_IAM_AUTH_VERSION}" ] || { echo "ERROR: could not resolve latest msk-iam-auth version" >&2; exit 1; }
fi

KAFKA_TARBALL="kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}.tgz"
KAFKA_DIR="kafka_${KAFKA_SCALA_VERSION}-${KAFKA_VERSION}"
KAFKA_INSTALL_DIR="/opt/kafka"

# dlcdn.apache.org only hosts the current release — older versions live on
# archive.apache.org. Try dlcdn first and fall back transparently.
KAFKA_CDN_URL="https://dlcdn.apache.org/kafka/${KAFKA_VERSION}/${KAFKA_TARBALL}"
KAFKA_ARCHIVE_URL="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${KAFKA_TARBALL}"

if wget -q --spider "${KAFKA_CDN_URL}" 2>/dev/null; then
    KAFKA_URL="${KAFKA_CDN_URL}"
    echo "Using CDN mirror for Kafka ${KAFKA_VERSION}"
else
    KAFKA_URL="${KAFKA_ARCHIVE_URL}"
    echo "CDN mirror unavailable, using archive for Kafka ${KAFKA_VERSION}"
fi

MSK_IAM_JAR="aws-msk-iam-auth-${MSK_IAM_AUTH_VERSION}-all.jar"
MSK_IAM_BASE_URL="https://github.com/aws/aws-msk-iam-auth/releases/download/v${MSK_IAM_AUTH_VERSION}"
MSK_IAM_URL="${MSK_IAM_BASE_URL}/${MSK_IAM_JAR}"
MSK_IAM_SHA256_URL="${MSK_IAM_URL}.sha256"

# ---------------------------------------------------------------------------
# Kafka: download & verify via SHA512 sidecar
# Apache's .sha512 format is "FILENAME: HASH_SPLIT\nACROSS\nLINES" —
# strip the "filename:" prefix and all whitespace to get the plain hex hash.
# ---------------------------------------------------------------------------
echo "Fetching SHA512 for kafka ${KAFKA_VERSION} ..."
KAFKA_SHA512="$(wget -qO- "${KAFKA_URL}.sha512" \
    | tr -d ' \n\r' \
    | sed 's/^[^:]*://')" || {
    echo "ERROR: Could not fetch SHA512 for kafka ${KAFKA_VERSION}" >&2
    exit 1
}

download_file "${KAFKA_URL}" "/tmp/${KAFKA_TARBALL}" || exit 1

verify_sha512 "/tmp/${KAFKA_TARBALL}" "${KAFKA_SHA512}" "kafka ${KAFKA_VERSION}" || {
    rm -f "/tmp/${KAFKA_TARBALL}"
    exit 1
}

# ---------------------------------------------------------------------------
# Kafka: extract client binaries only (bin/ + config/ + libs/)
# ---------------------------------------------------------------------------
mkdir -p "${KAFKA_INSTALL_DIR}"

tar -xzf "/tmp/${KAFKA_TARBALL}" \
    --strip-components=1 \
    -C "${KAFKA_INSTALL_DIR}" \
    "${KAFKA_DIR}/bin" \
    "${KAFKA_DIR}/config" \
    "${KAFKA_DIR}/libs"

rm -f "/tmp/${KAFKA_TARBALL}"
echo "OK: Kafka ${KAFKA_VERSION} client binaries installed to ${KAFKA_INSTALL_DIR}"

# ---------------------------------------------------------------------------
# MSK IAM Auth JAR: download & verify via SHA256 sidecar
# ---------------------------------------------------------------------------
echo "Fetching MSK IAM Auth SHA256 checksum ..."
MSK_IAM_SHA256="$(wget -qO- "${MSK_IAM_SHA256_URL}" | awk '{print $1}')" || {
    echo "ERROR: Could not fetch SHA256 for aws-msk-iam-auth ${MSK_IAM_AUTH_VERSION}" >&2
    exit 1
}

download_and_verify "${MSK_IAM_URL}" "/tmp/${MSK_IAM_JAR}" "${MSK_IAM_SHA256}"

mv "/tmp/${MSK_IAM_JAR}" "${KAFKA_INSTALL_DIR}/libs/${MSK_IAM_JAR}"
echo "OK: aws-msk-iam-auth ${MSK_IAM_AUTH_VERSION} installed to ${KAFKA_INSTALL_DIR}/libs/"

# ---------------------------------------------------------------------------
# MSK IAM client.properties
# ---------------------------------------------------------------------------
cat > "${KAFKA_INSTALL_DIR}/config/client.properties" << 'PROPS'
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
PROPS

echo "OK: MSK IAM client.properties written to ${KAFKA_INSTALL_DIR}/config/client.properties"