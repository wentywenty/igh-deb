# ethercat-igh

这个仓库用于构建 IgH EtherCAT Master（包含用户态工具和相关的交叉编译内核模块），生成供机器人和其他系统使用的 Debian 软件包。

## 目录说明

- `ethercat/`: IgH EtherCAT 源码子模块
- `debian/`: Debian 打包配置文件 (control、rules 等)及维护者脚本

## 本地与交叉构建

软件包默认配置为对 `aarch64` 进行交叉编译，如果本地路径拥有相应的编译链与内核源代码，可以直接使用 Debian 原生打包命令：

```bash
dpkg-buildpackage -us -uc -b -aarm64
```

相关的工具链 (`CROSS_COMPILE`)、内核源码路径 (`KERNEL_SRC`) 与架构类型可以在 `debian/rules` 中通过修改环境变量的方式自定义，也可以在打包时由上层 CI 进行环境注入。

## 产物位置

最终 deb 产物会默认输出到上级目录（与 `igh-deb` 平级）：

```bash
../ethercat-igh_<version>_<arch>.deb
```

## 初始化说明

打包安装后，会一并安装 `/lib/systemd/system/ethercat-first-boot.service`。它会在系统第一次安装启动时自动执行 `depmod -a` 和模块配置操作。
