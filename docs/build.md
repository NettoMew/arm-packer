# 构建与开关

## 跑法

用 `make <板子>` 即可（底层是 `scripts/build.sh`，可直接 `BOARD=… scripts/build.sh` 调用）。脚本
会自动用 `pacman` 装好所有依赖（交叉工具链 `aarch64-linux-gnu-gcc`、U-Boot/ATF 构建依赖、
`parted/util-linux/dosfstools/e2fsprogs/aria2/xz` 等）。**以普通用户运行即可**——需要 root 的
步骤（挂载、`losetup`、写引导）会自动 `sudo`。

```sh
make                 # 列出所有目标（help）

make e20c            # Radxa E20C
make m28k            # MangoPi M28K 有屏版（默认含 OLED，= m28k-screen）
make m28k-noscreen   # MangoPi M28K 无屏版
make rock5c          # Radxa ROCK 5C（RK3582 默认开核）
make rock5c-stock    # Radxa ROCK 5C 原厂分级（ROCK5C_UNLOCK=0）
make opiz3           # Orange Pi Zero 3（Allwinner H618）

make all             # 依次构建全部板子
```

- **选发行版**（默认 alpine）：`DISTRO=archlinux make rock5c` / `DISTRO=eweos make rock5c`。
- 任意 `scripts/build.sh` 开关都能命令行透传，例：`make opiz3 ROOT_PASSWORD=secret SKIP_FETCH=1`。
- **dry-run**：`make <板>-dry` 只解析配置、打印内核片段与板级钩子，不构建（秒级、无需联网/sudo）。

成品在 `out/`，例如 `out/radxa-rock5c-archlinux-7.2.7.img.xz`。

> **加速迭代**：内核默认增量编译（同板重编几秒）；`CLEAN_KERNEL=1` 从头编；`SKIP_BUILD=1`
> 跳过 U-Boot+内核只跑 rootfs/镜像；`SKIP_FETCH=1` 复用已克隆源码树。

### 内核版本

默认从官方 [Linux stable 仓库](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/)
获取 [`config/versions.conf`](../config/versions.conf) 中固定的标签，不再跟随 `torvalds/master` 开发分支。`make <板>-dry`
会显示实际使用的 `KERNEL_REPO` / `KERNEL_REF`；镜像版本号仍从取回的源码解析。

`make kernel-version` 查看默认版本。后续更新使用 `kernel-check` → `kernel-build` → 真机测试 →
`kernel-promote`，详见[内核更新流程](kernel-updates.md)；不需要到测试或引擎脚本中同步版本号。

从旧工作区升级时，必须重新取源并编译，不能使用 `SKIP_FETCH=1` 或 `SKIP_BUILD=1`：

```sh
make rock5c SKIP_FETCH=0 SKIP_BUILD=0 CLEAN_KERNEL=1   # 换成你的板子
```

`CLEAN_KERNEL=1` 用于干净重编；仍可用 `KERNEL_REPO` / `KERNEL_REF` 覆盖默认值。
例如恢复开发分支时需同时指定二者：

```sh
make rock5c KERNEL_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git KERNEL_REF=master
```

## 常用开关（环境变量）

Rockchip 的 `rkbin` 也固定到 `config/versions.conf` 中的提交，与 `lib/vendor/rockchip.sh`
引用的 BL31/DDR 文件版本配套。不要单独改回 `master`：上游会删除旧版本文件。
需要升级启动固件时，应同时更新提交及文件名，再做对应板子的冷启动验证。

BTF 生成也会随 `JOBS` 并行，内存不足时不能只看 C 编译是否通过。本次 10 GiB ARM64
虚拟机在 6 路 BTF 生成时触发 OOM，`JOBS=1` 增量续编成功；不必关闭 `MODERN_KERNEL`
或删掉 BTF。源码不变时可用 `make rock5c JOBS=1 SKIP_FETCH=1` 复用已编译产物。

