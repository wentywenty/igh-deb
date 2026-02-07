# IgH EtherCAT deb 构建部署指南

简易操作步骤如下：

### 1. 初始化源码
确保下载了子模块代码：
```bash
git submodule update --init --recursive
```

### 2. 安装依赖
在宿主机安装必要的构建工具：
```bash
sudo apt install build-essential autoconf automake libtool
```

### 3. 配置环境
修改 `env.sh` 文件，填入你的**交叉编译器路径**和**内核源码路径**：
```bash
# 例如：
export CROSS_COMPILE=/path/to/gcc-arm-11.2.../bin/aarch64-none-linux-gnu-
export KERNEL_SRC=/path/to/orange-pi-kernel-source
```

> **注意**：你的内核源码 (`KERNEL_SRC`) 必须是**先编译过**的状态（即源码目录下要有 `.config` 和编译生成的文件），否则 build.sh 无法编译内核模块。

### 4. 编译打包
直接运行构建脚本：
```bash
./build.sh
```
编译成功后，在 `output` 目录下会生成 `.deb` 安装包。

### 5. 安装与配置
把 `.deb` 包传到开发板上安装：
```bash
sudo dpkg -i ethercat-igh_xxx_arm64.deb
```

安装后，务必修改配置文件指定网卡名称（默认是 eth0）：
```bash
sudo nano /etc/ethercat.conf
```
找到 `MASTER0_DEVICE`，将其改为你实际使用的网卡名称（推荐用 MAC 地址，或 `ethX`）。

之后重启服务即可：
```bash
sudo systemctl restart ethercat
```
