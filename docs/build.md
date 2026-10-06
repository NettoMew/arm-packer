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

- **选发行版**（默认 alpine）：`DISTRO=archlinux make rock5c` / `DISTRO=debian make rock5c` / `DISTRO=eweos make rock5c`。
  `debian` 需要宿主机装有 `mmdebstrap` 与 `debian-archive-keyring`（Debian/Ubuntu 直接 apt 安装，Arch 走 AUR）。
- **选用途**（默认 base）：`DISTRO=debian PROFILE=incus make dragon-q8b` 产出 Incus 主机
  `*-debian-incus-*.img.xz`：内核按 incus/dae 能力合约编、ZFS 存储池、首启离线初始化，见 [Incus 主机](incus.md)。
- 任意 `scripts/build.sh` 开关都能命令行透传，例：`make opiz3 ROOT_PASSWORD=secret SKIP_FETCH=1`。
- **dry-run**：`make <板>-dry` 只解析配置、打印内核片段与板级钩子，不构建（秒级、无需联网/sudo）。

成品在 `out/`，例如 `out/radxa-rock5c-archlinux-7.2.9.img.xz`。

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

## 在 GitHub Actions 上构建

仓库带两个工作流：

- `check`（[`check.yml`](../.github/workflows/check.yml)）：每次推送和 PR 都跑离线检查：`bash -n`、
  `make test-kernel`（全部板 × 发行版 × 用途的 dry-run 矩阵与合约单测）、`make test-image`、`make test-swupdate`。
- `build`（[`build.yml`](../.github/workflows/build.yml)）：手动触发，在 GitHub 原生 arm64 runner
  （`ubuntu-24.04-arm`，4 核、15 GB 内存）上构建镜像。内核原生编译，不用交叉工具链，也不用 qemu；
  ZFS 池由 runner 内核自带的 zfs 模块创建。每个目标占一台 runner，并行构建。

```sh
gh workflow run build.yml                          # 默认：dragon-q8b:debian:incus rock5c:debian:incus
gh workflow run build.yml -f targets='rock5c:debian:incus e20c m28k-noscreen:archlinux'
gh workflow run build.yml -f targets=all:debian    # Makefile 里 all 的全部板子，都用 debian
gh workflow run build.yml -f targets=rock5c:debian:incus -f env='ROCK5C_NVME_BOOT=1'
gh workflow run build.yml -f targets=dragon-q8b:debian:incus -f kernel_ref=v7.2.10
gh workflow run build.yml -f release=v2026.10.06   # 另外发布到这个标签的 Release
```

- **目标**写成 `make 目标[:发行版[:用途]]`。make 目标就是 Makefile 里的板子目标（包括 `m28k-noscreen`、
  `rock5c-stock`），省略的部分取引擎默认值。plan 任务先对每个目标跑一遍 dry-run：目标写错、组合不合法
  （比如 alpine 配 ZFS 根），几秒内就失败，不占构建 runner。
- **`env`** 是空格分隔的 `KEY=VALUE`，作用于每个目标，值里不能有空格和引号。
- **成品**：每个镜像单独上传成不打包的 artifact，下载即 `.img.xz`。另有 `record-<目标>`，内含构建日志、
  内核 `.config`、sha256 和 ccache 统计；构建失败时也会上传，用来排查。两者都保留 30 天。
  填了 `release` 时，全部目标成功后再发到该标签的 Release；标签已存在就覆盖同名文件。
- **U-Boot** 改从 GitHub 镜像拉取：`source.denx.de` 对 runner 返回 502。

实测（Linux 7.2.9，2026-10）：冷编每个目标约 80 分钟，其中内核占 73 分钟；缓存热了以后整个任务
10–14 分钟，ccache 命中 99.9%，内核只剩约 4 分钟（链接、BTF、modpost）。

缓存（仓库免费额度共 10 GB，7 天没用到的条目会被 GitHub 清掉）：

- **ccache**：每个目标一份，约 3 GB（zstd 压缩约 3.2 倍），所以额度大约装得下三个目标，再多就按最久
  没用的先淘汰，那个目标下次冷编。键为 `ccache-arm64-<目标>-<运行号>`。目标第一次构建时，先借用别的目标的
  缓存起步，能命中多少取决于两边的内核配置有多接近。构建成功后只保留本次用到的对象，所以升级内核后旧版本的
  对象不会一直占着空间；构建失败则原样保留，重试时照样能用。几乎全命中的构建不再重存，存了新条目后
  删掉同目标的旧条目，免得把别的目标挤出额度。
