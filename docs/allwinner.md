# Orange Pi Zero 3（Allwinner H618）

唯一的 Allwinner 板，引导链与 Rockchip 完全不同，但**复用同一套 rootfs 流程**（分区/格式化/
安装/extlinux/时间/SSH/首启扩容等）。差异都由 `BOARD_VENDOR=allwinner` 分支处理：

- **无闭源 blob**：H616/H618 的 DRAM 初始化在开源 U-Boot SPL 里；BL31 由上游
  `arm-trusted-firmware`（`PLAT=sun50i_h616`，`make build_atf` 现编）提供。U-Boot 用
  `orangepi_zero3_defconfig`，`BL31=… SCP=/dev/null` 产出 `u-boot-sunxi-with-spl.bin`。
- **引导写入**：`u-boot-sunxi-with-spl.bin` 写在 **8 KiB**（`SPL_SEEK_KIB`）；分区表是 **MBR**
  （GPT 的分区项数组在 1–17 KiB，会被 SPL 覆盖），根分区起始扇区 32768（16 MiB）。
- **内核**：`sun50i-h618-orangepi-zero3.dtb`；网卡 `dwmac-sun8i` + RTL8211F PHY，存储 `mmc-sunxi`，
  USB 走 EHCI/OHCI + `phy-sun4i-usb`，GPU 是 **Mali-G31（Bifrost）→ Panfrost**（注意不是 Lima），
  并需 `SUN50I_H6_PRCM_PPU` 否则 GPU 电域不注册、panfrost probe -110 无 `/dev/dri`。
- **defconfig/dtb 都在主线**，无需注入板级源码；串口 `ttyS0 @ 115200`。

> 当前针对 **1GB RAM** 版（规避主线「1.5GB 被识别成 2GB」的已知问题）。
