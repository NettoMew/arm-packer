# 进度与已知限制

## Linux 7.2.9（2026-10-04）

- 默认内核由 7.2.7 升到 7.2.9，按 kernel-check → kernel-build → 真机测试 → kernel-promote 完整走了一遍
  （dragon-q8b / debian / incus）。Q8B 补丁 0037 删掉（7.2.8 已含），其余 79 个照旧；真机以 ZFS 启动环境方式升级，
  23 项验证与外设、重启回归通过。明细见 [incus.md](incus.md) 的“内核更新到 7.2.9”一节。
- ROCK 5C 的 Debian + Incus 镜像用 7.2.9 构建，审计与 QEMU 首启通过（ext4 根 8G + incus ZFS 分区、容器、U-Boot 扇区不变），
  未上实机；e20c、m28k、opiz3 只经 `make test-kernel` 的 dry-run。
- 升级中发现 Q8B 两个 2.5G 口的 eth0/eth1 偶尔对调（MAC 驱动与 GPIO 驱动并行 probe），补丁 0081 修掉：功能 0 固定 eth0。

## Incus 主机 profile（2026-10-04）

- 新增用途轴 `PROFILE`（`lib/profile/`，默认 `base` 不改变任何现有镜像）与内核能力合约 `kconfig/*.contract`；
  `PROFILE=incus`：Zabbly stable 的 Incus 7.5.1 + Web UI + OCI，存储只用 ZFS，首启离线初始化，内核按 incus 与 dae
  合约编，`.config` 定型后逐条核对、编完核对 BTF。详见 [Incus 主机](incus.md)。
- 离线验证：全部 5 板 × 4 发行版 × incus 的 dry-run 矩阵与合约语义单测（`make test-kernel`）；5 块板子 Debian + incus 的真实
  `.config` 都满足两份合约；`make test-grow` 在 loop 盘上实测 MBR/GPT/小盘的首启分区并逐字节核对引导区（期间抓到并修掉
  `sfdisk --append` 会把数据分区放进根分区前空隙、覆盖 U-Boot 的问题）。
- 构建验证（`ssh andy`）：Dragon Q8B incus 镜像构建、板级审计与 profile 审计通过（两份合约、vmlinux BTF 10.3 MB、Zabbly
  钉死的密钥与源、首启单元与配置、构建期不留 Incus 状态）；QEMU virt 上 ZFS 根与 ext4 根两条存储路径都首启到底并起了容器。
- 真机（Dragon Q8B）：以新的 ZFS 启动环境 `rpool/ROOT/debian-incus` 全新首启，23 项全过——AppArmor、BTF、ZFS 池、Web UI、
  非特权容器、KVM 虚拟机、OCI 应用容器、dae（netkit 性能模式、eBPF 数据面拦截/放行/卸载）。板子现在默认启动 Incus 系统，
  原系统 `rpool/ROOT/debian` 留在启动菜单里。明细见 [incus.md](incus.md) 的验证记录。
- 未覆盖：Rockchip/Allwinner 板子只做了 dry-run 与真实 `.config` 合约核对，没有构建/启动它们的 incus 镜像；
  ext4 根 + ZFS 分区的路径在 loop 盘与 QEMU 上实测，未在 U-Boot 板实机上跑过。

## 本轮收尾（2026-09-23）

- 最终采用保留 SD 卡的引导方式，暂停 SPI 模块采购及无 SD 启动研究；保持交付固件和 SD 优先默认顺序，不刷实验性 NVMe-first 固件。
- SD 原系统与已安装的 NVMe 系统均保留。最后一次真机检查仍为临时选盘后的 NVMe 根系统；此次仓库收尾不重启、不刷盘，不将文档整理表述为已切回 SD 运行。
- 可选 `ROCK5C_NVME_BOOT=1` 构建配置及研究记录保留，但默认关闭，NVMe 热重启超时尚未解决，不能作为稳定自动启动方案交付。
- SWUpdate 仅为签名安装器基础设施，实际在线内核切换和自动回滚仍未实现。
- 收尾离线检查通过：Shell 语法、12 个板卡/发行版 dry-run、内核更新工作流保护、SWUpdate 配置预检、真实 XZ 往返/失败保护、ROCK5C 默认 SD 与可选 NVMe BootSTD 补丁测试。内核工作流测试使用模拟编译，不等于再次交叉编译；本轮没有重跑真机或 SWUpdate 运行时测试。

