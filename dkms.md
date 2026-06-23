# IgH EtherCAT Master DKMS 化方案

## 1. 目标

将当前 `ethercat-igh` deb 包从「构建时交叉编译、内核版本锁死」的方式改为 DKMS（Dynamic Kernel Module Support）方式，实现：

- **内核升级时模块自动重编译**，无需手动迁移 `.ko` 文件
- **解除包版本与内核版本的绑定**（当前包名如 `ethercat-igh_1.7.1-6.1.99-rt36-rockchip-rk3588_arm64.deb`）
- **目标机本地编译**，不再依赖构建机上的交叉工具链和完整内核源码树

## 2. 架构对比

### 当前方式

```
构建机 (x86)                             目标机 (arm64)
┌─────────────────────────┐              ┌─────────────────────────┐
│ KERNEL_SRC=             │              │ dpkg -i xxx.deb         │
│   /opt/.../orange-pi-   │  交叉编译    │                          │
│   6.1-rk35xx (完整源码)  │─────────────▶│ /lib/modules/6.1.99-rt/  │
│                         │  产出 .ko    │   ethercat/             │
│ CROSS_COMPILE=          │              │   ├── ec_master.ko      │
│   aarch64-...-gnu-      │              │   ├── ec_generic.ko     │
│                         │              │   └── ec_igb.ko         │
│ ./configure --with-     │              │                          │
│   linux-dir=...         │              │ postinst hack:           │
│ make modules            │              │   内核版本不匹配时        │
│                         │              │   手动拷贝模块           │
└─────────────────────────┘              └─────────────────────────┘

问题:
  1. 内核更新后模块直接失效
  2. postinst 用 cp 迁移模块是 hack
  3. 包名跟内核版本强耦合
```

### DKMS 方式

```
构建机 (任意架构)                        目标机 (arm64)
┌─────────────────────────┐              ┌─────────────────────────┐
│ 预处理:                  │              │ dpkg -i ethercat-dkms*  │
│   Kbuild.in → Kbuild     │              │                          │
│   config.h (预生成)      │   产出       │ /usr/src/ethercat-1.7.1/ │
│   顶层 Makefile          │─────────────▶│   ├── dkms.conf          │
│   dkms.conf              │   .deb       │   ├── Makefile           │
│                         │  (Arch: all) │   ├── config.h           │
│ 打包用户态:              │              │   ├── Kbuild             │
│   libethercat.so         │              │   ├── master/            │
│   ethercat 命令          │   产出       │   └── devices/           │
│   配置/服务文件           │─────────────▶│                          │
│                         │   .deb       │ DKMS 自动:               │
│                         │  (Arch:arm64)│   │ 内核安装/更新时       │
│                         │              │   │ make -C /lib/modules/ │
│                         │              │   │   $(kv)/build M=$PWD  │
│                         │              │   │ 自动编译安装          │
└─────────────────────────┘              └─────────────────────────┘

依赖: linux-headers-$(uname -r) (目标机安装)
```

## 3. 需要解决的核心问题

### 3.1 去掉 autotools 运行时依赖

所有 `Kbuild.in` 文件包含 autoconf 的 `@variable@` 占位符，需要在 **构建机打包时** 一次性替换为静态值，使得目标机上直接可用 `make` 构建，无需运行 `./configure`。

涉及的替换变量：

| `@variable@` | 来源 | DKMS 化方式 |
|---|---|---|
| `@abs_srcdir@` | configure 生成 | 替换为 `$(src)`（Kbuild 内置变量） |
| `@abs_top_builddir@` | configure 生成 | 替换为 Kbuild 内置路径 |
| `@ENABLE_GENERIC@` | `--enable-generic` | 硬编码为 `1` 或通过 make 变量传入 |
| `@ENABLE_IGB@` | `--enable-igb` | 硬编码为 `1` |
| `@ENABLE_EOE@` | `--enable-eoe` | 硬编码为 `0`（当前用了 `--disable-eoe`） |
| `@ENABLE_HRTIMER@` | `--enable-hrtimer` | 需在 `config.h` 中定义 `EC_USE_HRTIMER` |
| `@ENABLE_RTDM@` | Xenomai/RTAI | 硬编码为 `0`（当前未启用） |
| `@LINUX_SYMVERS@` | configure 探测 | 替换为 `Module.symvers` |
| `@KERNEL_E100@` 等 | 内核版本匹配 | 在 Makefile 中根据目标内核版本选择 |
| `@ENABLE_DEBUG_IF@` | debug | 硬编码为 `0` |

