# 主线 SBC 固件构建器（Rockchip E20C / M28K / ROCK 5C + Allwinner Orange Pi Zero 3 · Alpine / Arch）

`scripts/build.sh` 从**主线源码**为多块 Rockchip / Allwinner 开发板构建开箱即用镜像，
**三根正交插件轴**：板子（board）× 厂商（vendor）× 发行版（distro）。

- 主线 **U-Boot**（`OF_UPSTREAM`）
  - Rockchip：DDR/BL31 来自 rkbin，按 SoC 自动选 RK3528 / RK3588
  - Allwinner H618：**全程开源无闭源 blob**——DRAM 初始化在 U-Boot SPL 里，BL31 由上游
    `arm-trusted-firmware`（`PLAT=sun50i_h616`）现编，产出 `u-boot-sunxi-with-spl.bin`
- 主线 **Linux** 内核（约 7.1 系列；内核选项是 `kconfig/*.fragment` 可组合片段）
- 根文件系统二选一（`DISTRO=`）：
  - **`alpine`**（默认）：`apk.static` 离线装 sys-mode rootfs + OpenRC + ifupdown，镜像小（~170M）
  - **`archlinux`**：上游 ALARM aarch64 rootfs + pacman + systemd（出厂预置 keyring，瘦身后 ~660M）

成品是可直接 `dd` 到 eMMC/SD 的整盘镜像，默认 `xz --best` 压成 `*.img.xz`。镜像名为
**`<板>-<发行版>-<内核版本号>.img`**（如 `radxa-rock5c-archlinux-7.1.0-rc6.img`、
`radxa-e20c-alpine-6.12.1.img`）——内核版本号取自 `make kernelversion`。

---

## 支持的板子与镜像

镜像名 = `<前缀>-<发行版>-<内核版本>.img(.xz)`；下表只列前缀（`<发行版>` 由 `DISTRO=` 决定）。

| `BOARD` | 板子 | SoC | 镜像名前缀 | 说明 |
|---------|------|-----|----------|------|
| `e20c`（默认） | Radxa E20C | RK3528 | `radxa-e20c-…` | 纯主线 |
| `m28k` + `M28K_OLED=1`（默认） | Widora MangoPi M28K | RK3528 | `widora-mangopi-m28k-screen-…` | **有屏版**：含 OLED 心电图仪表盘 |
| `m28k` + `M28K_OLED=0` | Widora MangoPi M28K | RK3528 | `widora-mangopi-m28k-noscreen-…` | **无屏版**：不装 OLED 用户态 |
| `rock5c` | Radxa ROCK 5C | RK3588S2 / **RK3582** | `radxa-rock5c-…` | 纯主线；RK3582 默认**开核**（见下） |
| `opiz3` | Xunlong Orange Pi Zero 3 | **Allwinner H618** | `orangepi-zero3-…` | 全程开源无闭源 blob（ATF BL31 现编 + U-Boot SPL）；针对 1GB 版 |

> 每块板 ×2 发行版：`make rock5c` 出 `…-alpine-<ver>`，`DISTRO=archlinux make rock5c` 出 `…-archlinux-<ver>`。

> M28K 有屏 / 无屏两版**内核与 dtb 完全相同**，区别仅在于有屏版额外装了 OLED 仪表盘程序
> 与开机自启脚本。

> `opiz3` 是唯一的 **Allwinner** 板：用上游 `arm-trusted-firmware`（`PLAT=sun50i_h616`）现编 BL31，
> H616/H618 的 DRAM 初始化在开源 U-Boot SPL 里，整条引导链无闭源 blob；引导镜像是
> `u-boot-sunxi-with-spl.bin`，写在 **8 KiB**，分区表用 **MBR**（GPT 会被 SPL 覆盖）。

---

## 在 Arch / CachyOS 上编译

用 `make <板子>` 即可（底层是 `scripts/build.sh`，可直接 `BOARD=… scripts/build.sh` 调用）。脚本会自动用
`pacman` 装好所有依赖（交叉工具链 `aarch64-linux-gnu-gcc`、U-Boot/ATF 构建依赖、
`parted/util-linux/dosfstools/e2fsprogs/aria2/xz` 等）。**以普通用户运行即可**——脚本内部
需要 root 的步骤（挂载、`losetup`、写引导）会自动调用 `sudo`。

