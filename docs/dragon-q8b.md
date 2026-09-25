# Radxa Dragon Q8B（Qualcomm SC8280XP）

> 状态：**镜像只跑 EL2（KVM 可用），已在真板上从 NVMe 启动验证**。开机没有 err 级别的内核日志，
> journal 里没有错误，也没有失败的服务。Wi-Fi/蓝牙（M.2 的 Intel AX210 系网卡）、声卡、GPU、双网口都正常。
> 还没做的是 EL2 下的视频编解码，见文末。

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
| 启动盘 | 标准 GPT + ESP；默认顺序 USB → SD → NVMe → UFS，逐个找 `\EFI\BOOT\BOOTAA64.EFI` | 512M ESP（`p1`）+ ext4 根（`p2`） |
| 设备树 | UEFI 自带一份；启动项里的 `devicetree` 可换成系统自带的 | 启动项里写 `devicetree`，用本项目编出的 DTB |
| 异常级别 | 默认在 Qualcomm 的 hypervisor 下以 EL1 启动；DTB 带 `/chosen/radxa,enable-kvm` 时固件改为 EL2 启动 | 只跑 EL2 |
| 主线内核 | 7.2.7 里没有 Q8B 的 DTS；TC956x 网卡驱动还在上游审阅 | 打 70 个补丁（见下） |
| 串口 | 40 针排针 Pin 6 GND、Pin 8 TXD、Pin 10 RXD；`ttyMSM0`，115200 | `board.conf` 里写死；DTS 补了 `stdout-path`，`earlycon` 可用 |
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
UEFI 固件每次开机读 ESP 都会留下 FAT 的脏标记，所以 vfat 分区在 fstab 里 fsck 序号为 2，挂载前由
systemd-fsck 清掉，引擎为此装 dosfstools。

systemd-boot 取自 Debian 的 `systemd-boot-efi` arm64 包，版本与 SHA-256 锁在 `config/versions.conf`，
只用其中的 `systemd-bootaa64.efi`，和目标发行版无关。

ESP 内容：

```
EFI/BOOT/BOOTAA64.EFI                         systemd-boot
EFI/systemd/systemd-bootaa64.efi
EFI/systemd/drivers/qebspilaa64.efi           DSP 预启动驱动（见下）
firmware/qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn   给 qebspil 用的 ADSP 固件
firmware/qcom/sc8280xp/qccdsp8280.mbn                    给 qebspil 用的 CDSP 固件
loader/loader.conf                            default arm-packer-7.2.7.conf，timeout 3
loader/entries/arm-packer-7.2.7.conf
arm-packer/7.2.7/Image                        带 EFI stub
arm-packer/7.2.7/dtbs/qcom/sc8280xp-radxa-dragon-q8b-el2.dtb
```

```
title      Debian 7.2.7 (Radxa Dragon Q8B)
version    7.2.7
linux      /arm-packer/7.2.7/Image
devicetree /arm-packer/7.2.7/dtbs/qcom/sc8280xp-radxa-dragon-q8b-el2.dtb
options    root=PARTUUID=… rootwait rw console=tty1 console=ttyMSM0,115200n8 earlycon clk_ignore_unused pd_ignore_unused efi=noruntime
```

### EL2 是怎么起来的

1. 镜像用的 DTB 是 `sc8280xp-radxa-dragon-q8b-el2.dtb`：板子 DTB 加一个 overlay（补丁 0063，由 dts
   Makefile 的 `-dtbs :=` 规则组合；引擎的 `kernel_dtb_has_source` 认这种没有 `.dts` 的 DTB）。
   overlay 加 `/chosen/radxa,enable-kvm`、ADSP 与 CDSP 的 `qcom,broken-reset`、EL2 虚拟定时器中断
   （PPI 12），并关掉 Iris。
2. 固件看到 `radxa,enable-kvm` 就以 EL2 启动系统，并自己补上 EL2 需要的设备树改动：开启 PCIe 的
   SMMU 并给各 PCIe 控制器加 `iommu-map`，关掉 GPU 的 zap shader，给 SCM 节点加
   `qcom,shm-bridge-vmid = SELF_OWNER`。BIOS 的 “Hypervisor Override” 必须保持 Auto。
3. EL2 下内核没法通过 PAS 接口启动 DSP。systemd-boot 在菜单前自动加载 `EFI/systemd/drivers/` 里的
   qebspil（[stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)，锁在 `config/versions.conf`，带一个补丁，
   见 `boards/dragon-q8b/qebspil/`）。它读启动项装进来的 DTB，在 `ExitBootServices()` 前启动带
   `qcom,broken-reset` 的 DSP，固件从 ESP 的 `/firmware/` 按 DTB 的 `firmware-name` 取。
4. 内核补丁 0061（Radxa 的 “attach to preloaded firmware”）在 probe 时通过 SMP2P 状态发现 DSP 已在
   运行，由 remoteproc 核心 attach，而不是重新加载。