### 3.2 生成 config.h

内核模块通过以下引用链依赖 `config.h`：

```
master/globals.h → ../globals.h → config.h
```

`config.h` 定义了编译时特性宏：

```c
#define EC_USE_HRTIMER     // --enable-hrtimer
#define EC_HAVE_CYCLES     1  // 硬件 TSC
#define EC_MAX_NUM_DEVICES 1  // 最大设备数
#define EC_IDENT_WILDCARDS 1  // Vendor/Product 通配符
#define EC_REGALIAS        1  // 别名地址
// #undef EC_EOE          // --disable-eoe
// #undef EC_RTDM         // 无 Xenomai/RTAI
// #undef EC_DEBUG_IF     // 无调试接口
// #undef EC_SII_ASSIGN   // 无 SII 分配
// #undef EC_RT_SYSLOG    // 无 RT 日志
```

需要按目标配置预生成一份 `config.h`，包含在 dkms 源码包中。

### 3.3 版本特定驱动文件选择

部分驱动（e100, e1000, e1000e, r8169, 8139too）有内核版本特定的 `.c` 文件：

```
devices/
├── e100-2.6.24-ethercat.c
├── e100-2.6.26-ethercat.c
├── e100-2.6.27-ethercat.c
├── ...
├── r8169-4.4-ethercat.c
├── r8169-4.15-ethercat.c
├── ...
```

`configure.ac` 通过扫描文件名并匹配目标内核版本来选择。在 DKMS 中，需要在内核模块 Makefile 中根据当前构建内核的版本执行等效选择逻辑。

**当前启用的驱动**（igb 和 generic）**不涉及版本特定文件**，这个问题主要影响未来扩展。但需要在 DKMS Makefile 中预留处理机制。

## 4. 文件变更清单

### 4.1 新增文件

| 文件 | 说明 |
|---|---|
| `dkms.conf` | DKMS 配置文件，定义模块名、构建命令、安装路径 |
| `Makefile`（顶层包装） | DKMS 调用的入口 Makefile，设置宏并委托给 Kbuild |
| `config.h`（预生成） | 替代配置完成后生成的 `config.h` |
| `debian/control` 新增条目 | `Package: ethercat-dkms` 包定义 |
| `debian/ethercat-dkms.install` | dkms 包的安装清单 |
| `debian/ethercat-dkms.postinst` | 触发 `dkms add/build/install` |
| `debian/ethercat-dkms.prerm` | 触发 `dkms remove` |

### 4.2 修改文件

| 文件 | 变更 |
|---|---|
| `debian/rules` | 新增 Kbuild.in→Kbuild 转换步骤；新增 dkms 包构建；去掉内核模块构建和安装步骤；去掉 gencontrol 内核版本注入 |
| `debian/control` | 新增 `ethercat-dkms` 包定义；`ethercat-igh` 增加 `Recommends: ethercat-dkms` |
| `ethercat/master/Kbuild.in` | 先转为静态 `Kbuild`（或保留 `.in`，在 rules 中生成 `Kbuild`） |
| `ethercat/devices/Kbuild.in` | 同上 |
| `ethercat/devices/*/Kbuild.in` | 同上 |
| `ethercat/Kbuild.in` | 同上 |
| `ethercat/tty/Kbuild.in` | 同上 |
| `debian/postinst` | 删除模块迁移 hack；删除内核模块安装后的 depmod 逻辑 |
| `debian/postrm` | 删除内核模块清理逻辑 |

### 4.3 保留不变的文件

| 文件 | 说明 |
|---|---|
| `ethercat/` 下所有 `*.c` / `*.h` | 源码不变 |
| `ethercat/configure.ac` | 保留，但仅用于构建用户态（或可在 dkms 场景下完全绕过） |
| `ethercat/lib/` | 用户态库，打包为 `ethercat-igh` |
| `ethercat/tool/` | 命令行工具，打包为 `ethercat-igh` |
| `ethercat/script/` | systemd 服务等，打包为 `ethercat-igh` |
| `debian/ethercat_init.sh` | first-boot 脚本，保留但简化（去掉模块迁移部分） |
| `debian/ethercat-first-boot.service` | 保留 |

