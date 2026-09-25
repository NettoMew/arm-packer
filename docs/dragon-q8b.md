# Radxa Dragon Q8B（Qualcomm SC8280XP）

> 状态：**EL1 镜像已实现**（引擎 UEFI 启动方式 + 板级支持）。EL2 / KVM、UFS 的 4K 扇区镜像、
> 音频拓扑与 UCM 还没做，见文末。标注“未验证”的结论需要真板确认。

Dragon Q8B 是高通 Snapdragon 8cx Gen 3（SC8280XP）开发板。它的启动链是厂商签名的板载固件加 UEFI，
构建器不编译、也不写入任何引导程序；镜像是一块 GPT 盘：EFI 系统分区（ESP）加 ext4 根分区，由
systemd-boot 读 Boot Loader Specification 启动项引导内核。

```sh
DISTRO=debian make dragon-q8b      # 产出 out/radxa-dragon-q8b-debian-<内核版本>.img.xz
make dragon-q8b-dry                # 只看配置
```

## 板子的关键事实

| 项目 | 情况 | 本项目怎么处理 |
|---|---|---|
| 启动链 | SPI NOR：Qualcomm PBL → XBL → Radxa EDK2 UEFI，不可替换；开机 F2 进设置 | 不编引导程序，盘头 16 MiB 保持全零 |
| 启动盘 | 标准 GPT + ESP；默认顺序 USB → SD → NVMe → UFS | 512M ESP（`p1`）+ ext4 根（`p2`） |
| 设备树 | UEFI 自带一份；Radxa 官方用启动项里的 `devicetree` 换成系统自带的 | 启动项里写 `devicetree`，用本项目编出的 DTB |
| 主线内核 | 7.2.7 里没有 Q8B 的 DTS；TC956x 网卡驱动还在上游审阅 | 打 60 个补丁（见下） |
| 串口 | 40 针排针 Pin 6 GND、Pin 8 TXD、Pin 10 RXD；`ttyMSM0`，115200 | `board.conf` 里写死 |
| UFS | 需要 4096 字节逻辑扇区的镜像 | 还没做；先用 USB / microSD / NVMe |
| USB | 两个 Type-C 在 DTS 里都是 host | 不能当 One-KVM 的 USB 设备端 |

## 实现

### 引擎：启动方式交给厂商插件

引擎里原来写死的 U-Boot + extlinux 已下放给厂商插件（`lib/vendor/<vendor>.sh`），厂商 source 对应的
启动方式：

| 启动方式 | 用它的厂商 | 内核放哪 | 启动配置 |
|---|---|---|---|
| `lib/boot/uboot.sh` | rockchip、allwinner | 根分区 `/boot` | `/boot/extlinux/extlinux.conf` |
| `lib/boot/uefi.sh` | qcom | ESP `/arm-packer/<版本>/` | `loader/entries/arm-packer-<版本>.conf` |

分区由 `vendor_partition_layout` 声明，引擎按布局建分区、格式化、挂载，fstab 自动带上 ESP。
`IMAGE_SIZE` 仍只表示根文件系统的预算，ESP 的 512M 另加，所以 Debian 镜像是 2G 根 + 512M ESP。

systemd-boot 取自 Debian 的 `systemd-boot-efi` arm64 包，版本与 SHA-256 锁在 `config/versions.conf`，
只用其中的 `systemd-bootaa64.efi`，和目标发行版无关。

ESP 内容：

```
EFI/BOOT/BOOTAA64.EFI                       systemd-boot
EFI/systemd/systemd-bootaa64.efi
loader/loader.conf                          default arm-packer-*，timeout 3
loader/entries/arm-packer-7.2.7.conf
arm-packer/7.2.7/Image                      带 EFI stub
arm-packer/7.2.7/dtbs/qcom/sc8280xp-radxa-dragon-q8b.dtb
```

```
title      Debian 7.2.7 (Radxa Dragon Q8B)
version    7.2.7
linux      /arm-packer/7.2.7/Image
devicetree /arm-packer/7.2.7/dtbs/qcom/sc8280xp-radxa-dragon-q8b.dtb
options    root=PARTUUID=… rootwait rw console=tty1 console=ttyMSM0,115200n8 earlycon clk_ignore_unused pd_ignore_unused arm64.nopauth efi=noruntime
```

### 板级（`boards/dragon-q8b/`）

- **内核补丁**（`linux/patches/`，60 个）：Armbian `sc8280xp-edge` 系列（armbian/build `1443dbae`）
  带到 7.2.7：删掉 7.2.7 已包含或已被上游替代的 5 个，刷新 2 个；另加 0060，修 TC956x 网卡驱动在栈上
  未初始化的 IRQ 域参数（内核不自动清零栈时两个网口都起不来）。每个补丁的来源和刷新内容见
  `linux/README.md`。
