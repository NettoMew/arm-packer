# Radxa Dragon Q8B（Qualcomm SC8280XP）

> 状态：**EL1 与 EL2（KVM）镜像都已实现，并在真板上验证**。Wi-Fi/蓝牙（M.2 的 Intel AX210 系网卡）
> 与声卡已接通。还没做的是 EL2 下的视频编解码，见文末。

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
| 异常级别 | 默认在 Qualcomm 的 hypervisor 下以 EL1 启动；DTB 带 `/chosen/radxa,enable-kvm` 时固件改为 EL2 启动 | 两条启动项：EL1（默认）与 EL2 |
| 主线内核 | 7.2.7 里没有 Q8B 的 DTS；TC956x 网卡驱动还在上游审阅 | 打 63 个补丁（见下） |
| 串口 | 40 针排针 Pin 6 GND、Pin 8 TXD、Pin 10 RXD；`ttyMSM0`，115200 | `board.conf` 里写死；DTS 补了 `stdout-path`，`earlycon` 可用 |
| USB | 两个 Type-C 在 DTS 里都是 host | 不能当 One-KVM 的 USB 设备端 |

## 实现

### 引擎：启动方式交给厂商插件

引擎里原来写死的 U-Boot + extlinux 已下放给厂商插件（`lib/vendor/<vendor>.sh`），厂商 source 对应的
启动方式：

| 启动方式 | 用它的厂商 | 内核放哪 | 启动配置 |
|---|---|---|---|
| `lib/boot/uboot.sh` | rockchip、allwinner | 根分区 `/boot` | `/boot/extlinux/extlinux.conf` |
| `lib/boot/uefi.sh` | qcom | ESP `/arm-packer/<版本>/` | `loader/entries/arm-packer-<版本>[-<变体>].conf` |

分区由 `vendor_partition_layout` 声明，引擎按布局建分区、格式化、挂载，fstab 自动带上 ESP。
`IMAGE_SIZE` 仍只表示根文件系统的预算，ESP 的 512M 另加，所以 Debian 镜像是 2G 根 + 512M ESP。

systemd-boot 取自 Debian 的 `systemd-boot-efi` arm64 包，版本与 SHA-256 锁在 `config/versions.conf`，
只用其中的 `systemd-bootaa64.efi`，和目标发行版无关。`BOARD_BOOT_VARIANTS="名称=DTB …"` 为每个变体
多写一条启动项：同一个内核、同一条命令行，只换 DTB；`loader.conf` 的默认项固定是普通那条。

ESP 内容：

```
EFI/BOOT/BOOTAA64.EFI                         systemd-boot
EFI/systemd/systemd-bootaa64.efi
EFI/systemd/drivers/qebspilaa64.efi           EL2 用的 DSP 预启动驱动（见下）
firmware/qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn   给 qebspil 用的 ADSP 固件
firmware/qcom/sc8280xp/qccdsp8280.mbn                    给 qebspil 用的 CDSP 固件
loader/loader.conf                            default arm-packer-7.2.7.conf，timeout 3
loader/entries/arm-packer-7.2.7.conf          EL1（默认）
loader/entries/arm-packer-7.2.7-el2.conf      EL2
arm-packer/7.2.7/Image                        带 EFI stub
arm-packer/7.2.7/dtbs/qcom/sc8280xp-radxa-dragon-q8b.dtb
arm-packer/7.2.7/dtbs/qcom/sc8280xp-radxa-dragon-q8b-el2.dtb
```

```
title      Debian 7.2.7 (Radxa Dragon Q8B, EL2)
version    7.2.7
linux      /arm-packer/7.2.7/Image
devicetree /arm-packer/7.2.7/dtbs/qcom/sc8280xp-radxa-dragon-q8b-el2.dtb
options    root=PARTUUID=… rootwait rw console=tty1 console=ttyMSM0,115200n8 earlycon clk_ignore_unused pd_ignore_unused arm64.nopauth efi=noruntime
```

### EL2 是怎么起来的

1. EL2 的 DTB 在板子 DTB 上只多三处：`/chosen/radxa,enable-kvm`、ADSP 和 CDSP 上的
   `qcom,broken-reset`，外加关掉 Iris。固件看到 `radxa,enable-kvm` 就以 EL2 启动系统，并自己补上 EL2
   需要的设备树改动（PCIe 的 SMMU、GPU 的 zap shader）。BIOS 的 “Hypervisor Override” 必须保持 Auto。