## 5. 关键文件设计

### 5.1 dkms.conf

```ini
PACKAGE_NAME="ethercat"
PACKAGE_VERSION="1.7.1"

MAKE[0]="make -C /lib/modules/$kernelver/build M=$PWD CPPFLAGS='-DEC_USE_HRTIMER -DEC_HAVE_CYCLES -DEC_IDENT_WILDCARDS -DEC_REGALIAS -DEC_MAX_NUM_DEVICES=1'"
CLEAN="make -C /lib/modules/$kernelver/build M=$PWD clean"

BUILT_MODULE_NAME[0]="ec_master"
BUILT_MODULE_LOCATION[0]="master/"
DEST_MODULE_LOCATION[0]="/kernel/drivers/ethercat"

BUILT_MODULE_NAME[1]="ec_generic"
BUILT_MODULE_LOCATION[1]="devices/"
DEST_MODULE_LOCATION[1]="/kernel/drivers/ethercat"

BUILT_MODULE_NAME[2]="ec_igb"
BUILT_MODULE_LOCATION[2]="devices/igb/"
DEST_MODULE_LOCATION[2]="/kernel/drivers/ethercat"

# 可选：示例模块
# BUILT_MODULE_NAME[3]="ec_example"
# BUILT_MODULE_LOCATION[3]="examples/mini/"
# DEST_MODULE_LOCATION[3]="/kernel/drivers/ethercat"

AUTOINSTALL="yes"
```

### 5.2 顶层包装 Makefile（放在 ethercat/ 目录）

```makefile
# DKMS wrapper Makefile - delegates to Kbuild
# Placed at: ethercat/Makefile (for dkms source tree)

# Feature flags (overridable by dkms MAKE command)
EC_USE_HRTIMER ?= 1
EC_HAVE_CYCLES  ?= 1
EC_IDENT_WILDCARDS ?= 1
EC_REGALIAS     ?= 1
EC_MAX_NUM_DEVICES ?= 1

# Convert to -D flags for compiler
DKMS_CPPFLAGS = \
	-DEC_USE_HRTIMER \
	-DEC_HAVE_CYCLES \
	-DEC_IDENT_WILDCARDS \
	-DEC_REGALIAS \
	-DEC_MAX_NUM_DEVICES=$(EC_MAX_NUM_DEVICES)

default: modules

modules:
	$(MAKE) -C /lib/modules/$(KERNELRELEASE)/build M=$(PWD) \
		ccflags-y="$(DKMS_CPPFLAGS)" modules

modules_install:
	$(MAKE) -C /lib/modules/$(KERNELRELEASE)/build M=$(PWD) \
		INSTALL_MOD_DIR=ethercat modules_install

clean:
	$(MAKE) -C /lib/modules/$(KERNELRELEASE)/build M=$(PWD) clean
```

### 5.3 预生成的 config.h

```c
/* config.h - Pre-generated for DKMS (no autotools needed) */
#ifndef __DKMS_CONFIG_H__
#define __DKMS_CONFIG_H__

#define EC_USE_HRTIMER      1  /* --enable-hrtimer */
#define EC_HAVE_CYCLES       1  /* CPU timestamp counter */
#define EC_IDENT_WILDCARDS   1  /* Vendor/product wildcards */
#define EC_REGALIAS          1  /* Read alias addresses from register */
#define EC_MAX_NUM_DEVICES   1  /* Max Ethernet devices per master */

/* Undef: disabled features (matching --disable-eoe etc.) */
/* #undef EC_EOE */
/* #undef EC_RTDM */
/* #undef EC_RTDM_XENOMAI_V3 */
/* #undef EC_RT_SYSLOG */
/* #undef EC_DEBUG_IF */
/* #undef EC_DEBUG_RING */
/* #undef EC_SII_ASSIGN */

#define PACKAGE_NAME    "ethercat"
#define PACKAGE_VERSION "1.7.1"
#define PACKAGE_STRING  "ethercat 1.7.1"
#define VERSION         "1.7.1"

#endif /* __DKMS_CONFIG_H__ */
```