```sh
cd /home/adam/Documents/package/rockchip/alpine

make                 # 列出所有目标（help）

make e20c            # Radxa E20C
make m28k            # MangoPi M28K 有屏版（默认含 OLED 心电图，= m28k-screen）
make m28k-noscreen   # MangoPi M28K 无屏版
make rock5c          # Radxa ROCK 5C（RK3582 默认开核）
make rock5c-stock    # Radxa ROCK 5C 原厂分级（ROCK5C_UNLOCK=0）
make opiz3           # Orange Pi Zero 3（Allwinner H618）

make all             # 依次构建全部板子
```

**选发行版**（默认 alpine）：`DISTRO=archlinux make rock5c`（出 `…-archlinux-<ver>` 镜像）。
任意 `scripts/build.sh` 的开关都能在命令行透传，例：`make opiz3 ROOT_PASSWORD=secret SKIP_FETCH=1`。
`make <板>-dry`（如 `make opiz3-dry`）只解析配置、打印内核片段与板级钩子，不构建（秒级、无需联网/sudo）。

成品在 `out/` 下，例如 `out/radxa-rock5c-archlinux-7.1.0-rc6.img.xz`。

> **加速迭代**：内核默认**增量编译**（同板重编几秒）；`CLEAN_KERNEL=1` 从头编；`SKIP_BUILD=1`
> 跳过 U-Boot+内核只跑 rootfs/镜像；`SKIP_FETCH=1` 复用已克隆源码树。

### 常用开关（环境变量）

| 变量 | 默认 | 作用 |
|------|------|------|
| `BOARD` | `e20c` | `e20c` / `m28k` / `rock5c` / `opiz3`（`make <板子>` 会自动设好） |
| `DISTRO` | `alpine` | 发行版：`alpine`（apk+OpenRC）/ `archlinux`（pacman+systemd） |
| `M28K_OLED` | `1` | M28K 有屏(1)/无屏(0) |
| `ROCK5C_UNLOCK` | `1` | RK3582 开核（仅 rock5c 有意义，RK3588S2 上为空操作） |
| `ATF_REF` / `ATF_PLAT` | `master` / `sun50i_h616` | 仅 `opiz3`：上游 arm-trusted-firmware 分支与 BL31 平台 |
| `SKIP_FETCH` | `0` | `1`=复用已克隆的源码树（Rockchip: U-Boot/Linux/rkbin；Allwinner: U-Boot/Linux/ATF），迭代更快 |
| `CLEAN_KERNEL` | `0` | `1`=删内核 build 目录从头编（默认增量，同板重编几秒） |
| `SKIP_BUILD` | `0` | `1`=跳过 U-Boot+内核编译，复用已编产物，只跑 rootfs/镜像（须是同板上次构建） |
| `ARCH_SLIM` | `1` | 仅 `archlinux`：删 ALARM 自带内核 + 桌面/x86 固件（用我们自己的内核+每板固件） |
| `ARCH_STRIP_ALL_FW` | `1` | 仅 `archlinux`：删**整个** linux-firmware（只留 aic8800+mali）；`0`=保留 ARM wifi/bt 固件 |
| `ARCH_BUILD_KEYRING` | `1` | 仅 `archlinux`：构建期 qemu chroot 预置 pacman keyring（首登即可 pacman）；`0`=首启再初始化 |
| `IMAGE_SIZE` | 按发行版（alpine `1G` / arch `4G`） | 构建镜像大小（稀疏 + 首启扩容，留足解 rootfs 的空间） |
| `ROOTFS_EXT4_FEATURES` | `^metadata_csum,^metadata_csum_seed,^orphan_file,^64bit` | 传给 `mkfs.ext4 -O` 的根分区特性；默认使用 U-Boot 更稳的保守 ext4，避免能读 `extlinux.conf` 但加载 `/boot/Image` 失败 |
| `COMPRESS_IMAGE` | `1` | `1`=构建后 `xz --best` 压缩并删除原始 `.img` |
| `INSTALL_DEPS` | `1` | `0`=只检查依赖、缺失就报错，不自动装 |
| `ROOT_PASSWORD` | `120102` | root 密码（SHA-512 写入 `/etc/shadow`）；置空则免密码（仅串口） |
| `ROOT_AUTHORIZED_KEY` | 内置 ed25519 公钥 | 写入 `/root/.ssh/authorized_keys`，并开 `PermitRootLogin yes` |
| `AUTO_RESIZE` | `1` | 首启自动把根分区扩到整盘（growpart + resize2fs，一次性自禁用） |
| `DOCKER_KERNEL` | `1` | 内核编入容器/Docker 网络栈（nftables + iptables + NAT + bridge/veth/overlay + 命名空间/cgroup） |
| `MODERN_KERNEL` | `1` | 内核编入现代 eBPF 栈：dae（BPF + BTF/CO-RE + tc clsact + kprobes）、tproxy/socket、WireGuard、TUN、BBR + fq/cake（BTF 需主机有 `pahole`） |
| `DISTRO_KERNEL` | `1` | **默认开**：在 defconfig 之上合并发行版级 aarch64 配置 `kconfig/distro-arm64.config`（源自 Arch Linux ARM，6770+ 选项，只增不减），覆盖海量文件系统/网络/netfilter/QoS/蓝牙/声卡/媒体/USB 设备/加密等；启动必需驱动随后由 `kconfig/*.fragment` 重新强制内建（无 initramfs 也能起） |
| `NTP_SERVERS` | aliyun + cn.pool | chrony 时间源 |
| `TIMEZONE` | `Asia/Shanghai` | 时区；置空保留 UTC |
| `SERIAL_CONSOLE` | 按板（RK3528=`ttyS0`，ROCK 5C=`ttyS2`，H618=`ttyS0`） | 串口控制台节点 |
| `SERIAL_BAUD` | 按板（Rockchip=`1500000`，Allwinner=`115200`） | 串口波特率 |

