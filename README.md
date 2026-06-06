<div align="center">

# 主线 SBC 固件构建器

**从主线源码，为多块 Rockchip / Allwinner 开发板构建开箱即用的整盘镜像。**

Radxa E20C · Widora MangoPi M28K · Radxa ROCK 5C · Orange Pi Zero 3
&nbsp;·&nbsp; Alpine / Arch Linux

</div>

---

一套引擎，**三根正交插件轴**——板子 `board` × 厂商 `vendor` × 发行版 `distro`。
引擎里没有任何 `if board/vendor/distro` 分支：差异全在插件与配置里。
*加一块板、加一个发行版，只是加一个文件。*

- **主线 U-Boot**（`OF_UPSTREAM`）— Rockchip 用 rkbin DDR/BL31；Allwinner H618 全程开源无闭源 blob
  （U-Boot SPL 初始化 DRAM + 上游 ATF 现编 BL31）。
- **主线 Linux**（约 7.1）— 内核选项是 `kconfig/*.fragment` 可组合片段，而非命令式补丁。
- **三选一根文件系统** — `alpine`（apk + OpenRC，~170M）、`archlinux`（pacman + systemd，~660M）
  或 `eweos`（musl + busybox + pacman + dinit，rolling）。

成品是可直接 `dd` 到 eMMC / SD 的整盘镜像，`zstd -19` 压成
**`<板>-<发行版>-<内核版本>.img.zst`**（如 `radxa-rock5c-archlinux-7.1.0-rc6.img.zst`），首启自动扩容。

## 快速开始

```sh
make e20c                      # Radxa E20C（RK3528）
make m28k                      # MangoPi M28K 有屏版（OLED 心电图仪表盘）
make rock5c                    # Radxa ROCK 5C（RK3582 默认开核 → 7 核 + GPU）
make opiz3                     # Orange Pi Zero 3（Allwinner H618，全开源引导链）
make all                       # 全部板子

DISTRO=archlinux make rock5c   # 换发行版（alpine / archlinux / eweos）
make rock5c-dry                # 只解析配置、打印片段/钩子，不构建（秒级）
```

以普通用户运行即可——需要 root 的步骤自动 `sudo`，依赖自动用 `pacman` 装好。成品落在 `out/`。

```sh
zstd -dc out/<镜像>.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync iflag=fullblock status=progress
```

> 默认登录 `root` / `120102`（内置 SSH 公钥，可直接 `ssh root@<板子IP>`）。

## 支持的板子

| `BOARD` | 板子 | SoC | 亮点 |
|---------|------|-----|------|
| `e20c` | Radxa E20C | RK3528 | 双千兆，纯主线 |
| `m28k` | Widora MangoPi M28K | RK3528 | AIC8800 Wi-Fi6/BT，OLED 仪表盘 |
| `rock5c` | Radxa ROCK 5C | RK3588S2 / RK3582 | RK3582 开核 → 7 核 + Mali-G610，NVMe，AIC8800 USB Wi-Fi |
| `opiz3` | Orange Pi Zero 3 | Allwinner H618 | 全程开源无闭源 blob，Mali-G31 |

## 文档

| | |
|---|---|
| [构建与开关](docs/build.md) | 跑法、环境变量全表、烧写、默认登录 |
| [支持的板子](docs/boards.md) | 镜像命名、各板细节 |
| [发行版](docs/distros.md) | alpine / archlinux / eweos 对照、各自专项处理 |
| [RK3582 开核](docs/rk3582-unlock.md) | ft_system_setup 补丁原理、实测 7 核 |
| [Allwinner H618](docs/allwinner.md) | 开源引导链、SPL/MBR/Panfrost |
| [架构](docs/architecture.md) | 三个契约、目录结构、内核片段 |
| [进度与限制](docs/status.md) | 已完成功能、已知限制 |
| [内核片段](kconfig/README.md) | `.config` 片段合并顺序与规则 |