2. EL2 下内核没法通过 PAS 接口启动 DSP。systemd-boot 在菜单前自动加载 `EFI/systemd/drivers/` 里的
   qebspil（[stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)，锁在 `config/versions.conf`，带一个补丁，
   见 `boards/dragon-q8b/qebspil/`）。它读启动项装进来的 DTB，只在 `ExitBootServices()` 前启动带
   `qcom,broken-reset` 的 DSP，固件从 ESP 的 `/firmware/` 按 DTB 的 `firmware-name` 取。EL1 的 DTB
   没有这个属性，qebspil 在 EL1 下什么都不做。
3. 内核补丁 0061（Radxa 的 “attach to preloaded firmware”）在 probe 时通过 SMP2P 状态发现 DSP 已在
   运行，把 remoteproc 标成 detached，由 remoteproc 核心 attach，而不是重新加载。
4. Iris 在 EL2 下加载固件失败（PAS 返回 `-EINVAL`），EL2 的 DTB 里把它关掉，和主线 X1 的 EL2
   overlay 一样。

### 板级（`boards/dragon-q8b/`）

- **内核补丁**（`linux/patches/`，63 个）：Armbian `sc8280xp-edge` 系列（armbian/build `1443dbae`）
  带到 7.2.7：删掉 7.2.7 已包含或已被上游替代的 5 个，刷新 2 个。另加 4 个：0060 修 TC956x 网卡驱动
  在栈上未初始化的 IRQ 域参数（内核不自动清零栈时两个网口都起不来），0061 让 PAS 驱动 attach 已被
  固件启动的 DSP，0062 给 DTS 补 `stdout-path`，0063 编出 EL2 的 DTB。每个补丁的来源和刷新内容见
  `linux/README.md`。
- **内核片段**：`kconfig/qcom-sc8280xp.fragment`（SoC）+ `boards/dragon-q8b/kernel.fragment`（TC956x
  网卡、CH7218A HDMI、音频 codec、RTC）。不用 initramfs，所以从上电到挂上根分区这一路全部内建。
  `DRM_MSM` 依赖 `QCOM_OCMEM || QCOM_OCMEM=n`，基线把 OCMEM 编成模块会把 DRM_MSM 压成模块，片段里把
  OCMEM 改成内建。
- **固件**（`firmware.lock`）：13 个文件和 2 个符号链接，按 commit 与 SHA-256 锁定，由引擎的
  `install_firmware_lock` 下载校验后装进 `/lib/firmware`：
  - ADSP 与 CDSP 取 radxa-firmware（Radxa OS 与 Armbian 实际使用的构建，ADSP 里带风扇控制服务）；
  - GPU、zap shader、视频固件取 linux-firmware；
  - 声卡的 AudioReach 拓扑取 Armbian 的固件仓库（耳机孔与三路 DisplayPort）；
  - M.2 上的 Intel AX210 系网卡（如 Killer AX1675x）：iwlwifi API 89 固件与 PNVM（这个内核只认 89）、
    `ibt-0041-0041` 蓝牙固件，均取自 linux-firmware；
  - wireless-regdb 的 `regulatory.db` 与签名。
  DTS 引用的 `qupv3fw.elf` 哪里都没有发布，UEFI 已把串行引擎配置好，内核用不到它。
- **Wi-Fi 用户态**：`wpasupplicant` 与 `iw`，`/etc/network/interfaces` 里带 `wlan0` 模板
  （`lib/wifi.sh`，与 M28K、ROCK 5C 共用）。bluez 依赖 dbus，镜像不装；蓝牙固件照常加载，需要时
  `apt install bluez`。

## 使用

1. `xz -dc radxa-dragon-q8b-debian-*.img.xz | dd of=/dev/sdX bs=4M conv=fsync`，写到 U 盘、microSD 或 NVMe。
2. BIOS 的 “Third-party OS Compatibility” 选项与 “Hypervisor Override” 保持默认。
3. 开机后 systemd-boot 3 秒倒计时进入默认项（EL1）；菜单里选 “EL2” 那条进 EL2，`/dev/kvm` 可用。
   串口接 40 针排针 8/10 脚，115200。
4. 首次开机把根分区扩到整盘，并生成本机的 SSH 主机密钥。登录 `root` / `120102`。
5. Wi-Fi：在 `/etc/wpa_supplicant/wpa_supplicant.conf` 填 SSID 与密码，`ifup wlan0`。

想让 EL2 成为默认并在失败时自动回到 EL1，可用 systemd-boot 的启动计数：把 EL2 启动项改名为
`arm-packer-7.2.7-el2+3.conf`、加一行 `sort-key arm-packer`，`loader.conf` 的 `default` 改成
`arm-packer-*`。连续三次没进系统，这条启动项就排到最后，默认回到 EL1。镜像里没有
`systemd-bless-boot`（`efi=noruntime` 下没有 EFI 变量），成功进系统后计数不会自动清除，需要把文件名里
的 `+…` 去掉。