---

## 发行版（`DISTRO=` 第三根插件轴）

内核 / 引导 / 镜像分区 / 板级钩子**与发行版无关、完全复用**；只有"用户态 = 包管理器 + init
系统 + 网络栈"由 `lib/distro/<distro>.sh` 插件提供（契约对称 `lib/vendor/*`）。加一个发行版 =
加一个同构插件，引擎不动。

| | `alpine`（默认） | `archlinux` |
|---|---|---|
| 包管理 / init | apk + OpenRC | pacman + systemd |
| 网络 | ifupdown `/etc/network/interfaces` | systemd-networkd（ALARM 自带 eth/en DHCP）|
| 校时 | chrony（aliyun NTP） | systemd-timesyncd（ALARM 自带，写 NTP=） |
| rootfs 来源 | apk.static 离线装 sys-mode | 解上游 ALARM aarch64 tar.gz |
| 镜像大小 | ~170M | ~660M（瘦身后；见下） |
| 首启 | 装 GPU/wifi 在线包 + 扩容 | 早期 sfdisk 扩容（无网）+ 网络后 pacman 装 mesa/wifi |

**Arch 专项处理**（都用我们自己的主线内核，不是 ALARM 那个）：
- **删 ALARM 自带内核**：删 `/boot` 内核 + `*-ARCH` 模块，`IgnorePkg = linux-aarch64` 屏蔽，
  首启 `pacman -Rdd` 清库（否则 `pacman -Syu` 会把内核+initramfs 装回来覆盖我们的 `/boot`）。
- **精简固件**（`ARCH_STRIP_ALL_FW=1`）：我们每板自带固件（Mali CSF + AIC8800），所以删整个
  `linux-firmware`（5.2M 只剩 aic8800+mali）；插外置 USB 网卡再 `pacman -S linux-firmware`。
- **keyring 出厂预置**（`ARCH_BUILD_KEYRING=1`）：构建期 qemu chroot 跑 `pacman-key --init/--populate`，
  首登即可 pacman，无首启竞态（首启保留幂等兜底）。
- **早期扩容**：独立 `firstboot-grow.service`（`sysinit.target`，无网络），用 base 自带的
  `sfdisk + resize2fs`，开机几秒扩满盘——不依赖联网装 growpart。

---

## Radxa ROCK 5C 与 RK3582 开核

ROCK 5C 已**完整在主线**：U-Boot `rock-5c-rk3588s_defconfig` + Linux `rk3588s-rock-5c.dtb`。
板子可能是满血 **RK3588S2**，也可能是降级分级的 **RK3582**。