## 内核更新工作流

- 默认源码版本集中到 `config/versions.conf`，环境变量和板级覆盖保留。
- 新增独立 `kernel-check` / `kernel-build` 及带报告检查、人工真机确认的 `kernel-promote`。
- 流程离线回归使用模拟编译产物验证保护逻辑；不等同于真实交叉编译或真机验证。使用方式见[内核更新流程](kernel-updates.md)。

## SWUpdate 首个测试目标（2026-09-22）

- ROCK5C / Alpine 为首个镜像目标；`ENABLE_SWUPDATE=1` 显式启用，打包方式见 [SWUpdate 集成](swupdate.md)。
- ARM64 Linux 的 Alpine 3.24.2 / musl 环境已真实编译 SWUpdate 2026.05.1 和 libubootenv 0.3.7；不是模拟编译。
- 真实安装器的签名校验、错误密钥/布局版本/篡改/无签名拒绝、preinstall 失败保护和正常 archive/hook 流程通过。
- 已在独立 Alpine rootfs 验证签名 APK 仓库安装、动态库解析、公共验证密钥及设备身份写入，保留原测试启动文件。
- **完整 Linux 7.2.7 / ROCK5C / Alpine 3.24.2 镜像已真实构建并通过离线审计**：`ssh andy` 的 ARM64 Linux 容器构建，保留 BTF、Docker、发行版级内核配置和 4113 个模块文件；AIC8800 USB 两个模块与内核版本一致。
- 检查了 ext4、引导区、Image/DTB、PARTUUID/extlinux/fstab、AIC/Mali 固件、OpenRC 服务、SWUpdate 运行库/签名配置/公钥。镜像不含更新私钥，不启用更新守护进程。
- **2026-09-23 已完成首轮 ROCK5C 真机启动检查**，结果和未解决警告见下节；没有实现在线内核切换/自动回滚。
- 修复干净构建环境缺少 libelf 开发头文件的预检；`rkbin` 固定到包含既定 BL31/DDR 文件的提交，避免 `master` 删除旧文件后构建失败。10 GiB 虚拟机的 BTF 阶段以 `JOBS=1` 完成，未关闭 BTF。

## ROCK5C / 7.2.7 首轮真机检查（2026-09-23）

- 通过 COM3（1500000、8N1、无流控）及直连以太网 SSH 实测启动；运行 Alpine 3.24.2 / Linux 7.2.7，7 个 CPU 在线。Image、DTB 和更新公钥哈希与交付产物一致，运行时 BTF 存在。
- SD 根分区首启扩容至约 14.3 GiB；`sfdisk --verify /dev/mmcblk1` 无错误。早期启动日志的 GPT 备份表位置警告发生在扩容前，当前表已正常。
- 以太网协商 1000 Mbps / 全双工，主机到板卡 ping 3/3 及公钥 SSH 登录通过。本次 IPv4LL 地址为 `169.254.192.252`，不是固定配置；未修改主机网络，也未配置 Internet 共享，chrony 尚未同步时间。
- AIC8800 USB 两个模块加载，`wlan0` 被动扫描返回 8 条 BSS 记录；未测试 Wi-Fi 关联/数据传输。Panthor 初始化并出现 `renderD128`，NVMe E2M2 64GB 及其分区被识别；未做 GPU 渲染或 NVMe 读写测试。
- SWUpdate 程序可运行、设备身份为 `rock5c rock5c-alpine-v1`；没有执行更新、重启、刷写或磁盘写入测试。HDMI、蓝牙、持续负载和重启回归仍待验证。
- **待修复 / 排查**：
  - GIC PPI affinity 仍含 `cpu@400`（phandle `0x06`），但运行时该 CPU 的 `status=fail`。与本次构建源码对照，`of_cpu_node_to_id()` 返回负值触发 `irq-gic-v3.c:2135` 的 WARN，随后跳过该 CPU；不能将这次启动记为无内核警告。
  - `mmc0` 报非可移除卡初始化失败；用户已确认未安装 eMMC 模块，因此本次不作为已安装存储设备故障。当前从 SD（`mmc1`）正常启动，eMMC 功能仍未测试。
  - `wireless-regdb` 未安装，日志提示 `regulatory.db` 缺失；驱动另报 efuse 无 MAC。扫描成功不代表区域规则、唯一 MAC 或无线连接验证完成。
  - 还有 NVMe SUBNQN、媒体设备电源域/延迟探测提示；NVMe 枚举及 Hantro 后续注册成功不等于这些子系统的功能测试通过。