- **内核片段**：`kconfig/qcom-sc8280xp.fragment`（SoC）+ `boards/dragon-q8b/kernel.fragment`（TC956x
  网卡、CH7218A HDMI、音频 codec、RTC）。不用 initramfs，所以从上电到挂上根分区这一路全部内建。
  `DRM_MSM` 依赖 `QCOM_OCMEM || QCOM_OCMEM=n`，基线把 OCMEM 编成模块会把 DRM_MSM 压成模块，片段里把
  OCMEM 改成内建。
- **固件**（`firmware.lock`）：6 个文件按 commit 与 SHA-256 锁定，由引擎的 `install_firmware_lock`
  下载校验后装进 `/lib/firmware`。ADSP 与 CDSP 取 radxa-firmware（Radxa OS 与 Armbian 实际使用的
  构建，ADSP 里带风扇控制服务）；GPU、zap shader、视频固件取 linux-firmware。DTS 引用的
  `qupv3fw.elf` 哪里都没有发布，UEFI 已把串行引擎配置好，内核用不到它。

## 使用

1. `xz -dc radxa-dragon-q8b-debian-*.img.xz | dd of=/dev/sdX bs=4M conv=fsync`，写到 U 盘、microSD 或 NVMe。
2. BIOS 的 “Third-party OS Compatibility” 选项保持默认（关）：它们改写的是固件自带的设备树，本镜像
   不用那份。
3. 开机后 systemd-boot 3 秒倒计时进入默认项；串口接 40 针排针 8/10 脚，115200。
4. 首次开机把根分区扩到整盘，并生成本机的 SSH 主机密钥。登录 `root` / `120102`。

## 验证状态

- 引擎重构：现有 4 块板 × 4 个发行版的 dry-run 与重构前逐项对比，只多出分区布局一行；三组回归
  测试通过；opiz3 用新引擎重建并通过离线审计与 qemu 开机测试（U-Boot 路径未回归）。
- Q8B 镜像：离线审计（分区、ESP 内容与构建产物逐字节一致、固件校验和、内核配置与模块）。
- UEFI 路径：同一镜像在 qemu virt + edk2 上经 systemd-boot 启动（测试副本额外加一个不带
  `devicetree` 的启动项），验证 BLS、EFI stub、无 initramfs 挂根、fstab 挂 ESP、首启扩容。
- 真板（BIOS 6.0.260818，microSD 启动）：UEFI → systemd-boot → 内核不带 initramfs 挂上根分区，
  约 17 秒到串口登录。首启扩容、ESP 挂载、两块 NVMe 与 Wi-Fi 卡枚举、TC9563 交换芯片、ADSP/CDSP、
  HDMI 控制台、RTC 均正常；两个 TC956x 网口都识别（MAC 取自 EEPROM），eth0 接线后 2.5 Gbps、
  DHCP、apt 可用，eth1 未接线测试；GPU 首次打开时加载固件（`gpu-initialized: 1`）。
- 已知现象：开机 5 秒左右 fbdev 先打开 GPU，那时根分区还没挂，日志里有一条 `a660_sqe.fw` 加载
  失败；之后任何程序打开 DRM 设备都会重新加载，GPU 正常。

## 下一步

| 阶段 | 内容 |
|---|---|
| EL2 / KVM | qebspil（systemd-boot 驱动目录加载，预启动 ADSP/CDSP）、remoteproc 接管补丁、tzmem self-owner 补丁、EL2 DTB（主线 `sc8280xp-el2.dtso` + `radxa,enable-kvm` + `shm-bridge-vmid` + `qcom,broken-reset` + Venus），启动计数回退 EL1 |
| UFS | 4096 字节扇区镜像（`losetup --sector-size 4096`） |
| 音频 | Q8B 的 AudioReach 拓扑（自 `.m4` 编译）与 Radxa 的 UCM |

## 风险与未验证项

- 补丁系列跟着上游变：DTS、网卡驱动都还在审阅，锁定 7.2.x 跟 Armbian，DTS 进主线后逐个删除。
- 不带 initramfs 的启动在真板上只验证了 microSD 作根分区；NVMe 作根分区时 PCIe、pwrctrl 与
  fw_devlink 的顺序还要确认，备选是加 `fw_devlink=permissive`。
- M.2 上用户自装的 Wi-Fi/蓝牙卡（如 Intel AX1675）的固件不在镜像里，按需自行安装。
- BIOS 兼容选项必须保持默认，否则 UEFI 会改写我们提供的 DTB。
- DSP 崩溃后需要重启；风扇与 USB-C 都依赖 ADSP。

## 参考

- Radxa 文档：<https://docs.radxa.com/en/dragon/q8b>
- 上游 DTS 补丁串：<https://ratatoskr.run/linux-arm-msm/2026/09/17490306/t>
- Armbian 支持：<https://github.com/armbian/build/pull/10215>
- Radxa 固件包：<https://github.com/radxa-pkg/radxa-firmware>
- linux-firmware：<https://gitlab.com/kernel-firmware/linux-firmware>
- EL2 社区方案：<https://github.com/ctr54188/radxa-dragon-q8b-fixes>、<https://github.com/stephan-gh/qebspil>
- X13s 主线参考：<https://github.com/jhovold/linux/wiki/X13s>