RK3582 的"砍核"**完全发生在 U-Boot**：主线 U-Boot 的 `ft_system_setup()`
（`arch/arm/mach-rockchip/rk3588/rk3588.c`，由 `CONFIG_OF_SYSTEM_SETUP=y` 触发）在把设备树
交给内核前，读芯片 OTP efuse，先屏蔽 **OTP 实测的坏核**，再套一层**市场分级策略**：
强制再砍掉一个大核 cluster（cpu6/cpu7）和 Mali-G610 GPU。

**开核（`ROCK5C_UNLOCK=1`，默认）= 一个 U-Boot 补丁**
（`boards/rock5c/uboot/patches/0001-rk3582-unlock-cores-gpu.patch`），把 ft_system_setup() 里
**三段策略** `#if 0` 掉：①"一核坏就连坐砍整簇"（否则同簇的好核也被牵连）、②"再强制砍一个大核簇"
（分级）、③"强制砍 GPU"。**保留 OTP 对单颗坏核的真实标记**，所以真坏的核仍被屏蔽，能用的好核
全部拿回 → 恢复 GPU + 尽可能多的大核。

- ✅ **实测**（本人 RK3582 ROCK 5C）：开核后 **7 核**（4×A55 + 3×A76 @2.4GHz）+ Mali-G610 GPU 正常。
- ℹ️ 为什么是 7 不是 8：这颗片子有**一颗大核（MPIDR 0x400）是真坏的**（强行打开会 `failed to
  come online`），所以最多 7 核。良率好的 RK3582 可达 8 核；都由 OTP 自动决定。
- ⚠️ **OTP 实测坏核仍保留屏蔽**（补丁只去人为分级/连坐，不动 OTP 单核标记）→ 相对安全；不稳就
  `ROCK5C_UNLOCK=0` 回原厂。
- 在真 **RK3588S2** 上补丁为**空操作**（cpu-code≠0x3582，`ft_system_setup` 直接返回）。

> GPU 说明：Panthor 编译为**内核模块**（不是内建），否则会在 `/lib/firmware` 挂载前 probe 导致
> `mali_csffw.bin failed -2`。构建时会下载该固件（约 280KB）并写 `/etc/modules-load.d/panthor.conf`，
> 开机挂载根文件系统后再加载 panthor → GPU 正常（`/dev/dri/renderD128`）。

---

## Orange Pi Zero 3（Allwinner H618）

唯一的 Allwinner 板，引导链与 Rockchip 完全不同，但**复用同一套 Alpine rootfs 流程**
（分区/格式化/apk.static 安装/extlinux/时间/SSH/首启扩容等）。差异都由 `BOARD_VENDOR=allwinner`
分支处理：

- **无闭源 blob**：H616/H618 的 DRAM 初始化在开源 U-Boot SPL 里；BL31 由上游
  `arm-trusted-firmware`（`PLAT=sun50i_h616`，`make build_atf` 现编）提供。U-Boot 用
  `orangepi_zero3_defconfig`，`BL31=… SCP=/dev/null` 产出 `u-boot-sunxi-with-spl.bin`。
- **引导写入**：`u-boot-sunxi-with-spl.bin` 写在 **8 KiB**（`SPL_SEEK_KIB`）；分区表是 **MBR**
  （GPT 的分区项数组在 1–17 KiB，会被 SPL 覆盖），根分区起始扇区 32768（16 MiB），留足空间。
- **内核**：`sun50i-h618-orangepi-zero3.dtb`；网卡 `dwmac-sun8i` + RTL8211F PHY，存储 `mmc-sunxi`，
  USB 走 EHCI/OHCI + `phy-sun4i-usb`，GPU 是 **Mali-G31（Bifrost）→ Panfrost**（注意不是 Lima），
  并需 `SUN50I_H6_PRCM_PPU` 否则 GPU 电域不注册、panfrost probe -110 无 `/dev/dri`。
- **defconfig/dtb 都在主线**，无需注入板级源码；串口 `ttyS0 @ 115200`。

> 当前针对 **1GB RAM** 版（规避主线"1.5GB 被识别成 2GB"的已知问题）。

---

## 烧写

```sh
IMG=out/radxa-rock5c-archlinux-7.1.0-rc6.img    # 换成你实际的成品名（含内核版本号）
# xz 已删除原始 img，可直接解压管道写盘（务必先核对 /dev/sdX 是正确的卡 / eMMC）
xz -dc "$IMG.xz" | sudo dd of=/dev/sdX bs=4M conv=fsync iflag=fullblock status=progress
```

