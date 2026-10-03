<div align="center">

# 主线 SBC 固件构建器

**从主线源码，为多块 Rockchip / Allwinner / Qualcomm 开发板构建开箱即用的整盘镜像。**

Radxa E20C · Widora MangoPi M28K · Radxa ROCK 5C · Orange Pi Zero 3 · Radxa Dragon Q8B
&nbsp;·&nbsp; Alpine / Arch Linux / Debian / eweOS

</div>

---

一套引擎，**三根正交插件轴**——板子 `board` × 厂商 `vendor` × 发行版 `distro`。
引擎里没有任何 `if board/vendor/distro` 分支：差异全在插件与配置里。
*加一块板、加一个发行版，只是加一个文件。*

- **主线 U-Boot**（`OF_UPSTREAM`）— Rockchip 用 rkbin DDR/BL31；Allwinner H618 全程开源无闭源 blob
  （U-Boot SPL 初始化 DRAM + 上游 ATF 现编 BL31）。
- **板载 UEFI 的板子**（Qualcomm）— 不编引导程序：GPT 盘 = ESP + 根分区，锁版本的 systemd-boot 读 BLS 启动项。
- **主线 Linux 稳定版**（标签固定在 [`config/versions.conf`](config/versions.conf)）— 内核选项是 `kconfig/*.fragment` 可组合片段，而非命令式补丁。
- **四选一根文件系统** — `alpine`（apk + OpenRC，~170M）、`archlinux`（pacman + systemd，~660M）、
  `debian`（最小化 trixie：Debian 基础系统 + systemd + ifupdown，无 dbus）或 `eweos`（musl + busybox + pacman + dinit，rolling）。
- **按用途出镜像**（`PROFILE`）— `incus`：任一板子变成 Incus 主机（系统容器 / OCI / KVM 虚拟机 + Web UI），
  存储只用 ZFS，内核按 Incus 与 dae（eBPF/BTF）能力合约编，合约在 `.config` 定型后逐条核对。

成品是可直接 `dd` 到 eMMC / SD 的整盘镜像，`xz -T0 -6` 压成
**`<板>-<发行版>-<内核版本>.img.xz`**，首启自动扩容。
可在 balenaEtcher 的 **Flash from file** 中直接选择 `.img.xz`，无需手动解压。

## 快速开始

```sh
make e20c                      # Radxa E20C（RK3528）
make m28k                      # MangoPi M28K 有屏版（OLED 心电图仪表盘）
make rock5c                    # Radxa ROCK 5C（RK3582 默认开核 → 7 核 + GPU）
make opiz3                     # Orange Pi Zero 3（Allwinner H618，全开源引导链）
DISTRO=debian make dragon-q8b  # Radxa Dragon Q8B（Qualcomm SC8280XP，UEFI + systemd-boot）
make all                       # 全部板子

DISTRO=archlinux make rock5c   # 换发行版（alpine / archlinux / debian / eweos）
DISTRO=debian PROFILE=incus make dragon-q8b   # Incus 主机（ZFS 存储、Web UI :8443）
make rock5c-dry                # 只解析配置、打印片段/钩子，不构建（秒级）
```

以普通用户运行即可——需要 root 的步骤自动 `sudo`，依赖自动用 `pacman` 装好。成品落在 `out/`。

```sh
xz -dc out/<镜像>.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync iflag=fullblock status=progress
```

> 默认登录 `root` / `120102`（内置 SSH 公钥，可直接 `ssh root@<板子IP>`）。

## 支持的板子

| `BOARD` | 板子 | SoC | 亮点 |
|---------|------|-----|------|
| `e20c` | Radxa E20C | RK3528 | 双千兆，纯主线 |
| `m28k` | Widora MangoPi M28K | RK3528 | AIC8800 Wi-Fi6/BT，OLED 仪表盘 |
| `rock5c` | Radxa ROCK 5C | RK3588S2 / RK3582 | RK3582 开核 → 7 核 + Mali-G610，NVMe，AIC8800 USB Wi-Fi |
| `opiz3` | Orange Pi Zero 3 | Allwinner H618 | 全程开源无闭源 blob，Mali-G31 |
| `dragon-q8b` | Radxa Dragon Q8B | Qualcomm SC8280XP | 板载 UEFI + systemd-boot，ZFS 根，EL2 + KVM，双 2.5GbE，NVMe，Adreno 690 |

## 文档

| | |
|---|---|
| [构建与开关](docs/build.md) | 跑法、环境变量全表、烧写、默认登录 |
| [内核更新流程](docs/kernel-updates.md) | 集中版本配置、候选验证/编译、真机测试后更新默认值 |
| [SWUpdate 测试镜像](docs/swupdate.md) | 上游 APK、签名验证、ROCK5C 首个测试目标及当前边界 |
| [支持的板子](docs/boards.md) | 镜像命名、各板细节 |
| [发行版](docs/distros.md) | alpine / archlinux / debian / eweos 对照、各自专项处理 |
| [Incus 主机](docs/incus.md) | `PROFILE=incus`：ZFS 存储、首启初始化、Web UI、自建 br0、内核能力合约与 dae |
| [RK3582 开核](docs/rk3582-unlock.md) | ft_system_setup 补丁原理、实测 7 核 |
| [Allwinner H618](docs/allwinner.md) | 开源引导链、SPL/MBR/Panfrost |
| [架构](docs/architecture.md) | 插件契约、目录结构、内核片段 |
| [进度与限制](docs/status.md) | 已完成功能、已知限制 |
| [内核片段](kconfig/README.md) | `.config` 片段合并顺序与规则 |