| 变量 | 默认 | 作用 |
|------|------|------|
| `BOARD` | `e20c` | `e20c` / `m28k` / `rock5c` / `opiz3`（`make <板子>` 会自动设好） |
| `DISTRO` | `alpine` | `alpine`（apk+OpenRC）/ `archlinux`（pacman+systemd）/ `eweos`（pacman+dinit，musl/busybox） |
| `JOBS` | `nproc` | 编译并发；完整内核的 BTF 阶段内存占用较高，小内存构建机可设 `1` |
| `KERNEL_REPO` | `config/versions.conf` 中的 `DEFAULT_KERNEL_REPO` | Linux 源码仓库；需包含 `KERNEL_REF` 指定的标签/分支 |
| `KERNEL_REF` | `config/versions.conf` 中的 `DEFAULT_KERNEL_REF` | 固定内核版本；`SKIP_FETCH=1` 时不会切换已有源码 |
| `RKBIN_REF` | `config/versions.conf` 中的 `DEFAULT_RKBIN_REF` | Rockchip 固件提交；须与 BL31/DDR 文件名配套 |
| `KERNEL_VALIDATION_ROOT` | `work/kernel-validation` | 独立候选验证的根目录；每次新建子目录，不复用正常 `WORKSPACE` |
| `M28K_OLED` | `1` | M28K 有屏(1)/无屏(0) |
| `ROCK5C_UNLOCK` | `1` | RK3582 开核（RK3588S2 上为空操作） |
| `ROCK5C_NVME_BOOT` | `0` | ROCK5C 可选 NVMe 优先 BootSTD/extlinux 引导；SD/eMMC/USB 为后备。不自动安装或清空 NVMe，不支持此配置下的 EFI 启动；见 [NVMe 说明](rock5c-nvme-boot.md) |
| `ATF_REF` / `ATF_PLAT` | `master` / `sun50i_h616` | 仅 `opiz3`：上游 arm-trusted-firmware 分支与 BL31 平台 |
| `SKIP_FETCH` | `0` | `1`=复用已克隆源码树，迭代更快 |
| `CLEAN_KERNEL` | `0` | `1`=删内核 build 目录从头编（默认增量） |
| `SKIP_BUILD` | `0` | `1`=跳过 U-Boot+内核编译，只跑 rootfs/镜像（须同板上次构建） |
| `ARCH_SLIM` | `1` | 仅 `archlinux`：删 ALARM 自带内核 + 桌面/x86 固件 |
| `ARCH_STRIP_ALL_FW` | `1` | 仅 `archlinux`：删整个 linux-firmware（只留 aic8800+mali）；`0`=保留 ARM wifi/bt 固件 |
| `ARCH_BUILD_KEYRING` | `1` | 仅 `archlinux`：构建期 qemu chroot 预置 pacman keyring；`0`=首启再初始化 |
| `IMAGE_SIZE` | alpine `1G` / arch `4G` | 构建镜像大小（稀疏 + 首启扩容） |
| `ROOTFS_EXT4_FEATURES` | `^metadata_csum,^metadata_csum_seed,^orphan_file,^64bit` | 传给 `mkfs.ext4 -O` 的根分区特性；默认保守 ext4，避免 U-Boot 能读 `extlinux.conf` 却加载 `/boot/Image` 失败 |
| `COMPRESS_IMAGE` | `1` | `1`=构建后 `xz -T0 -6` 打包，完整性检查通过才发布 `.img.xz` 并删除原始 `.img` |
| `INSTALL_DEPS` | `1` | `0`=只检查依赖、缺失就报错，不自动装 |
| `ROOT_PASSWORD` | `120102` | root 密码（SHA-512 写入 `/etc/shadow`）；置空则免密码（仅串口） |
| `ROOT_AUTHORIZED_KEY` | 内置 ed25519 公钥 | 写入 `/root/.ssh/authorized_keys`，并开 `PermitRootLogin yes` |
| `AUTO_RESIZE` | `1` | 首启自动把根分区扩到整盘（一次性自禁用） |
| `DOCKER_KERNEL` | `1` | 内核编入容器/Docker 网络栈（nftables + iptables + NAT + bridge/veth/overlay + 命名空间/cgroup） |
| `MODERN_KERNEL` | `1` | 内核编入现代 eBPF 栈：dae（BPF + BTF/CO-RE + tc clsact + kprobes）、tproxy/socket、WireGuard、TUN、BBR + fq/cake（BTF 需主机有 `pahole`） |
| `DISTRO_KERNEL` | `1` | 在 defconfig 之上合并发行版级 aarch64 配置 `kconfig/distro-arm64.config`（源自 ALARM，6770+ 选项，只增不减）；启动必需驱动随后由 `kconfig/*.fragment` 重新强制内建（无 initramfs 也能起） |
| `NTP_SERVERS` | aliyun + cn.pool | chrony 时间源 |
| `TIMEZONE` | `Asia/Shanghai` | 时区；置空保留 UTC |
| `SERIAL_CONSOLE` | 按板（RK3528=`ttyS0`，ROCK 5C=`ttyS2`，H618=`ttyS0`） | 串口控制台节点 |
| `SERIAL_BAUD` | 按板（Rockchip=`1500000`，Allwinner=`115200`） | 串口波特率 |

## 烧写

balenaEtcher 可直接选择 `.img.xz`（**Flash from file**），无需手动解压；
XZ 在[上游支持测试清单](https://etcher-docs.balena.io/MANUAL-TESTING/#image-support)中。
请核对目标卡，刷写会清空其内容。

构建默认使用标准 XZ/LZMA2、CRC64 校验和 preset 6；压缩失败或校验失败时保留
原始镜像及已有压缩包，不留下可被误认为成品的半成品。`make test-image` 验证真实
压缩/解压和失败保护；`COMPRESS_IMAGE=0` 仍只保留原始 `.img`。

```sh
IMG=out/radxa-rock5c-archlinux-7.2.7.img.xz   # 换成你的实际成品名（含内核版本号）
# 务必先核对 /dev/sdX 是正确的卡 / eMMC
xz -dc "$IMG" | sudo dd of=/dev/sdX bs=4M conv=fsync iflag=fullblock status=progress
```

首次启动后根分区自动扩展到整盘并一次性自禁用：Alpine 走 `/etc/local.d/10-resize-rootfs.start`
（growpart + resize2fs）；Arch 走早期 `firstboot-grow.service`（sfdisk + resize2fs，开机几秒、无需联网）。

### 默认登录

- `root` / `120102`（可用 `ROOT_PASSWORD` 改）
- 已内置 SSH 公钥 + `PermitRootLogin yes`，可直接 `ssh root@<板子IP>`
- **hostname**：`radxa-e20c` / `mangopi-m28k` / `radxa-rock5c` / `orangepi-zero3`
- 串口：RK3528 板 `ttyS0`、ROCK 5C `ttyS2`（均 `1500000 8n1`）、Orange Pi Zero 3 `ttyS0`
  （`115200 8n1`）；`console=` 中串口放最后，保证 login 走串口