5. 补丁 0064/0065（Stephan Gerhold）让 tzmem 读 `qcom,shm-bridge-vmid`，EL2 下以 self owner 方式建
   SHM bridge。

### 板级（`boards/dragon-q8b/`）

- **内核补丁**（`linux/patches/`，70 个）：Armbian `sc8280xp-edge` 系列（armbian/build `1443dbae`）
  带到 7.2.7：删掉 7.2.7 已包含或已被上游替代的 5 个，刷新 2 个。另加 11 个，来源与理由逐个写在
  `linux/README.md`：
  - 0060 修 TC956x 网卡驱动在栈上未初始化的 IRQ 域参数（内核不自动清零栈时两个网口都起不来）；
  - 0061–0065 是上面 EL2 用到的；
  - 0066–0069 去掉几条“把预期情况当错误打印”的日志：fw_devlink 的 sync_state 专用链接、sysmon 查询
    不存在的 CDSP shutdown-ack 中断、q6apm 把 DSP 就绪前的沉默当成命令失败、ACPI 核心在设备树平台上
    对没有 ACPI handle 的设备（iwlwifi、btintel）求值 `_DSM`；
  - 0070 是主线 “drm/msm: mark the fbdev framebuffer as system memory” 的回移植。
- **内核片段**：`kconfig/qcom-sc8280xp.fragment`（SoC）+ `boards/dragon-q8b/kernel.fragment`（TC956x
  网卡、CH7218A HDMI、音频 codec、RTC）。不用 initramfs，从上电到挂上根分区（含 NVMe）这一路全部
  内建。`DRM_MSM` 是模块：内建时 GPU 在根分区挂载前就请求固件，会报错；做成模块由 udev 在根分区挂好
  后加载，EFI framebuffer 撑到那时。qcomtee 关掉：这块固件里的 QTEE 不响应内核的对象调用（EL1 下
  版本查询得 0.0.0，EL2 下直接 `-EINVAL`），镜像里也没有用它的程序。
- **固件**（`firmware.lock`）：13 个文件和 2 个符号链接，按 commit 与 SHA-256 锁定，由引擎的
  `install_firmware_lock` 下载校验后装进 `/lib/firmware`：
  - ADSP 与 CDSP 取 radxa-firmware（Radxa OS 与 Armbian 实际使用的构建，ADSP 里带风扇控制服务）；
  - GPU、zap shader、视频固件取 linux-firmware；
  - 声卡的 AudioReach 拓扑取 Armbian 的固件仓库（耳机孔与三路 DisplayPort）；
  - M.2 上的 Intel AX210 系网卡（如 Killer AX1675x）：iwlwifi API 89 固件与 PNVM（这个内核只认 89）、
    `ibt-0041-0041` 蓝牙固件，均取自 linux-firmware；
  - wireless-regdb 的 `regulatory.db` 与签名。
  DTS 引用的 `qupv3fw.elf` 哪里都没有发布，UEFI 已把串行引擎配置好，内核用不到它。
- **内核命令行**：`clk_ignore_unused pd_ignore_unused efi=noruntime`。`pd_ignore_unused` 不能去：去掉后
  M.2 Wi-Fi 卡在 PCIe SMMU 上出翻译故障、随后 PCIe 致命错误、卡丢失（实测）；`clk_ignore_unused` 固件
  自己也会加上；EFI 运行时服务固件支持不可靠。EL1 需要的 `arm64.nopauth` 在 EL2 下不需要，指针认证可用。
- **Wi-Fi 用户态**：`wpasupplicant` 与 `iw`，`/etc/network/interfaces` 里带 `wlan0` 模板
  （`lib/wifi.sh`，与 M28K、ROCK 5C 共用）。bluez 依赖 dbus，镜像不装；蓝牙固件照常加载，需要时
  `apt install bluez`。Debian 的 dhcpcd 设为 `background`，没插网线的网口不会卡 30 秒再报超时。

## 使用

1. `xz -dc radxa-dragon-q8b-debian-*.img.xz | dd of=/dev/sdX bs=4M conv=fsync`，写到 U 盘、microSD 或 NVMe。
   写 NVMe 前先 `wipefs -a`（最好 `blkdiscard`）清掉整盘，盘尾的旧签名（例如旧 ZFS 池的标签）不会被
   2.5G 的镜像覆盖。
2. BIOS 的 “Third-party OS Compatibility” 选项与 “Hypervisor Override” 保持默认。
3. 固件按 USB → SD → NVMe 的顺序找启动盘。要从 NVMe 启动，拔掉带系统的 SD 卡（或把它的
   `EFI/BOOT/BOOTAA64.EFI` 改名）。串口接 40 针排针 8/10 脚，115200。
