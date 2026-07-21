#!/bin/sh
# install-pico-toolchain.sh
# Full RP2040 / Pico SDK toolchain setup for a Debian/Ubuntu-based Docker container

set -eu
. /usr/local/lib/shell/download-utils.sh

PICO_SDK_VERSION="${1:-${PICO_SDK_VERSION:-}}"
if [ -z "${PICO_SDK_VERSION}" ]; then
    echo "Resolving latest stable Pico SDK release ..."
    PICO_SDK_VERSION="$(github_latest_stable raspberrypi/pico-sdk)"
    [ -n "${PICO_SDK_VERSION}" ] || { echo "ERROR: could not resolve latest Pico SDK version" >&2; exit 1; }
fi
INSTALL_DIR="/opt/pico"

echo "==> [1/6] Installing system dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    ca-certificates \
    cmake \
    ninja-build \
    build-essential \
    gcc \
    g++ \
    libstdc++-arm-none-eabi-newlib \
    gcc-arm-none-eabi \
    libnewlib-arm-none-eabi \
    libusb-1.0-0-dev \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv \
    python3-serial \
    minicom \
    usbutils \
    unzip
rm -rf /var/lib/apt/lists/*

echo "==> [2/6] Verifying ARM toolchain..."
arm-none-eabi-gcc --version
arm-none-eabi-g++ --version
arm-none-eabi-objcopy --version

echo "==> [3/6] Cloning Pico SDK v${PICO_SDK_VERSION}..."
mkdir -p "${INSTALL_DIR}"
git clone \
    --branch "${PICO_SDK_VERSION}" \
    --depth 1 \
    https://github.com/raspberrypi/pico-sdk.git \
    "${INSTALL_DIR}/pico-sdk"

git -C "${INSTALL_DIR}/pico-sdk" submodule update --init --depth 1

echo "==> [4/6] Cloning Pico extras & examples..."
git clone \
    --depth 1 \
    https://github.com/raspberrypi/pico-extras.git \
    "${INSTALL_DIR}/pico-extras"

git clone \
    --depth 1 \
    https://github.com/raspberrypi/pico-examples.git \
    "${INSTALL_DIR}/pico-examples"

echo "==> [5/6] Installing picotool..."
git clone \
    --depth 1 \
    https://github.com/raspberrypi/picotool.git \
    "${INSTALL_DIR}/picotool"

cmake \
    -S "${INSTALL_DIR}/picotool" \
    -B "${INSTALL_DIR}/picotool/build" \
    -DPICO_SDK_PATH="${INSTALL_DIR}/pico-sdk" \
    -DCMAKE_BUILD_TYPE=Release \
    -G Ninja

NPROC=1
if command -v nproc > /dev/null 2>&1; then
    NPROC=$(nproc)
elif command -v getconf > /dev/null 2>&1; then
    NPROC=$(getconf _NPROCESSORS_ONLN)
fi

cmake --build "${INSTALL_DIR}/picotool/build" --parallel "${NPROC}"
install -m 755 "${INSTALL_DIR}/picotool/build/picotool" /usr/local/bin/picotool

echo "==> [6/6] Writing environment variables..."
# NOTE: /etc/profile.d/ is not sourced in Docker RUN steps (non-login shells).
# Set these as ENV in your Dockerfile instead:
#   ENV PICO_SDK_PATH=/opt/pico/pico-sdk \
#       PICO_EXTRAS_PATH=/opt/pico/pico-extras \
#       PICO_EXAMPLES_PATH=/opt/pico/pico-examples
export PICO_SDK_PATH="${INSTALL_DIR}/pico-sdk"
export PICO_EXTRAS_PATH="${INSTALL_DIR}/pico-extras"
export PICO_EXAMPLES_PATH="${INSTALL_DIR}/pico-examples"

ARM_GCC_VER=$(arm-none-eabi-gcc --version | head -1)
PICOTOOL_VER=$(picotool version)

echo ""
echo "======================================================"
echo " RP2040 toolchain ready!"
echo " PICO_SDK_PATH  = ${PICO_SDK_PATH}"
echo " ARM GCC        = ${ARM_GCC_VER}"
echo " picotool       = ${PICOTOOL_VER}"
echo "======================================================"
echo ""
echo "Quick-start: build the 'blink' example"
echo "  mkdir -p /tmp/blink-build && cd /tmp/blink-build"
echo "  cmake \${PICO_EXAMPLES_PATH}/blink -DPICO_BOARD=pico"
echo "  make -j${NPROC}"
echo "  # produces blink.uf2 -> drag to Pico in BOOTSEL mode"