# Radxa Dragon Q8B（Qualcomm SC8280XP）

> 状态：**镜像只跑 EL2（KVM 可用），根文件系统是 ZFS，已在真板上从 NVMe 启动验证**。开机没有 err 级别的内核日志，
> journal 里没有错误，也没有失败的服务。Wi-Fi/蓝牙（M.2 的 Intel AX210 系网卡）、声卡、GPU、双网口、
> Iris 硬件视频编解码（H.264/H.265）都正常。

Dragon Q8B 是高通 Snapdragon 8cx Gen 3（SC8280XP）开发板。它的启动链是厂商签名的板载固件加 UEFI，
构建器不编译、也不写入任何引导程序；镜像是一块 GPT 盘：EFI 系统分区（ESP）加一个 ZFS 池（`rpool`），由
systemd-boot 读 Boot Loader Specification 启动项引导内核与 initramfs，initramfs 导入池、挂上根。

```sh
DISTRO=debian make dragon-q8b      # 产出 out/radxa-dragon-q8b-debian-<内核版本>.img.xz
make dragon-q8b-dry                # 只看配置
```

## 板子的关键事实

| 项目 | 情况 | 本项目怎么处理 |
|---|---|---|
| 启动链 | SPI NOR：Qualcomm PBL → XBL → Radxa EDK2 UEFI，不可替换；开机 F2 进设置 | 不编引导程序，盘头 16 MiB 保持全零 |
| 启动盘 | 标准 GPT + ESP；默认顺序 USB → SD → NVMe → UFS，逐个找 `\EFI\BOOT\BOOTAA64.EFI` | 512M ESP（`p1`）+ ZFS 池（`p2`） |
| 设备树 | UEFI 自带一份；启动项里的 `devicetree` 可换成系统自带的 | 启动项里写 `devicetree`，用本项目编出的 DTB |
| 异常级别 | 默认在 Qualcomm 的 hypervisor 下以 EL1 启动；DTB 带 `/chosen/radxa,enable-kvm` 时固件改为 EL2 启动 | 只跑 EL2 |
| 主线内核 | 7.2.7 里没有 Q8B 的 DTS；TC956x 网卡驱动还在上游审阅 | 打 75 个补丁（见下） |
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
arm-packer/7.2.7/initrd.img                   导入 ZFS 池的 initramfs（约 13M）
arm-packer/7.2.7/dtbs/qcom/sc8280xp-radxa-dragon-q8b-el2.dtb
```

```
title      Debian 7.2.7 (Radxa Dragon Q8B)
version    7.2.7
linux      /arm-packer/7.2.7/Image
initrd     /arm-packer/7.2.7/initrd.img
devicetree /arm-packer/7.2.7/dtbs/qcom/sc8280xp-radxa-dragon-q8b-el2.dtb
options    root=ZFS=rpool/ROOT/debian rw console=tty1 console=ttyMSM0,115200n8 earlycon clk_ignore_unused efi=noruntime
```

### 根文件系统：ZFS

`board.conf` 里 `BOARD_ROOTFS_TYPE="zfs"`，由根文件系统插件 `lib/fs/zfs.sh` 负责；内核在 ESP 上，根
文件系统不受引导程序限制。给容器和虚拟机用，ZFS 的快照、克隆、压缩与校验比 ext4 合适。

- **池与数据集**：`rpool`（`ashift=12`、`autotrim=on`，特性集限定 `openzfs-2.2-linux`），根数据集
  `rpool/ROOT/debian`（`canmount=noauto`、挂在 `/`，是池的 `bootfs`）；所有数据集继承 `compression=zstd`、
  `atime=off`、`xattr=sa`、`acltype=posixacl`、`dnodesize=auto`。容器与虚拟机的数据集按需自己建，
  例如 `zfs create -o mountpoint=/var/lib/lxc rpool/lxc`。
- **模块**：OpenZFS 2.3.9 发布包（版本与 SHA-256 锁在 `config/versions.conf`）随内核编译，与内核的其他
  模块一起装进 `/lib/modules/<release>/extra`。升级内核时 `make kernel-build` 会一并编 ZFS；OpenZFS 的
  `Linux-Maximum`（2.3.9 为 7.2）不覆盖新内核时构建直接报错，要先换 OpenZFS 版本。
- **用户态**：Debian trixie contrib 的 `zfsutils-linux` 与 `zfs-initramfs`，与模块同为 2.3.9。
  `zfs-initramfs` 要求的 `zfs-modules` 由一个不含文件的 `arm-packer-zfs-modules` 包声明，`zfs-dkms`
  被 apt 钉死，不会装进编译器。
- **启动**：initramfs 由 initramfs-tools 为镜像内核生成，`MODULES=list`，只含 `spl.ko`、`zfs.ko`、
  `zpool`/`zfs`/`mount.zfs` 与导入脚本，约 13M（zstd），放在 ESP 内核旁。命令行是
  `root=ZFS=rpool/ROOT/debian`，fstab 里没有根，只有 ESP。`/etc/hostid` 随镜像固定，initramfs 里是同一份。
- **构建**：池在构建机上以临时名 `arm-packer-<pid>` 创建和导入，永远不会和构建机自己的 `rpool` 冲突；
  特性集限定在 2.2，构建机的 OpenZFS 比镜像新也不会启用镜像不认识的特性。收尾时 `zpool trim` 把空闲块
  还给稀疏镜像，再导出池，板子第一次导入时不会把它当成别的主机的池。构建机内核需要 zfs 模块（容器里
  要在宿主上 `modprobe zfs`）和 `zfsutils-linux`。
- **首次开机**：`firstboot-grow.service` 先把分区扩到整盘，再 `zpool online -e` 扩池。
- **ARC**：保持 OpenZFS 默认上限（内存减 1G），内存紧张时会让出；虚拟机多时可以用
  `options zfs zfs_arc_max=…` 压低。

### EL2 是怎么起来的

1. 镜像用的 DTB 是 `sc8280xp-radxa-dragon-q8b-el2.dtb`：板子 DTB 加一个 overlay（补丁 0063，由 dts
   Makefile 的 `-dtbs :=` 规则组合；引擎的 `kernel_dtb_has_source` 认这种没有 `.dts` 的 DTB）。
   overlay 加 `/chosen/radxa,enable-kvm`、ADSP 与 CDSP 的 `qcom,broken-reset`、EL2 虚拟定时器中断
   （PPI 12），以及 Iris 的 `video-firmware` 子节点（固件自己的 IOMMU 流 `0x2a02`）。
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
6. Iris 也没法通过 PAS 启动：它的复位与 IOMMU 处理在这代芯片上由 EL1 的 hypervisor 负责。补丁 0071
   （Stephan Gerhold 的 “media: iris: Port firmware loading without TZ/PAS from venus”）在有
   `video-firmware` 子节点时由内核自己加载固件、在固件的 IOMMU 流里映射、解除视频核心的复位，
   也就是 venus 驱动一直以来的做法。

### 板级（`boards/dragon-q8b/`）

- **内核补丁**（`linux/patches/`，75 个）：Armbian `sc8280xp-edge` 系列（armbian/build `1443dbae`）
  带到 7.2.7：删掉 7.2.7 已包含或已被上游替代的 5 个，刷新 2 个。另加 16 个，来源与理由逐个写在
  `linux/README.md`：
  - 0060 修 TC956x 网卡驱动在栈上未初始化的 IRQ 域参数（内核不自动清零栈时两个网口都起不来）；
  - 0061–0065 与 0071 是上面 EL2 用到的；
  - 0066–0069 去掉几条“把预期情况当错误打印”的日志：fw_devlink 的 sync_state 专用链接、sysmon 查询
    不存在的 CDSP shutdown-ack 中断、q6apm 把 DSP 就绪前的沉默当成命令失败、ACPI 核心在设备树平台上
    对没有 ACPI handle 的设备（iwlwifi、btintel）求值 `_DSM`；
  - 0070 是主线 “drm/msm: mark the fbdev framebuffer as system memory” 的回移植，0072 是 ASoC 树已接受的
    “lpass-{rx,wsa}-macro: sort reg_defaults before regmap init”；
  - 0073–0075：AudioReach 音量控件名不再拼接 widget 名（否则超过 ALSA 的 44 字节被截断）、拓扑的延迟
    绑定不再按 warning 打印、Adreno 的旧式 “vdd”/“vddcx” 电源改为可选获取。
- **内核片段**：`kconfig/qcom-sc8280xp.fragment`（SoC）+ `boards/dragon-q8b/kernel.fragment`（TC956x
  网卡、CH7218A HDMI、音频 codec、RTC）。从上电到根盘（含 NVMe）这一路全部内建，initramfs 只管导入
  ZFS 池。`DRM_MSM` 是模块：内建时 GPU 在根文件系统挂载前就请求固件，会报错；做成模块由 udev 在根文件系统挂好
  后加载，EFI framebuffer 撑到那时。`EEPROM_AT24` 与 GENI I2C 内建：TC9563 的 pwrctrl 要从这块 EEPROM
  读网口 MAC，做成模块时 PCIe 要一直延迟重试到 udev 起来。qcomtee 关掉：这块固件里的 QTEE 不响应内核的对象调用（EL1 下
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
- **内核命令行**：`clk_ignore_unused efi=noruntime`。`clk_ignore_unused` 固件在缺少时会自己加上；EFI 运行时
  服务固件支持不可靠。`pd_ignore_unused` 不需要：SoC 依赖的 GDSC 在供应者 sync_state 之前一直保持
  开启（去掉后连续重启 5 次、Wi-Fi 均正常）。EL1 需要的 `arm64.nopauth` 在 EL2 下不需要，指针认证可用。
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
4. 首次开机把根分区与 ZFS 池扩到整盘，并生成本机的 SSH 主机密钥与 DHCP 客户端 DUID（所以每次新刷的系统
   可能拿到不同的 IP）。登录 `root` / `120102`。
5. Wi-Fi：在 `/etc/wpa_supplicant/wpa_supplicant.conf` 填 SSID 与密码，`ifup wlan0`。

## 验证状态

- 引擎：全部板子 × 4 个发行版的 dry-run 与改动前逐项对比；shellcheck 干净；回归测试
  （`test-kernel`、`test-swupdate`、`test-image`）通过；opiz3 用新引擎重建并通过离线审计与 qemu
  开机测试（U-Boot 路径未回归）。
- Q8B 镜像离线审计：分区、ESP 内容与构建产物逐字节一致、唯一的启动项与 EL2 DTB（与板子 DTB 的差异
  恰好是上面几处）、qebspil 与 ESP 上的 DSP 固件、固件校验和与链接、内核配置与模块、fstab 的 ESP
  fsck、dosfstools、dhcpcd、Wi-Fi 用户态且没有 dbus；池以只读方式导入核对池属性、数据集属性与
  已导出状态，initramfs 解开核对只有 `spl.ko`/`zfs.ko`、导入工具齐全、hostid 与根文件系统一致。
- 真板（BIOS 6.0.260818，Intel SSDPEKKW256G8 NVMe 启动）：
  - 固件跳过 SD 从 NVMe 启动 → qebspil 启动 ADSP/CDSP → `CPU: All CPU(s) started at EL2` →
    initramfs 加载 OpenZFS 2.3.9、导入 `rpool`、挂上 `rpool/ROOT/debian`，内核 6.3 秒 + 用户态 10.1 秒；
    首启把池扩到 238G，根数据集 217M（zstd 压缩比 4.98x）。第二次开机
    `zfs-import-cache` 正常，`zpool status` 健康；快照、`zfs diff`、新建数据集挂载都正常。
  - `dmesg -l err` 与 `journalctl -p err` 都为空，没有失败的服务，`systemctl is-system-running` 为 running。
  - KVM 以 VHE 初始化，一个最小 KVM 程序在客户机里执行指令并按预期以 MMIO 退出；ADSP、CDSP
    `attached`；eth0 2.5 Gbps、DHCP、外网；iwlwifi 加载 API 89 固件并能扫描；蓝牙固件加载成功；
    声卡（DP0–2 与耳机孔，控件名不再截断）；GPU `gpu-initialized: 1`；ESP 挂载前 fsck 通过。
  - Iris：GStreamer `v4l2h264enc`/`v4l2h265enc` 各编码 120 帧 1080p60，再从文件用 `v4l2h264dec`/
    `v4l2h265dec` 解出全部 120 帧，画面与原图逐条色带一致，没有 IOMMU 故障。测试工具用后卸载，
    系统的软件包与镜像完全一致。
- 剩下的 warning（不是错误），修它们只能靠不正当的手段：
  - `qcom-pcie … supply vdda not found` 与 1c10000 的 `vddpe-3v3`：SC8280XP 的 PCIe binding 里没有 vdda，
    1c10000 下面是板载的 TC9563 而不是插槽，本就没有这路电；驱动的 2_7_0 供电处理被二十来个 SoC 共用，
    缺失时用占位电源是上游的设计。1c10000 那路随每次延迟重试重复打印，EEPROM 内建后从 15 次降到 5 次。
  - `arm-smmu-v3 … no priq irq`：PCIe SMMU 支持 PRI，但哪个 DT 都没有 PRI 队列中断号，不能猜；所有 PCIe
    节点都没开 ATS，PRI 用不上。
  - `Zap shader not enabled`：EL2 下固件关掉了 zap shader，上游 EL2 overlay 同样如此，这是 EL2 的正常路径。
  - `clk: Not disabling unused clocks`：固件总会在命令行里加上 `clk_ignore_unused`。
  - `spl: loading out-of-tree module taints kernel`、`zfs: module license 'CDDL' taints kernel`：ZFS 不在
    主线里、许可证是 CDDL，内核加载它时必然这样标记。initramfs 的 `lvm is not available` 是 ZFS 导入
    脚本顺带查找 LVM 卷时的提示，镜像没有 LVM。

## 下一步

| 阶段 | 内容 |
|---|---|
| eth1 | 接上网线验证传输 |
| Iris | 挂起/恢复与 VP9 解码的验证 |

## 风险与未验证项

- 补丁系列跟着上游变：DTS、网卡驱动都还在审阅，锁定 7.2.x 跟 Armbian，DTS 进主线后逐个删除。
- EL2 依赖固件对 `radxa,enable-kvm` 的处理；BIOS 升级若改了这一行为，镜像需要相应调整。
- BIOS 兼容选项必须保持默认，否则 UEFI 会改写我们提供的 DTB。
- DSP 崩溃后需要重启；风扇与 USB-C 都依赖 ADSP。EL2 下 DSP 由固件启动，内核不能重新加载它们。
- eth1 只验证了识别，未接网线测传输。
- Iris 的无 TZ 启动：固件 IOMMU 流 `0x2a02` 来自社区实测，不在官方 DT 里；绕过 TZ 意味着没有受保护内容
  播放；补丁上游尚未合入，以后可能要换成 Linux 管 IOMMU、TZ 做鉴权的新接口。
- ZFS 是 CDDL 许可，和 GPL 的内核一起分发二进制在法律上有争议：镜像适合自用，公开分发前要想清楚。
- 内核升级受 OpenZFS 支持范围约束（`Linux-Maximum`）；OpenZFS 与 Debian 的 `zfsutils-linux` 要一起升。
- 同一镜像刷出的板子共用 `/etc/hostid` 与池名 `rpool`；两块盘插进同一台机器时要按 GUID 改名导入。
- GStreamer 的 V4L2 解码器只认它预设的色彩描述组合，`videotestsrc` 生成的旧式 BT.601 描述
  （`2:4:5:4`）会协商失败；常见的 BT.709 视频不受影响。

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
