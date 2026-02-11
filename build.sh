#!/bin/bash
set -e

# Load environment variables
source "$(dirname "$0")/env.sh"

# Parse command line arguments
# $1: KERNEL_COMPILER (optional, e.g., "aarch64-none-linux-gnu-", defaults to env.sh value)
# $2: KERNEL_SRC path (optional, defaults to env.sh value)

if [ -n "$1" ]; then
    KERNEL_COMPILER="$1"
    echo "Info: Using custom KERNEL_COMPILER: $KERNEL_COMPILER"
fi

if [ -n "$2" ]; then
    KERNEL_SRC="$2"
    echo "Info: Using custom KERNEL_SRC: $KERNEL_SRC"
fi

# Build the full CROSS_COMPILE with CCACHE if needed
if [ -n "$CCACHE" ]; then
    CROSS_COMPILE="$CCACHE $KERNEL_COMPILER"
else
    CROSS_COMPILE="$KERNEL_COMPILER"
fi

WORK_DIR=$(dirname "$(readlink -f "$0")")
SOURCE_DIR="$WORK_DIR/ethercat"
OUTPUT_DIR="$WORK_DIR/output"
INSTALL_DIR="$OUTPUT_DIR/_install"
MODULES_DIR="$OUTPUT_DIR/_modules"

# Check directories
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory $SOURCE_DIR not found."
    exit 1
fi

echo "=== Environment Info ==="
echo "Work Dir:    $WORK_DIR"
echo "Source Dir:  $SOURCE_DIR"
echo "Kernel Src:  $KERNEL_SRC"
echo "Compiler:    ${CROSS_COMPILE}gcc"
echo "========================"

# --- Go to source dir ---
pushd "$SOURCE_DIR"

echo "[1/5] Cleanup..."
make clean >/dev/null 2>&1 || true
make distclean >/dev/null 2>&1 || true
rm -rf "$OUTPUT_DIR"

echo "[2/5] Configure..."
./bootstrap
./configure \
    --host=aarch64-none-linux-gnu \
    --enable-kernel \
    --enable-generic \
    --enable-igb \
    --disable-eoe \
    --enable-hrtimer \
    --with-systemdsystemunitdir="/lib/systemd/system" \
    --prefix="${PREFIX}" \
    --with-linux-dir="$KERNEL_SRC" \
    --sysconfdir=/etc \
    CC="${CROSS_COMPILE}gcc" \
    CXX="${CROSS_COMPILE}g++" \
    AR="${CROSS_COMPILE}ar" \
    LD="${CROSS_COMPILE}ld" \
    STRIP="${CROSS_COMPILE}strip"

echo "[3/5] Build..."
# Build User Space Libs & Tools
make -j$(nproc)
# Build Kernel Modules
make modules -j$(nproc)

echo "[4/5] Install..."
# Install User Space
make install DESTDIR="$INSTALL_DIR"
# Install Kernel Modules
make modules_install INSTALL_MOD_PATH="$MODULES_DIR"

# Strip binaries to reduce size
find "$INSTALL_DIR" -type f -exec "${CROSS_COMPILE}strip" {} \; 2>/dev/null || true
find "$MODULES_DIR" -name "*.ko" -exec "${CROSS_COMPILE}strip" --strip-debug {} \; 2>/dev/null || true

popd # Back to WORK_DIR

echo "[5/5] Packaging DEB..."
DEB_BUILD_DIR="$OUTPUT_DIR/package"

mkdir -p "$DEB_BUILD_DIR"

