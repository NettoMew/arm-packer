# 进度与已知限制

## 已完成

**通用**
- 主线 U-Boot + 主线 Linux + rootfs，整盘镜像，首启自动扩容
- GPU：内核 DRM（RK3528=lima / RK3588=Panthor）+ 用户态 Mesa
- 时间：chrony（aliyun NTP）+ tzdata（Asia/Shanghai），无 RTC 也能开机校时
- SSH（公钥 + 密码）、root 密码、串口控制台、mdev 热插拔
- 输出 `zstd -19` 压缩为 `*.img.zst`（删除原始 `.img`）
- **三个发行版**：`alpine`（apk+OpenRC）/ `archlinux`（pacman+systemd）/ `eweos`（pacman+dinit，
  musl/busybox）。内核/引导/分区/板级钩子完全复用，每块板 ×3 发行版皆可构建

**E20C / M28K（RK3528）**
- 双千兆网口：PCIe `r8169`（combphy）+ RGMII `gmac`（INNO PHY）
- eMMC（`sdhci`）/ SD（`sdmmc`）/ USB 2.0 Host（M28K 走 USB 回移补丁）
- **M28K**：AIC8800 Wi-Fi6 + 蓝牙（板载 SDIO，树外驱动移植主线 7.1，`pwrseq_simple` 回归已修）；
  有屏版 OLED 心电图仪表盘（0.91" SSD1306 128×32，扫描线绘制波形/分隔线/`<CPU%> <IPv4>`，心率随
  CPU 变化，防烧屏，开机自启，已真机验证）；LED 触发器配置
  - **开机自启按 init 系统自适配**：Alpine 走 OpenRC `/etc/local.d/`；Arch 走 systemd
    （`oled-dash.service`，等 `/dev/fb0`，崩溃自拉起）；eweOS 走 dinit（`oled-dash` 服务等
    ssd130x framebuffer 后 exec，symlink 进 `/etc/dinit.d/boot.d/` 自启）。LED 由通用
    `distro_adapt_local_d` 自动转成对应 init 的 oneshot。三版功能对齐。

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