4. 首次开机把根分区扩到整盘，并生成本机的 SSH 主机密钥与 DHCP 客户端 DUID（所以每次新刷的系统
   可能拿到不同的 IP）。登录 `root` / `120102`。
5. Wi-Fi：在 `/etc/wpa_supplicant/wpa_supplicant.conf` 填 SSID 与密码，`ifup wlan0`。

## 验证状态

- 引擎：全部板子 × 4 个发行版的 dry-run 与改动前逐项对比；shellcheck 干净；回归测试
  （`test-kernel`、`test-swupdate`、`test-image`）通过；opiz3 用新引擎重建并通过离线审计与 qemu
  开机测试（U-Boot 路径未回归）。
- Q8B 镜像离线审计：分区、ESP 内容与构建产物逐字节一致、唯一的启动项与 EL2 DTB（与板子 DTB 的差异
  恰好是上面几处）、qebspil 与 ESP 上的 DSP 固件、固件校验和与链接、内核配置与模块、fstab 的 ESP
  fsck、dosfstools、dhcpcd、Wi-Fi 用户态且没有 dbus。
- 真板（BIOS 6.0.260818，Intel SSDPEKKW256G8 NVMe 启动）：
  - 固件跳过 SD 从 NVMe 启动 → qebspil 启动 ADSP/CDSP → `CPU: All CPU(s) started at EL2` → 不带
    initramfs 挂上 NVMe 根分区，约 14 秒到登录；首启把根分区扩到 235G。
  - `dmesg -l err` 与 `journalctl -p err` 都为空，没有失败的服务，`systemctl is-system-running` 为 running。
  - KVM 以 VHE 初始化，一个最小 KVM 程序在客户机里执行指令并按预期以 MMIO 退出；ADSP、CDSP
    `attached`；eth0 2.5 Gbps、DHCP、外网；iwlwifi 加载 API 89 固件并能扫描；蓝牙固件加载成功；
    声卡（DP0–2 与耳机孔）；GPU `gpu-initialized: 1`；ESP 挂载前 fsck 通过。
- 剩下的 warning（不是错误），都来自设备树描述、固件或上游驱动：
  - `qcom-pcie … supply vdda/vddpe-3v3 not found` 与 `adreno … supply vdd/vddcx not found`：DTS 没写
    这些供电，内核用占位 regulator；1c10000 那路因为 TC9563 的 pwrctrl 反复 probe 而重复出现。
  - `arm-smmu-v3 … no priq irq`：PCIe SMMU 的 DT 节点没有 PRI 队列中断。
  - `Zap shader not enabled`：EL2 下固件关掉了 zap shader，这是 EL2 的正常路径。
  - `clk: Not disabling unused clocks`、`genpd: Not disabling unused power domains`：命令行的两个参数有意为之。
  - `rx_macro … Unsorted reg_defaults`：上游驱动至今未修。
  - `ASoC: Parent card not yet available` 与四条 `ALSA: Control name … truncated`：声卡按拓扑延迟绑定、
    拓扑里的控件名超长。

## 下一步

| 阶段 | 内容 |
|---|---|
| EL2 视频编解码 | EL2 下 Iris 起不来。社区方案是换回 venus 驱动（HFI6）配 Gen1 固件 `vpu20_p4.mbn` |

## 风险与未验证项

- 补丁系列跟着上游变：DTS、网卡驱动都还在审阅，锁定 7.2.x 跟 Armbian，DTS 进主线后逐个删除。
- EL2 依赖固件对 `radxa,enable-kvm` 的处理；BIOS 升级若改了这一行为，镜像需要相应调整。
- BIOS 兼容选项必须保持默认，否则 UEFI 会改写我们提供的 DTB。
- DSP 崩溃后需要重启；风扇与 USB-C 都依赖 ADSP。EL2 下 DSP 由固件启动，内核不能重新加载它们。
- eth1 只验证了识别，未接网线测传输。

## 参考

- Radxa 文档：<https://docs.radxa.com/en/dragon/q8b>
- 上游 DTS 补丁串：<https://ratatoskr.run/linux-arm-msm/2026/09/17490306/t>
- Armbian 支持：<https://github.com/armbian/build/pull/10215>
- Radxa 固件包：<https://github.com/radxa-pkg/radxa-firmware>
- Radxa 内核（PAS attach、tzmem self owner）：<https://github.com/radxa/kernel/tree/linux-7.0.11>
- Armbian 固件仓库（音频拓扑）：<https://github.com/armbian/firmware>
- linux-firmware：<https://gitlab.com/kernel-firmware/linux-firmware>
- wireless-regdb：<https://git.kernel.org/pub/scm/linux/kernel/git/wens/wireless-regdb.git>
- EL2 社区方案：<https://github.com/ctr54188/radxa-dragon-q8b-fixes>、<https://github.com/stephan-gh/qebspil>
- X13s 主线参考：<https://github.com/jhovold/linux/wiki/X13s>