首次启动后根分区自动扩展到整盘并一次性自禁用：Alpine 走 `/etc/local.d/10-resize-rootfs.start`
（growpart + resize2fs）；Arch 走早期 `firstboot-grow.service`（sfdisk + resize2fs，开机几秒、无需联网）。

### 默认登录

- `root` / `120102`（可用 `ROOT_PASSWORD` 改）
- 已内置 SSH 公钥 + `PermitRootLogin yes`，可直接 `ssh root@<板子IP>`
- **hostname** = 品牌+名称：`radxa-e20c` / `mangopi-m28k` / `radxa-rock5c` / `orangepi-zero3`
- 串口：RK3528 板 `ttyS0`、ROCK 5C `ttyS2`（均 `1500000 8n1`）、Orange Pi Zero 3 `ttyS0`
  （`115200 8n1`）；`console=` 中串口放最后，保证 login 走串口

---

## 已完成（Completed）

**通用**
- 主线 U-Boot + 主线 Linux + Alpine rootfs，整盘镜像，首启自动扩容
- GPU：内核 DRM（RK3528=lima / RK3588=Panthor）+ 用户态 Mesa
- 时间：chrony（aliyun NTP）+ tzdata（Asia/Shanghai），无 RTC 也能开机校时
- SSH（公钥 + 密码）、root 密码、串口控制台、mdev 热插拔
- 输出 `xz --best` 压缩为 `*.img.xz`（删除原始 `.img`）

**E20C / M28K（RK3528）**
- 双千兆网口：PCIe `r8169`（combphy）+ RGMII `gmac`（INNO PHY）
- eMMC（`sdhci`）/ SD（`sdmmc`）/ USB 2.0 Host（M28K 走 USB 回移补丁）
- **M28K**：AIC8800 Wi-Fi6 + 蓝牙（板载 SDIO，树外驱动移植主线 7.1，`pwrseq_simple` 回归已修）；
  有屏版 OLED 心电图仪表盘（0.91" SSD1306 128×32，扫描线绘制波形/分隔线/`<CPU%> <IPv4>`，
  心率随 CPU 变化，防烧屏，开机自启，已真机验证）；LED 触发器配置
  - **开机自启按 init 系统自适配**：Alpine 走 OpenRC `/etc/local.d/`；**Arch 走 systemd**——OLED 是
    `oled-dash.service`（Type=simple，等 `/dev/fb0`，崩溃自拉起），LED 由通用 `distro_adapt_local_d`
    把 `/etc/local.d/*.start` 自动转成 `localcompat-m28k-leds.service`（oneshot）。两版功能对齐。

**ROCK 5C（RK3588S2 / RK3582）—— 已真机验证**
- 纯主线 U-Boot + Linux，真机启动正常：千兆网口（gmac1 RGMII + RTL8211F）、eMMC、SD、
  USB3(DWC3)、**PCIe NVMe（FPC/M.2）**、**Mali-G610 → Panthor**（模块 + 固件，`/dev/dri/renderD128`）
- **RK3582 开核已生效**：实测 **7 核**（4×A55 + 3×A76 @2.4GHz）+ GPU；只砍掉真坏的那颗大核
- **FPC NVMe**：内核 cmdline `nvme_core.default_ps_max_latency_us=0 pcie_aspm=off` 修掉掉链问题（61.8GB 稳定）
- **WiFi（AIC8800D80 USB）**：树外驱动移植到主线 7.1（`boards/rock5c/aic8800/`），实测 wlan0 扫到 23 个 AP、
  开机自动加载；连接填 `/etc/wpa_supplicant/wpa_supplicant.conf` 的 SSID/密码即可
- rkbin 用 `rk3588_bl31_v1.51.elf` + `rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.19.bin`
- 首启自动扩容（growpart + resize2fs）、swclock、sysctl 均已修好并真机验证

**Orange Pi Zero 3（Allwinner H618）**
- **全程开源无闭源 blob**：上游 ATF BL31（`PLAT=sun50i_h616`）现编 + 主线 U-Boot SPL →
  `u-boot-sunxi-with-spl.bin`（写 8 KiB，MBR 分区表）
