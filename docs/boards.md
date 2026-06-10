# 支持的板子

镜像名 = `<前缀>-<发行版>-<内核版本>.img.zst`；下表只列前缀，`<发行版>` 由 `DISTRO=` 决定
（`alpine` / `archlinux` / `eweos`）。例如 `make rock5c` 出 `…-alpine-<ver>`，`DISTRO=eweos make rock5c`
出 `…-eweos-<ver>`。

| `BOARD` | 板子 | SoC | 前缀 | 说明 |
|---------|------|-----|------|------|
| `e20c`（默认） | Radxa E20C | RK3528 | `radxa-e20c-…` | 纯主线 |
| `m28k`（默认含屏） | Widora MangoPi M28K | RK3528 | `widora-mangopi-m28k-screen-…` | 有屏版：OLED 心电图仪表盘 |
| `m28k` `M28K_OLED=0` | Widora MangoPi M28K | RK3528 | `widora-mangopi-m28k-noscreen-…` | 无屏版：不装 OLED 用户态 |
| `rock5c` | Radxa ROCK 5C | RK3588S2 / **RK3582** | `radxa-rock5c-…` | 纯主线；RK3582 默认开核 |
| `hinlink-h88k` | Hinlink H88K | RK3588 | `hinlink-h88k-…` | 纯净无屏主线基线；Armbian 同名 DTB；GMAC + 2×RTL8125 |
| `opiz3` | Xunlong Orange Pi Zero 3 | **Allwinner H618** | `orangepi-zero3-…` | 全程开源无闭源 blob；针对 1GB 版 |

- **M28K 有屏 / 无屏**两版内核与 dtb 完全相同，区别仅在有屏版额外装了 OLED 仪表盘程序与开机自启脚本。
- **H88K 当前先走纯净无屏基线**：只注入 Armbian 主线同名 `rockchip/rk3588-hinlink-h88k.dtb`，不启用 LCD overlay、v2/v3 拆分或 SATA 变体；启动链按可启动 Armbian community 26.8 镜像对齐为 Radxa `rock-5b-rk3588_defconfig`（套 H88K evb/console patch）+ rkbin DDR `v1.18`（= 运行设备 `/proc/cmdline` 实测 `9fa84341ce`）/ BL31 `v1.48`，输出 split `idbloader.img` + `u-boot.itb`。
- **H88K 启动关键**：该板从 eMMC/SPI 里的旧 Rockchip 厂商 u-boot 启动，绕过 SD 卡引导区；其 extlinux 绝对路径处理不可靠，故 `board_configure_runtime` 钩子额外产出 Armbian 式 `boot.scr` + `armbianEnv.txt` + `/boot/dtb/` 布局（无 initrd，根驱动全内建，`root=PARTUUID=`），extlinux 保留作兜底。详见 `boards/hinlink-h88k/boot/boot.cmd`。**尚未上机验证。**
- **opiz3** 是唯一的 Allwinner 板：用上游 `arm-trusted-firmware`（`PLAT=sun50i_h616`）现编 BL31，
  H616/H618 的 DRAM 初始化在开源 U-Boot SPL 里，整条引导链无闭源 blob；引导镜像
  `u-boot-sunxi-with-spl.bin` 写在 **8 KiB**，分区表用 **MBR**（GPT 会被 SPL 覆盖）。详见
  [allwinner.md](allwinner.md)。

## Radxa ROCK 5C 与 RK3582 开核 → [rk3582-unlock.md](rk3582-unlock.md)

## Orange Pi Zero 3（Allwinner H618）→ [allwinner.md](allwinner.md)