- 本次本地原始证据：`work/rock5c-hardware-20260923/`（串口、完整 dmesg、SSH 摘要和只读分区校验；不纳入版本控制）。
- 后续经用户授权清空 NVMe，已部署并校验同一交付镜像，分配独立 UUID，根文件系统扩容至 56.7 GiB。完全断电后，串口临时选择 NVMe extlinux bootflow，实测 Image/DTB 从 NVMe 加载，运行根设备为 `nvme0n1p1`，Linux 7.2.7 / Alpine 3.24.2 与 SSH 均正常。
- **NVMe 启动尚不能作为稳定交付**：此前软重启后的 U-Boot 探测曾超时，冷启动通过不代表根因已解决；默认仍 SD 优先，SD 引导/救援系统未改，NVMe 优先候选固件只编译、未刷入。详见 [NVMe 启动研究](rock5c-nvme-boot.md)。
- 此前为彻底无 SD 的目标，已对照 A5E 的 SPI/NVMe 方案、Rockchip 手册、Radxa SPI 配置及主线驱动。独立 SPI 固件 + NVMe 完整系统需要兼容 SPI 模块（或 eMMC 前级），但本板共享插座为空；A5E 同型号 SSD 的供电/复位时序修复仅作诊断参考，未直接移植、未刷写。该方向现已暂缓。
- 无 SD 研究时用户曾要求不加硬件、不接受电脑辅助，只接电源独立冷启动。进一步核查固定版 U-Boot 的 ROM 来源映射、SPL/RAM/USB 引导与 rkdeveloptool 下载实现后，确认现有空插座硬件无法同时满足这些约束，未实现该功能。USB 辅助方案已停止，未为此构建/刷写固件或操作 OTP；最终收尾改为保留 SD，详见 [研究记录](rock5c-nvme-boot.md)。

## Linux 7.2.7 升级

- 本次升级将内核设为官方 stable 仓库的 `v7.2.7`（后续默认值以 `config/versions.conf` 为准）；升级旧工作区时须重新取源并编译，见[构建说明](build.md#内核版本)。
- M28K 检测到原生 RK3528 USB PHY 与设备树支持时跳过旧 USB 回移补丁，仍应用 SDIO 供电修复。
- 当前支持 4 块板 × 3 个发行版，使用 `bash scripts/test-kernel-config.sh` 做 dry-run 回归；已在 7.2.7 / 7.1-rc6 的相关上游源码文件上验证 M28K 补丁注入与重复执行。
- 下述历史真机实测记录来自升级前；7.2.7 已完成 ROCK5C 镜像、AIC8800 USB 编译和上节列出的首轮启动检查，其他板子的完整构建、AIC8800 SDIO 移植与 7.2.7 启动仍需验证。

## 已完成

- 2026-09-23：默认整盘镜像打包改为 `.img.xz`，可直接交给 balenaEtcher。
  ROCK5C 7.2.7 旧测试镜像已转包；解压后的 SHA-256 不变，未重编或修改系统内容。
  新增真实 XZ 往返、关闭压缩、缺少工具、压缩/校验失败保留旧包与原图的回归测试。

**通用**
- 主线 U-Boot + 主线 Linux + rootfs，整盘镜像，首启自动扩容
- GPU：内核 DRM（RK3528=lima / RK3588=Panthor）+ 用户态 Mesa
- 时间：chrony（aliyun NTP）+ tzdata（Asia/Shanghai），无 RTC 也能开机校时
- SSH（公钥 + 密码）、root 密码、串口控制台、mdev 热插拔
- 输出 `xz -T0 -6` 压缩为 `*.img.xz`（删除原始 `.img`）
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

**ROCK 5C（RK3588S2 / RK3582）—— 升级前内核已真机验证**
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