- 主线 `orangepi_zero3_defconfig` + `sun50i-h618-orangepi-zero3.dtb`，无需注入板级源码
- 千兆网口 `dwmac-sun8i` + RTL8211F、microSD `mmc-sunxi`、USB EHCI/OHCI + `phy-sun4i-usb`
- GPU：**Mali-G31（Bifrost）→ Panfrost** + `SUN50I_H6_PRCM_PPU` 电域 + Mesa 用户态
- 复用统一 rootfs 流程：首启扩容、SSH、chrony、串口 `ttyS0 @ 115200`

---

## 未完成 / 已知限制

- **ROCK 5C HDMI 输出未验证**（其余：7 核开核、GPU、NVMe(FPC)、千兆、USB3、WiFi、首启扩容
  均已真机验证）。8 核仅在大核全好的 RK3582 上可得；本人这颗有一颗大核物理损坏，最多 7 核。
  WiFi 出厂只装驱动+固件+模板，连接需自填 SSID/密码；蓝牙（AIC USB BT）未做。
- **E20C 不含 USB 回移补丁**：USB 回移与 M28K 设备树绑定，E20C 走纯主线树，USB 取决于主线
  `rk3528-radxa-e20c.dts` 本身。E20C 无 Wi-Fi。
- **M28K 蓝牙端到端未充分验证**；Wi-Fi 凭据为模板，需填 SSID/PSK。
- **RK3528 无 HDMI**（主线缺 VOP/HDMI），M28K 的 micro-HDMI 未启用（OLED 是唯一显示）。
- **构建需联网**：部分用户态包（Mesa、wpa_supplicant/bluez、tzdata、cloud-utils-growpart）走在线
  安装；无网络时降级/跳过（非致命）。

---

## 目录结构

声明式、可插拔架构：**每块板一个 `boards/<board>/board.conf`** + 可选 `hooks.sh`；
厂商差异是 `lib/vendor/<vendor>.sh` 插件；内核选项是 `kconfig/*.fragment` 可组合片段；
引擎 `lib/*.sh` 里没有任何 board/vendor 条件分支。加一块新板 = 丢一个 `board.conf`（+ 需要时
`hooks.sh`/`kernel.fragment`/资源），不改引擎。

```
Makefile                      # 入口：make <板子> / make <板>-dry（调用 scripts/build.sh）
scripts/build.sh              # 唯一入口脚本：载 config → 载 vendor+hooks → 跑 pipeline
lib/                          # 引擎模块（被 scripts/build.sh source；无 board/vendor/distro 分支）
  log/env/deps/workspace/     #   日志、旋钮+派生路径、依赖、工作区
  sources/uboot/kernel/       #   取源(+定镜像名)、U-Boot、内核(片段合并)
  image/rootfs/pipeline.sh    #   镜像分区/写引导、共享 rootfs 落地、run_pipeline + 钩子分派
  aic8800.sh                  #   AIC8800 Wi-Fi/BT 驱动能力（m28k SDIO / rock5c USB 共用）
  vendor/rockchip.sh          #   rkbin blob / u-boot-rockchip.bin@s64 / GPT / Panthor 固件
  vendor/allwinner.sh         #   现编 ATF BL31 / u-boot-sunxi-with-spl.bin@8KiB / MBR
  distro/alpine.sh            #   apk + OpenRC + ifupdown（distro_* 契约）
  distro/archlinux.sh         #   ALARM + pacman + systemd（删自带内核/固件、预置 keyring、早期扩容）
boards/<board>/board.conf     # 每块板的声明式配置（vendor/soc/defconfig/dtb/镜像前缀/串口…）
boards/m28k/                  #   有屏 M28K：hooks.sh + kernel.fragment + 注入源
    hooks.sh                  #     源码注入 + AIC8800(SDIO) + OLED 仪表盘
    kernel.fragment           #     板级内核片段（SSD130X + wifi/bt core）
    {uboot,linux,aic8800,oled,files}/   # DTS/补丁/固件移植/OLED 源/开机脚本
boards/rock5c/                #   hooks.sh（RK3582 开核 + AIC8800 USB）+ uboot/aic8800 补丁
# e20c / opiz3 纯主线，只有 board.conf，无 hooks/注入源
kconfig/                      # 可组合内核片段 + distro-arm64.config 基线（见 kconfig/README.md）
resources/rootfs/             # 固定 rootfs 文件（resize 脚本、wpa 模板、interfaces 基底）
work/                         # 源码树工作区（U-Boot/Linux + rkbin/aic8800 或 arm-trusted-firmware）
out/                          # 成品镜像（*.img.xz）
```