# 5.1 Copy Install Files (Move from /opt/ethercat inside DESTDIR to root of package)
# Automake install with DESTDIR creates full path structure, e.g. output/_install/opt/ethercat/...
# We want this structure in the package.
cp -r "$INSTALL_DIR"/* "$DEB_BUILD_DIR/"

# 5.1.1 Config Fix: Adjust config file path and content
# With --sysconfdir=/etc, it should be in $DEB_BUILD_DIR/etc/ethercat.conf
# But if it ended up in $DEB_BUILD_DIR$PREFIX/etc/ethercat.conf, we move it.
CONFIG_FILE="$DEB_BUILD_DIR/etc/ethercat.conf"
PREFIX_CONFIG_FILE="$DEB_BUILD_DIR${PREFIX}/etc/ethercat.conf"

if [ -f "$PREFIX_CONFIG_FILE" ]; then
    echo "Moving config file from prefix to /etc/..."
    mkdir -p "$DEB_BUILD_DIR/etc"
    mv "$PREFIX_CONFIG_FILE" "$CONFIG_FILE"
    rmdir "$DEB_BUILD_DIR${PREFIX}/etc" 2>/dev/null || true
fi

if [ -f "$CONFIG_FILE" ]; then
    echo "Configuring ethercat.conf..."
    # Config Fix for igb driver
    sed -i 's/^MASTER0_DEVICE=""/MASTER0_DEVICE="enP3p49s0"/' "$CONFIG_FILE"
    sed -i 's/^DEVICE_MODULES=""/DEVICE_MODULES="igb"/' "$CONFIG_FILE"
else
    echo "Warning: ethercat.conf not found in package!"
fi

# 5.2 Copy Modules
if [ -d "$MODULES_DIR/lib" ]; then
    # Remove unnecessary files to prevent conflicts
    find "$MODULES_DIR" -name "modules.alias" -type f -delete
    find "$MODULES_DIR" -name "modules.alias.bin" -type f -delete
    find "$MODULES_DIR" -name "modules.dep" -type f -delete
    find "$MODULES_DIR" -name "modules.dep.bin" -type f -delete
    find "$MODULES_DIR" -name "modules.softdep" -type f -delete
    find "$MODULES_DIR" -name "modules.symbols" -type f -delete
    find "$MODULES_DIR" -name "modules.symbols.bin" -type f -delete
    find "$MODULES_DIR" -name "modules.builtin.bin" -type f -delete
    find "$MODULES_DIR" -name "modules.builtin.alias.bin" -type f -delete
    find "$MODULES_DIR" -name "modules.devname" -type f -delete

    mkdir -p "$DEB_BUILD_DIR/lib"
    cp -r "$MODULES_DIR/lib" "$DEB_BUILD_DIR/"
fi

# 5.3 Copy DEBIAN control files
mkdir -p "$DEB_BUILD_DIR/DEBIAN"
cp -r "$WORK_DIR/debian/DEBIAN/"* "$DEB_BUILD_DIR/DEBIAN/"
chmod 755 "$DEB_BUILD_DIR/DEBIAN/post"* "$DEB_BUILD_DIR/DEBIAN/pre"* 2>/dev/null || true

# Get built kernel version
KERNEL_SUFFIX=""
if [ -d "$MODULES_DIR/lib/modules" ]; then
    BUILD_KERNEL_VER=$(ls "$MODULES_DIR/lib/modules/" | head -n 1)
    if [ -n "$BUILD_KERNEL_VER" ]; then
        KERNEL_SUFFIX="_${BUILD_KERNEL_VER}"
        echo "Detected built kernel version: $BUILD_KERNEL_VER"
    fi
fi

# 5.4 Generate Control File if missing
if [ ! -f "$DEB_BUILD_DIR/DEBIAN/control" ]; then
    echo "Generating basic control file..."
    cat <<EOF > "$DEB_BUILD_DIR/DEBIAN/control"
Package: ${PACKAGE_NAME}
Version: ${DEB_VERSION}${KERNEL_SUFFIX//_/-}
Architecture: arm64
Maintainer: Flora <2321901849@qq.com>
Description: IgH EtherCAT Master (Kernel ${BUILD_KERNEL_VER})
EOF
fi

# 5.5 Build DEB
DEB_NAME="${PACKAGE_NAME}_${DEB_VERSION}${KERNEL_SUFFIX}_arm64.deb"
dpkg-deb --build "$DEB_BUILD_DIR" "$OUTPUT_DIR/${DEB_NAME}"

echo "=== Build Success! ==="
echo "Package: $OUTPUT_DIR/${DEB_NAME}"