- **`work/downloads`**：OpenZFS、systemd-boot 和锁定的固件，几十 MB，键随 `config/versions.conf`
  与各板 `firmware.lock` 的内容变化。发行版的 rootfs 包不缓存：它们跟着 latest 走、文件名却不变
  （Arch 插件见到同名文件就直接复用，缓存会让 CI 一直用旧快照），而且镜像站很快，Alpine 的 460 MB
  只要 17 秒。
- **源码树不缓存**：内核从 git.kernel.org 浅克隆、U-Boot 等从 GitHub 克隆，各只要几十秒；缓存它们
  还会挤占 ccache 的额度。

缓存条目归属存下它的分支：`main` 存的所有分支都能用，其他分支存的只有那个分支自己能用。所以平时
在 `main` 上触发，缓存才能一直热着。

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
| `DISTRO` | `alpine` | `alpine`（apk+OpenRC）/ `archlinux`（pacman+systemd）/ `debian`（apt+systemd+ifupdown，最小化）/ `eweos`（pacman+dinit，musl/busybox） |
| `PROFILE` | `base` | 用途插件 `lib/profile/<名>.sh`：`base`（什么都不加）/ `incus`（Incus 主机，仅 `debian`；镜像名加 `-incus`，见 [incus.md](incus.md)） |
| `INCUS_CHANNEL` | `stable` | 仅 incus：Zabbly 频道（`stable` / `lts-7.0` / `lts-6.0` / `daily`） |
| `INCUS_PACKAGES` | `incus incus-ui-canonical skopeo umoci` | 仅 incus：从 Zabbly/Debian 装的包 |
| `INCUS_ROOT_SIZE` / `INCUS_POOL_MIN` | `8G` / `8G` | 仅 incus、非 ZFS 根：首启根分区只扩到前者，余下（至少后者）建 ZFS 池分区；盘不够就拒绝初始化 |
| `JOBS` | `nproc` | 编译并发；完整内核的 BTF 阶段内存占用较高，小内存构建机可设 `1` |
| `KERNEL_REPO` | `config/versions.conf` 中的 `DEFAULT_KERNEL_REPO` | Linux 源码仓库；需包含 `KERNEL_REF` 指定的标签/分支 |
| `KERNEL_REF` | `config/versions.conf` 中的 `DEFAULT_KERNEL_REF` | 固定内核版本；`SKIP_FETCH=1` 时不会切换已有源码 |
| `RKBIN_REF` | `config/versions.conf` 中的 `DEFAULT_RKBIN_REF` | Rockchip 固件提交；须与 BL31/DDR 文件名配套 |
| `KERNEL_VALIDATION_ROOT` | `work/kernel-validation` | 独立候选验证的根目录；每次新建子目录，不复用正常 `WORKSPACE` |
| `M28K_OLED` | `1` | M28K 有屏(1)/无屏(0) |
| `ROCK5C_UNLOCK` | `1` | RK3582 开核（RK3588S2 上为空操作） |
| `ROCK5C_NVME_BOOT` | `0` | ROCK5C 可选 NVMe 优先 BootSTD/extlinux 引导；SD/eMMC/USB 为后备。不自动安装或清空 NVMe，不支持此配置下的 EFI 启动；见 [NVMe 说明](rock5c-nvme-boot.md) |
| `ATF_REF` / `ATF_PLAT` | `master` / `sun50i_h616` | 仅 `opiz3`：上游 arm-trusted-firmware 分支与 BL31 平台 |
| `QCOM_ESP_SIZE` | `512M` | 仅 Qualcomm 板（`dragon-q8b`）：ESP 大小，放 systemd-boot、内核与 dtb |
| `SKIP_FETCH` | `0` | `1`=复用已克隆源码树，迭代更快 |
| `CLEAN_KERNEL` | `0` | `1`=删内核 build 目录从头编（默认增量） |
| `SKIP_BUILD` | `0` | `1`=跳过 U-Boot+内核编译，只跑 rootfs/镜像（须同板上次构建） |
| `ARCH_SLIM` | `1` | 仅 `archlinux`：删 ALARM 自带内核 + 桌面/x86 固件 |
| `ARCH_STRIP_ALL_FW` | `1` | 仅 `archlinux`：删整个 linux-firmware（只留 aic8800+mali）；`0`=保留 ARM wifi/bt 固件 |
| `ARCH_BUILD_KEYRING` | `1` | 仅 `archlinux`：构建期 qemu chroot 预置 pacman keyring；`0`=首启再初始化 |
| `DEBIAN_SUITE` | `trixie` | 仅 `debian`：稳定版代号，自动带上 `-updates` 与 `-security` |
| `DEBIAN_MIRROR` / `DEBIAN_SECURITY_MIRROR` | `deb.debian.org` / `security.debian.org` | 仅 `debian`：构建期与板上共用的软件源 |
| `DEBIAN_VARIANT` | `important` | 仅 `debian`：mmdebstrap 基础层（Debian 优先级定义的最小可用系统）；更薄的 `required`/`apt` 缺 login 与 debconf 前端 |
| `DEBIAN_EXTRA_PACKAGES` | 空 | 仅 `debian`：在基础系统之外追加的包（空格分隔），如 `curl htop` |
| `DEBIAN_MASKED_UNITS` | apt/dpkg/e2scrub 周期任务 | 仅 `debian`：屏蔽的 systemd 单元（`fstrim.timer` 保留） |
| `IMAGE_SIZE` | alpine `1G` / arch `4G` / debian `2G` / eweos `2G`；incus `4G` | 根文件系统大小（稀疏 + 首启扩容）；ESP 等其他分区另加；profile 的需求优先于发行版默认 |
| `ROOTFS_TYPE` | 板级 `BOARD_ROOTFS_TYPE`，否则 `ext4` | 根文件系统插件 `lib/fs/<type>.sh`：`ext4`，或 `zfs`（仅 UEFI 厂商 + `debian`；dragon-q8b 默认） |
| `ZFS_POOL` | `rpool` | 仅 zfs：池名；根数据集为 `<池>/ROOT/<distro>` |
| `ZFS_POOL_COMPATIBILITY` | `openzfs-2.2-linux` | 仅 zfs：建池时限定的特性集，构建机比镜像新也不会启用镜像模块不认识的特性；板上 `zpool set compatibility=off` 后可 `zpool upgrade` |
| `ZFS_POOL_PROPERTIES` | `ashift=12 autotrim=on` | 仅 zfs：`zpool create -o` 的池属性 |
| `ZFS_DATASET_PROPERTIES` | `compression=zstd atime=off xattr=sa acltype=posixacl dnodesize=auto` | 仅 zfs：`zpool create -O` 的数据集属性，所有数据集继承（池根数据集固定 `mountpoint=none canmount=off`，新数据集要自己指定挂载点） |
| `ROOTFS_EXT4_FEATURES` | `^metadata_csum,^metadata_csum_seed,^orphan_file,^64bit` | 仅 ext4：传给 `mkfs.ext4 -O` 的根分区特性；默认保守 ext4，避免 U-Boot 能读 `extlinux.conf` 却加载 `/boot/Image` 失败 |
| `COMPRESS_IMAGE` | `1` | `1`=构建后 `xz -T0 -6` 打包，完整性检查通过才发布 `.img.xz` 并删除原始 `.img` |
| `INSTALL_DEPS` | `1` | `0`=只检查依赖、缺失就报错，不自动装 |
| `ROOT_PASSWORD` | `120102` | root 密码（SHA-512 写入 `/etc/shadow`）；置空则免密码（仅串口） |
| `ROOT_AUTHORIZED_KEY` | 内置 ed25519 公钥 | 写入 `/root/.ssh/authorized_keys`，并开 `PermitRootLogin yes` |
| `AUTO_RESIZE` | `1` | 首启自动把根分区扩到整盘（一次性自禁用） |
| `DOCKER_KERNEL` | `1` | 内核编入容器/Docker 网络栈（nftables + iptables + NAT + bridge/veth/overlay + 命名空间/cgroup） |
| `MODERN_KERNEL` | `1` | 内核编入现代 eBPF 栈：dae（BPF + BTF/CO-RE + tc clsact + kprobes）、tproxy/socket、WireGuard、TUN、BBR + fq/cake（BTF 需主机有 `pahole`） |
| `DISTRO_KERNEL` | `1` | 在 defconfig 之上合并发行版级 aarch64 配置 `kconfig/distro-arm64.config`（源自 ALARM，6770+ 选项，只增不减）；启动必需驱动随后由 `kconfig/*.fragment` 重新强制内建（无 initramfs 也能起） |
| `NTP_SERVERS` | aliyun + cn.pool | 时间源（chrony / timesyncd / ntpd，随发行版） |
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
IMG=out/radxa-rock5c-archlinux-7.2.9.img.xz   # 换成你的实际成品名（含内核版本号）
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