## 验证状态

- 引擎：全部板子 × 4 个发行版的 dry-run 与改动前逐项对比，只有 Q8B 的输出有变化；shellcheck 干净；
  opiz3 用新引擎重建并通过离线审计与 qemu 开机测试（U-Boot 路径未回归）。
- Q8B 镜像离线审计：分区、ESP 内容与构建产物逐字节一致、两条启动项与两个 DTB（EL2 与普通 DTB 的
  差异恰好是上面四处）、qebspil 与 ESP 上的 DSP 固件、13 个固件校验和与 2 个链接、内核配置与模块、
  Wi-Fi 用户态且没有 dbus。
- 真板（BIOS 6.0.260818，microSD 启动）：
  - EL1：UEFI → systemd-boot → 内核不带 initramfs 挂上根分区，约 17 秒到串口登录。首启扩容、ESP、
    两块 NVMe、TC9563 交换芯片与两个 TC956x 网口（eth0 2.5 Gbps、DHCP、apt）、ADSP/CDSP、声卡
    （DP0–2 与耳机孔）、GPU（`gpu-initialized: 1`）、Iris、HDMI 控制台、RTC、earlycon 均正常。
    iwlwifi 加载 API 89 固件，`wlan0` 可扫描；蓝牙固件加载成功（`hci0`）；`regulatory.db` 加载成功。
  - EL2：`CPU: All CPU(s) started at EL2`，KVM 以 VHE 初始化；qebspil 启动 ADSP 与 CDSP，内核
    `attached`；网络、声卡、GPU 正常，没有 SMMU 故障，没有失败的服务。一个最小 KVM 程序在客户机里执行
    三条指令并按预期以 MMIO 退出（`KVM_GET_API_VERSION = 12`，写出值 42）。启动计数回退也按预期工作。
- 已知现象：
  - 开机 5 秒左右 fbdev 先打开 GPU，那时根分区还没挂，日志里有一条 `a660_sqe.fw` 加载失败；之后任何
    程序打开 DRM 设备都会重新加载，GPU 正常。
  - 更新后的第一次 EL1 启动在加载 CDSP 固件时整板复位过一次，随后三次 EL1 启动都正常，未能复现。

## 下一步

| 阶段 | 内容 |
|---|---|
| EL2 视频编解码 | EL2 下 Iris 起不来。社区方案是换回 venus 驱动（HFI6）配 Gen1 固件 `vpu20_p4.mbn` |

## 风险与未验证项

- 补丁系列跟着上游变：DTS、网卡驱动都还在审阅，锁定 7.2.x 跟 Armbian，DTS 进主线后逐个删除。
- 不带 initramfs 的启动在真板上只验证了 microSD 作根分区；NVMe 作根分区时 PCIe、pwrctrl 与
  fw_devlink 的顺序还要确认，备选是加 `fw_devlink=permissive`。
- EL2 依赖固件对 `radxa,enable-kvm` 的处理；BIOS 升级若改了这一行为，EL2 启动项会失效，EL1 不受影响。
- BIOS 兼容选项必须保持默认，否则 UEFI 会改写我们提供的 DTB。
- DSP 崩溃后需要重启；风扇与 USB-C 都依赖 ADSP。EL2 下 DSP 由固件启动，内核不能重新加载它们。

## 参考

- Radxa 文档：<https://docs.radxa.com/en/dragon/q8b>
- 上游 DTS 补丁串：<https://ratatoskr.run/linux-arm-msm/2026/09/17490306/t>
- Armbian 支持：<https://github.com/armbian/build/pull/10215>
- Radxa 固件包：<https://github.com/radxa-pkg/radxa-firmware>
- Radxa 内核（PAS attach 补丁）：<https://github.com/radxa/kernel/commit/7bf1919dfc5e873808f48231156aa12b64d926cc>
- Armbian 固件仓库（音频拓扑）：<https://github.com/armbian/firmware>
- linux-firmware：<https://gitlab.com/kernel-firmware/linux-firmware>
- wireless-regdb：<https://git.kernel.org/pub/scm/linux/kernel/git/wens/wireless-regdb.git>
- EL2 社区方案：<https://github.com/ctr54188/radxa-dragon-q8b-fixes>、<https://github.com/stephan-gh/qebspil>
- X13s 主线参考：<https://github.com/jhovold/linux/wiki/X13s>