### 5.4 Kbuild.in → Kbuild 转换规则（在 debian/rules 中执行）

以 `master/Kbuild.in` 为例，转换逻辑为：

```makefile
# Before (Kbuild.in):
src := @abs_srcdir@
ccflags-y := -I@abs_top_builddir@
ifeq (@ENABLE_EOE@,1)
ec_master-objs += eoe_request.o ethernet.o fsm_eoe.o
endif
ifeq (@ENABLE_RTDM@,1)
...
endif

# After (Kbuild):
src := $(src)
ifeq (,1)
ec_master-objs += eoe_request.o ethernet.o fsm_eoe.o
endif
ifeq (,1)
...
endif
```

其中 `@ENABLE_EOE@` 替换为 ` `` `（空，即不成立），`ifeq (@ENABLE_EOE@,1)` 变为 `ifeq (,1)` — 永假，被 EoE 的代码不会被编译。

**实现方式**：在 `debian/rules` 中新增 `override_dh_auto_configure` 步骤，用 `sed` 批量替换所有 `Kbuild.in` → `Kbuild`。

### 5.5 debian/control 新增条目

```
Package: ethercat-dkms
Architecture: all
Depends: dkms, ${misc:Depends}
Recommends: linux-headers-generic | linux-headers
Description: IgH EtherCAT Master - DKMS kernel modules
 IgH EtherCAT Master kernel module source for DKMS.
 This package provides the source code for the EtherCAT master
 kernel modules (ec_master, ec_generic, ec_igb) to be built with
 DKMS against the running kernel's headers.
```

原来的 `ethercat-igh` 包增加：

```
Recommends: ethercat-dkms
```

### 5.6 debian/ethercat-dkms.install

```
ethercat/                                       usr/src/ethercat-1.7.1/
debian/dkms.conf                                usr/src/ethercat-1.7.1/
debian/dkms-config.h                            usr/src/ethercat-1.7.1/config.h
```

## 6. 实施步骤

### Step 1: 生成静态 Kbuild 文件

在 `debian/rules` 中新增预处理步骤：

```makefile
override_dh_auto_configure:
	# 1. 将所有 Kbuild.in 转为 Kbuild（替换 autoconf 变量）
	find ethercat -name "Kbuild.in" | while read f; do \
		dest=$$(echo "$$f" | sed 's/\.in$$//'); \
		sed \
			-e 's|@abs_srcdir@|$(src)|g' \
			-e 's|@abs_top_builddir@|$(src)/..|g' \
			-e 's|@ENABLE_EOE@||g' \
			-e 's|@ENABLE_RTDM@||g' \
			-e 's|@ENABLE_XENOMAI@||g' \
			-e 's|@ENABLE_XENOMAI_V3@||g' \
			-e 's|@ENABLE_RTAI@||g' \
			-e 's|@ENABLE_DEBUG_IF@||g' \
			-e 's|@ENABLE_DRIVER_RESOURCE_VERIFYING@||g' \
			-e 's|@ENABLE_TTY@||g' \
			-e 's|@LINUX_SYMVERS@|Module.symvers|g' \
			"$$f" > "$$dest"; \
	done

	# 2. 仍需要 configure 来构建用户态部分（可选：可绕过）
	cd ethercat && ./bootstrap
	dh_auto_configure -D ethercat -- \
		--host=aarch64-none-linux-gnu \
		--enable-kernel \
		--enable-generic \
		--enable-igb \
		--disable-eoe \
		--enable-hrtimer \
		--with-linux-dir="$(KERNEL_SRC)" \
		--prefix="$(PREFIX)" \
		--sysconfdir=/etc \
		CC="$(CROSS_COMPILE)gcc" \
		CXX="$(CROSS_COMPILE)g++"
```

### Step 2: 去掉内核模块的构建和安装

修改 `debian/rules`：

```makefile
override_dh_auto_build:
	dh_auto_build -D ethercat -- -j$$(nproc)
	# 不再执行: make modules

override_dh_auto_install:
	dh_auto_install -D ethercat -- DESTDIR=$(CURDIR)/debian/ethercat-igh
	# 不再执行: make modules_install

override_dh_strip:
	dh_strip -p ethercat-igh
	# dh_strip -p ethercat-dkms  # skip for source package
```

