#!/bin/bash

# Toolchain Path
export CROSS_COMPILE=${CROSS_COMPILE:-/home/flora/orangepi-build/toolchains/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-}
export ARCH="arm64"

# Kernel Source Path
export KERNEL_SRC="${KERNEL_SRC:-/home/flora/orangepi-build/kernel/orange-pi-6.1-rk35xx}"

# Package Information
export PACKAGE_NAME="ethercat-igh"
export DEB_VERSION="1.6"

# Install Paths
export PREFIX="/opt/ethercat"
