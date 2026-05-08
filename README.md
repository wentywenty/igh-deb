# ethercat-igh

This repository is used to build the IgH EtherCAT Master (including user-space tools and cross-compiled kernel modules), generating Debian packages for robots and other target systems.

## Directory Structure

- `ethercat/`: IgH EtherCAT source code submodule.
- `debian/`: Debian packaging configurations (control, rules, etc.) and maintainer scripts.

## Initialization

Ensure you have initialized and updated the submodule code:
```bash
git submodule update --init --recursive
```

## Dependencies

Install the necessary build tools on your host OS:
```bash
sudo apt install build-essential debhelper autoconf automake libtool pkg-config
```

## Local & Cross Compilation

The package is configured by default to cross-compile for `aarch64`. Modify the `env.sh` file to specify your **cross-compiler path** and **kernel source path**:

```bash
# e.g., in env.sh
export CROSS_COMPILE=/path/to/gcc-arm-.../bin/aarch64-none-linux-gnu-
export KERNEL_SRC=/path/to/orange-pi-kernel-source
```

> **Note**: Your kernel source (`KERNEL_SRC`) must be **pre-compiled** (i.e. it must have a `.config` and compiled objects in the source tree), otherwise the kernel modules cannot be successfully built.

Load the environment variables and run the native Debian build command:

```bash
source env.sh
dpkg-buildpackage -us -uc -b -aarm64
```

These parameters can also be dynamically injected via CI pipelines during the build process without modifying the script.

## Artifact Location

The final `.deb` artifacts will be output to the parent directory (sibling to `igh-deb`), dynamically bearing the kernel version signifier:

```bash
../ethercat-igh_<version>-<kernel_version>_arm64.deb
```

## Installation & Setup

After transferring and installing the `.deb` package on the target device:

```bash
sudo dpkg -i ethercat-igh_*_arm64.deb
```

The installation includes `/lib/systemd/system/ethercat-first-boot.service`, which automatically executes `depmod -a` and resolves module dependencies during the first system boot. 

If you need to change your specific network device (default `enP3p49s0` or `eth0`), edit the configuration:
```bash
sudo nano /etc/ethercat.conf
```
And restart the service:
```bash
sudo systemctl restart ethercat
```