### Step 3: 去掉 gencontrol 内核版本注入

```makefile
override_dh_gencontrol:
	dh_gencontrol -p ethercat-igh
	dh_gencontrol -p ethercat-dkms
```

### Step 4: 简化 postinst / postrm

`debian/postinst` 中删除第 9-52 行（整个模块迁移和 depmod 逻辑），只保留 PATH 配置、ldconfig、systemd 启用。但模块特定的操作删除后，需确保 `ethercat-dkms.postinst` 中 `dkms autoinstall` 处理模块注册。

### Step 5: 编写 DKMS 维护脚本

`debian/ethercat-dkms.postinst`:
```bash
#!/bin/bash
set -e

NAME=ethercat
VERSION=1.7.1

if [ "$1" = "configure" ]; then
    dkms add -m $NAME -v $VERSION >/dev/null 2>&1 || true
    dkms build -m $NAME -v $VERSION >/dev/null 2>&1 || true
    dkms install -m $NAME -v $VERSION >/dev/null 2>&1 || true
fi
exit 0
```

`debian/ethercat-dkms.prerm`:
```bash
#!/bin/bash
set -e

NAME=ethercat
VERSION=1.7.1

if [ "$1" = "remove" ]; then
    dkms remove -m $NAME -v $VERSION --all >/dev/null 2>&1 || true
fi
exit 0
```

### Step 6: 测试验证

```bash
# 在目标 arm64 机器上
sudo dpkg -i ethercat-dkms_1.7.1_all.deb
sudo dpkg -i ethercat-igh_1.7.1_arm64.deb

# 验证 DKMS 状态
dkms status

# 验证模块
modinfo ec_master
modprobe ec_master

# 验证用户态
/opt/ethercat/bin/ethercat version

# 模拟内核更新后重编译
sudo dkms autoinstall
```

## 7. 注意事项

### 7.1 构建机 vs 目标机

| 事项 | 当前 | DKMS 化后 |
|---|---|---|
| 工具链 | 交叉编译 `aarch64-*-gcc` | 目标机本地 gcc |
| 内核源码 | 完整树 `/opt/.../orange-pi-6.1-rk35xx` | 头文件包 `linux-headers-$(uname -r)` |
| 架构 | `Architecture: arm64` | dkms 包 `Architecture: all` |

### 7.2 内核版本特定文件

当前启用的 igb 和 generic 驱动不涉及版本特定文件。但如果将来启用 e100/e1000/r8169 等驱动，需要在 Makefile 中根据 `$(KERNELRELEASE)` 选择正确的源文件。做法类似 configure.ac 的逻辑：

```makefile
KERNEL_VER_MAJOR = $(word 1,$(subst ., ,$(KERNELRELEASE)))
KERNEL_VER_MINOR = $(word 2,$(subst ., ,$(KERNELRELEASE)))
# 匹配最接近的驱动文件版本...
```

### 7.3 用户态版本一致性

用户态 `libethercat.so` 通过 ioctl 与内核模块通信。DKMS 使得模块跟随内核自动重编译，但用户态不变。由于内核模块 API（ioctl 接口）是稳定的，这不成问题。如果未来 ighest 更新 ioctl 协议，则需同步更新用户态包。

### 7.4 config.h 中 PACKAGE_VERSION 的影响

`globals.h` 中有：

```c
#define EC_MASTER_VERSION VERSION " " EC_STR(REV)
```

`VERSION` 来自 `config.h` 中的 `PACKAGE_VERSION`。这在 `module.c` 中用于 `ec_master_version_str` 输出。DKMS 版本应与此保持一致。

## 8. 工作量估算

| 任务 | 预计工作量 |
|---|---|
| Kbuild.in → Kbuild 替换脚本 | 2h |
| config.h 预生成 | 0.5h |
| dkms.conf 编写 | 0.5h |
| debian/rules 改造 | 2h |
| debian/control 拆分 | 0.5h |
| 维护脚本编写 | 1h |
| 测试 & 调试 | 3h |
| **合计** | **~1 人天** |
