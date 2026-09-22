# ROCK5C：FPC NVMe 启动研究

日期：2026-09-23。对象：ROCK5C / Linux 7.2.7 / Alpine 3.24.2；现已临时选择 NVMe 完整系统启动，SD 前级引导及默认顺序仍未修改。

**NVMe 系统部署、文件系统校验及一次断电冷启动后的完整系统启动均已通过：Image、DTB、根文件系统都来自 NVMe。此前软重启后的 U-Boot 探测超时尚未解决，不能宣称启动稳定性已验证。SD 引导与救援系统未修改，NVMe 优先候选固件尚未刷入。**

## 本轮收尾决定：保留 SD 引导（2026-09-23）

- 用户最终选择保留 SD 卡，不再推进购买 SPI 模块或无 SD 独立启动方案；以下 SPI/USB 内容仅作为历史研究保留。
- 保持已交付固件及默认 **SD 优先** 顺序，`ROCK5C_NVME_BOOT=0` 不变。原 SD 完整系统继续作为默认启动与救援路径，没有刷入实验性的 NVMe-first 固件。
- NVMe 已安装的系统保留。本轮最后一次真机检查是在串口临时选择 NVMe 后运行；本次收尾仅整理仓库，不重启板卡、不重新格式化，也不宣称已经切回 SD 根文件系统。
- **SD 前级 + NVMe 完整系统** 的一次冷启动验证保留为实验结果，不升级为自动启动默认值；NVMe 热重启超时仍未解决。后续若恢复此路线，须先完成下文稳定性回归。

## 无 SD 约束与源码核查结论（历史研究）

此前用户要求：**不增加硬件、不保留 SD、不接受电脑辅助，每次完全断电后只接电源独立启动 NVMe**。这些是研究时的约束，现已由上面的保留 SD 决定取代；下文 SPI 方案不是本轮实施范围。

在这块 eMMC/SPI 插座为空的 ROCK5C 上，上述条件不能同时实现。缺失的是 BootROM 能读取的持久化前级引导，不是 Linux 的 NVMe 驱动。当前没有符合这些约束的可实施纯软件方案，不把“开机后拔卡”、kexec、USB RAM 下载或不断电待机记为实现。

本轮审计的是公开的相关启动链源码与芯片文档，**不是声称取得或完整审计了芯片固化的 BootROM 源码**：

| 层级 / 固定源码 | 核查结果 |
|---|---|
| [Rockchip RK3588S 数据手册 §1.2.2](https://wiki.friendlyelec.com/wiki/images/8/8b/Rockchip_RK3588S_Datasheet_V1.5-20231110.pdf#page=7) | ROM 列出的启动介质是 SPI、eMMC、SD/MMC；USB OTG 用于下载代码，没有 NVMe 启动入口。 |
| U-Boot `ece349ade…`：[rk3588.c 的 boot_devices](https://github.com/u-boot/u-boot/blob/ece349ade2973e220f524ce59e59711cc919263f/arch/arm/mach-rockchip/rk3588/rk3588.c) | RK3588 的 ROM 来源映射对应 eMMC、FSPI M0/M1/M2 和 SD。它是 U-Boot 对 ROM 来源的解释，不是可用于给 ROM 增加驱动的配置表。 |
| 同版 [spl-boot-order.c](https://github.com/u-boot/u-boot/blob/ece349ade2973e220f524ce59e59711cc919263f/arch/arm/mach-rockchip/spl-boot-order.c) | `board_boot_order()` 在 SPL 已经运行后才选择下一阶段；RAM 优先分支要求 ROM 来源为 USB 且启用 RAM_DEVICE。不能解决“先从哪里加载 SPL”。 |
| 同版 [spl.c](https://github.com/u-boot/u-boot/blob/ece349ade2973e220f524ce59e59711cc919263f/arch/arm/mach-rockchip/spl.c)、`rockchip-u-boot.dtsi`、Kconfig | 已有 `ROCKCHIP_MASKROM_IMAGE` 和 RAM 中 FIT 的加载实现，USB471 为 DDR 初始化，USB472 为 SPL 与 FIT。说明无需自造 USB 引导协议，但断电后 RAM 内容不保留，仍需主机下载。 |
| rkdeveloptool `304f0737…`：[RKDevice.cpp](https://github.com/rockchip-linux/rkdeveloptool/blob/304f073752fd25c854e1bcf05d8e7f925b1f4e14/RKDevice.cpp) | `DownloadBoot()` 使用 USB `0x471` / `0x472` 请求发送代码。它不把 NVMe 变成 BootROM 支持的介质；用户已明确拒绝这一主机辅助路线。 |
| PCIe/NVMe、BootSTD/extlinux | 在已运行的 U-Boot 中负责发现 SSD 和加载系统，本板已实测可用；修改此层不会让代码在 BootROM 之前执行。 |

通用 `bootrom.h` 中还声明其他 Rockchip SoC 的来源编号，不能将通用枚举误读为 RK3588 支持所有对应启动接口，也不能据此把板上普通 EEPROM 当成启动 Flash。

USB 路线在用户拒绝后已停止：没有构建或下载 RAM 引导产物，没有切换 MaskROM，没有重启/刷写板卡，没有操作 OTP/eFuse。编译容器只启动做了源码查询，现已停止。保留现有 NVMe 系统和 SD 救援；审计材料在 `work/rock5c-rom-usb-research-20260923/`。

## 最新部署进展（2026-09-23）

- 用户明确授权清空 `E2M2 64GB` NVMe，已用交付的 Alpine 3.24.2 / Linux 7.2.7 镜像覆盖旧分区。此为系统重装，不是安全擦除承诺。
- XZ 校验、解压后 SHA-256、写入后全部 2 GiB 回读哈希均通过。重新分配 GPT 磁盘/分区 UUID 和 ext4 UUID，更新 NVMe 自己的 extlinux/fstab，避免与 SD 冲突。
- 根文件系统已离线扩容至约 56.7 GiB，`e2fsck`、GPT 校验通过。Image/DTB/更新公钥与原交付产物一致；同一板卡的 SSH 主机身份及 dhcpcd 状态保留。
- NVMe 根分区 PARTUUID：`9e0f770f-2f0e-4340-ad98-a8a61001dd14`；文件系统 UUID：`9e9f5734-0f39-45cc-b5b5-abb6c454212e`。
- `BLKRRPART` 后遇到 BusyBox mdev 的异步分区节点移除/创建问题：sysfs 已有新分区，但 `/dev/nvme0n1p1` 缺失。经等待、`mdev -s` 及核对设备 major/minor 后恢复；没有将第一次失败误判为扩容成功。
- **软重启问题仍待解决**：部署后 U-Boot NVMe 探测返回 `-110`；在失败状态下再次 PCI 枚举/探测曾发生无效 BAR 映射及同步异常复位，随后恢复 SD 启动。另一次独立软复位探测仍未完成；不得在已失败的探测状态下盲目重复 PCI 枚举。
- **用户完全断电再上电后验证通过**：截停 U-Boot，`pci enum`、`nvme scan/info/part` 成功；`bootflow scan -lGH nvme` 找到 1 个 `ready` 的 extlinux bootflow。检查配置后执行 `bootflow select 0` / `bootflow boot`，串口记录明确从该 NVMe bootflow 加载 `/boot/Image` 和板级 DTB，随后进入 Linux。
- **运行系统验证通过**：SSH 恢复为 `root@169.254.192.252`；`/proc/self/mountinfo` 的根设备 `259:1` 经 sysfs 解析为 `nvme0n1p1`，以 ext4 可读写挂载。Image/DTB SHA-256 与交付产物一致；运行 Linux 7.2.7 / Alpine 3.24.2、7 核在线、BTF 存在，NVMe 状态为 `live`。根文件系统 56.7 GiB，可用约 53.2 GiB。本次日志未见 NVMe I/O 超时或 ext4 错误，但仍有已知 SUBNQN、GIC 等警告；未做持续负载验证。
- 冷启动成功与此前软重启失败表明两条路径的表现不同，**还不能据此确定 SSD 固件、供电、复位时序或 U-Boot 哪一项是根因**。本次只是串口临时选盘，默认仍为 SD 优先；没有再次重启，当前保留 NVMe 系统运行，COM3 已释放。
- 已编译 `ROCK5C_NVME_BOOT=1` 可选候选固件：板级 DT 的 BootSTD 顺序为 NVMe → SD → eMMC → USB，显式使用 extlinux，并清空会覆盖 DT 顺序的旧 `boot_targets`。默认值仍为 `0`，原 SD 优先行为不变；该配置不支持 EFI 系统。
- **候选固件尚未刷入 SD**，不应在 NVMe 启动问题定位前视为可交付引导。产物在 `out/rock5c-nvme-boot-20260923/`；离线板级补丁测试和 12 个板卡/发行版配置回归通过。
- 安装/后续调试证据：`work/rock5c-nvme-install-20260923/`，尤其是 `serial-coldboot-nvme-scan.log`、`serial-first-nvme-linux-boot.log`、`live-nvme-verification.log` 和 `live-nvme-dmesg.log`。以下“本机证据”为安装前的研究记录，不代表当前仍从 SD 运行。

## 结论

FPC 转 M.2 是 PCIe 通路，不要求再移植一种“FPC 存储驱动”。本机 NVMe 已在 Linux 下识别，当前主线 U-Boot 构建也具备该 PCIe 控制器、PHY、NVMe 和 ext4/extlinux 支持。

必须区分 **BootROM 从哪里加载前级引导** 和 **U-Boot 从哪里加载操作系统**。把整盘系统镜像写入 NVMe，不会让 BootROM 自动具备从 PCIe SSD 加载引导程序的能力。Radxa 官方的 ROCK5C 无 SD 启动流程使用 SPI 引导加 NVMe 系统盘。[官方 NVMe 安装说明](https://docs.radxa.com/en/rock5/rock5c/getting-started/install-os/nvme)

| 方案 | 启动链（简写） | 适用情况 |
|---|---|---|
| SD 引导 + NVMe 完整系统 | BootROM → SD 上 DDR/SPL、BL31、U-Boot → NVMe 上 extlinux、Image、DTB、rootfs | 当前临时验证路径；不购买额外模块，仍需插 SD |
| SPI 引导 + NVMe 完整系统 | BootROM → SPI 上 DDR/SPL、BL31、U-Boot → NVMe 上完整系统 | 历史备选，已暂缓；需合适的 SPI 模块与专用引导产物 |
| SD 内核 + NVMe rootfs | BootROM → SD 引导与内核 → NVMe rootfs | 可作为临时诊断路径，不建议作为长期默认布局 |

第一种已作为临时验证通过；第二种曾作为脱离 SD 的研究方向，现已暂缓。两种方案都把 `/boot`、DTB、`/lib/modules` 和 rootfs 放在同一个 NVMe 系统布局中，避免更新了 SSD 上模块却仍启动 SD 上旧内核。将来若增加 SPI，可保留现有 NVMe 系统，不必仅为切换前级引导再次重装 SSD；本轮仍保留原 SD 默认引导。

ROCK5C 的可选 SPI Flash 模块使用 eMMC 共用插座，两者不能同时插；它不是 FPC 转 M.2 板本身提供的功能。[Radxa SPI 模块](https://radxa.com/products/accessories/spi-flash-module/)、[插座说明](https://docs.radxa.com/en/rock5/rock5c/hardware-design/hardware-interface#emmc-socket--spi-flash-connector)

## 无 SD 方案：对照 A5E 与上游的补充调查

### 硬件边界

- 用户提供的 [A5E 启动文档](https://github.com/NettoMew/vyos-sbc/blob/main/docs/boards/a5e/boot.md) 实际采用 **SPI → U-Boot → NVMe EFI/GRUB → 系统**；并没有让 BootROM 直接读取 NVMe。可借鉴的是分阶段部署、介质身份隔离、SPI 备份/读回及拔卡冷/热启动验收，不能直接刷它的 Allwinner 固件。
- Rockchip 的 [RK3588S 数据手册 §1.2.2](https://wiki.friendlyelec.com/wiki/images/8/8b/Rockchip_RK3588S_Datasheet_V1.5-20231110.pdf#page=7) 列出的 ROM 启动介质为 SPI、eMMC、SD/MMC；USB OTG 是代码下载入口，不是 ROM 自动从 U 盘或 NVMe 加载完整系统。修改 extlinux、切换 GRUB/UEFI 或重写 SSD 分区不能补上这一阶段。
- 本机 eMMC/SPI 插座已由用户确认为空。因此，**现有硬件不增加启动介质时，无法拔掉 SD 后独立上电启动**。需要一个官网明确支持 ROCK 5A/5C 的 SPI Flash 模块；若已有兼容 eMMC，也可仅放前级固件，但不为此要求安装整套 eMMC 系统。
- 选择接到专用插座的模块，不把 40-pin 上的一般 SPI 外设总线等同于 BootROM 的 FSPI 启动连接。官方 [接口引脚](https://docs.radxa.com/en/rock5/rock5c/hardware-design/hardware-interface#emmc-socket--spi-flash-connector) 和 [v1.1 原理图第 21 页](https://dl.radxa.com/rock5/5c/docs/hw/v1100/radxa_rock_5c_schematic_v1100.pdf#page=21) 明确给出 eMMC/FSPI 共享信号。

### 可复用的现成实现

1. **官方对照路线**：ROCK5C 文档已有 `rsetup` 更新 SPI 后拔 SD 启动 NVMe 的流程；Radxa 源码已有 [SPI defconfig](https://github.com/radxa/u-boot/blob/next-dev-v2024.10/configs/rock-5c-spi-rk3588s_defconfig) 及 [SPI 板级 DTS](https://github.com/radxa/u-boot/blob/next-dev-v2024.10/arch/arm/dts/rk3588s-rock-5c-spi.dts)。后者禁用 `sdhci`、启用 `sfc` 并使用 `fspim0_pins`，可作为硬件配置对照；不能直接混入主线的 Kconfig/打包流程。官方 Radxa OS 的 `rsetup` 操作也不能原样当作当前 Alpine 的安装命令。
2. **本项目优先路线**：继续复用已验证的主线 U-Boot、RK3582 板级补丁和 DDR/BL31，增加独立 SPI 构建配置；使用上游 SFC/SPI-NOR、SPL 和 Binman 生成专用 `u-boot-rockchip-spi.bin`。不重写启动器、不为了换存储而引入 GRUB。当前已编译的 NVMe-first SD 候选产物 **不是 SPI 产物**。[上游 Rockchip SPI 文档](https://docs.u-boot.org/en/latest/board/rockchip/rockchip.html#spi)
3. SPI 配置需要核对实际模块 JEDEC ID、容量、电压及擦除块；同时处理 U-Boot/SPL 和 Linux DT 的 eMMC/FSPI 互斥。不能只打开一个 SPI Kconfig 就宣布支持，更不能套 ROCK5B 的引脚或固件。

### SPI 布局与恢复策略（历史设计，尚未部署）

```text
BootROM → SPI 的 DDR/SPL、BL31、U-Boot
                         ↓ 上游 BootSTD / extlinux
              NVMe 的 /boot、DTB、modules、rootfs
```

- SPI 仅放低频更新的前级固件；内核更新只操作 NVMe 系统，默认不触碰 SPI。
- 建议 SPI profile 采用 **SD 救援优先 → NVMe → USB 救援**：日常不插 SD，自动启动 NVMe；插入匹配的救援卡时可明确进入救援。它与之前的“SD 上 NVMe-first”候选不是同一用途，不应混淆两者配置。
- 保留串口截停及可拆卸 SPI 模块的恢复通路；必要时断电移除模块，用已验证的 SD 重新启动。MaskROM/USB 恢复需要另核对本板预留引脚和连接方式，不能假设已经验收。
- SD 插入恢复和 NVMe 缺失回退必须实测；BootSTD 的介质回退仍不等于 Linux 启动失败后的健康检测/自动回滚。

### E2M2 软重启问题：找到有价值的对照，但没有现成已验证修复

参考仓库检出提交：`64ef0c1575830a3e8a5296c257cbde999b74fa1a`。

- [A5E PCIe 实测](https://github.com/NettoMew/vyos-sbc/blob/64ef0c1575830a3e8a5296c257cbde999b74fa1a/docs/boards/a5e/pcie.md) 记录了相同 E2M2 64GB / `10100080` 固件、`1217:8760` 控制器；其完整时序修正后，无 SD 冷启动和普通重启通过。这是另一平台的项目实测，不是 ROCK5C 的兼容保证。
- 其 [U-Boot 0075 补丁](https://github.com/NettoMew/vyos-sbc/blob/64ef0c1575830a3e8a5296c257cbde999b74fa1a/boards/a5e/uboot/patches/always/0075-a5e-owned-slot-power-sequence.patch) 在枚举前关断插槽电源并等待、再上电，在交接时配合 PERST#、LTSSM 和供电释放；内核 177 也处理了对应关机路径。**可借鉴所有权和时序检查方法，不能照搬 sun55i 驱动、GPIO 或延迟值。**
- 本项目固定 U-Boot 提交的 ROCK5C DTS 已有 `pcie2x1l2_3v3` regulator（GPIO0_C5），复位为 GPIO3_D1；该 regulator 本就没有 A5E 补丁删除的 `always-on` / `boot-on`。因此简单删属性不是本机修复方案。[固定版本 DTS](https://github.com/u-boot/u-boot/blob/ece349ade2973e220f524ce59e59711cc919263f/dts/upstream/src/arm64/rockchip/rk3588s-rock-5c.dts)
- 已对照当前上游 `pcie_dw_rockchip.c` 与交付版本，文件 SHA-256 相同；未发现可仅通过更新这一文件就得到的现成新修复。当前实现有 PERST/REFCLK 等待，但没有 A5E 同类的显式插槽断电等待及 OS 交接 remove 路径。这只是源码差异，**还不能证明其导致了本机超时**。
- 本次仅只读查看运行时 GPIO/regulator：NVMe `live`，插槽电源由 PCIe host 持有，GPIO0_C5 和 GPIO3_D1 均为高；未重启、未复位、未断电、未刷写。由于根文件系统就在 NVMe，**绝不能在当前 Linux 中直接拉 GPIO 或关 regulator 来测试**。
- 下一步受控实验应在正常关机/重启、文件系统不再挂载的 U-Boot 或独立救援环境中进行，先核对 FPC 扩展板的实际供电连线，再比较 PERST 保持、插槽断电等待与正常重新枚举。PCI/NVMe 已失败后不盲目反复扫描；不把任意加大超时当成修复。

### 无 SD 验收门槛

1. 模块到位前先解决并回归现有 SD 前级 + NVMe 系统的软重启问题；更换到 SPI 不会自动修好 PCIe 时序。
2. 模块安装后只读识别、完整备份至主机，再使用板型匹配、来源/哈希已确认的 SPI 专用固件；保护擦除块边界及非固件区域，写后做全片预期内容比较。
3. 正常关机、断电、拔掉 SD；串口确认 SPL 从 SPI 加载，Linux 确认无 SD 块设备且根分区、Image/DTB 身份正确。
4. 无 SD 冷启动和普通 reboot 多轮验证，做有界文件写入/直接读回及空闲测试，检查 I/O 错误。
5. 插回 SD 验证救援，检查拔掉 NVMe 时的失败/恢复行为，再标记为可交付。

本轮下载的参考补丁、固定源码和只读运行状态位于 `work/rock5c-spi-research-20260923/`；没有应用 A5E 补丁，没有改写现有固件或系统。

## 安装前的本机证据（历史记录）

### Linux 与硬盘

- SSD：`E2M2 64GB`，固件 `10100080`，控制器状态 `live`。
- 通路：`a41000000.pcie` → `0004:41:00.0`；实际协商 `5.0 GT/s`、宽度 `1`，即 Gen2 ×1。这是链路观测值，不是磁盘性能实测值。
- Linux 日志：`PCIe Gen.2 x1 link up`，随后识别 `nvme0n1` / `nvme0n1p1`。
- `CONFIG_PCIE_ROCKCHIP_DW_HOST`、`CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY`、`CONFIG_BLK_DEV_NVME`、`CONFIG_NVME_CORE` 和 `CONFIG_EXT4_FS` 均为 `y`；现有普通 ext4/NVMe 根分区方案不需要单纯为了加载这些驱动再加 initramfs。LVM、加密根分区则是另一套启动要求。
- 当前 `/` 仍在 SD。NVMe 未挂载，但已有 GPT 分区，类型标记为 Linux LVM；这不证明有效 LVM 内容，也**不证明它是空盘**。迁移前必须确认数据保留/清空策略。
- 保留当前已配置的 `nvme_core.default_ps_max_latency_us=0 pcie_aspm=off`。它们用于规避此前记录的掉盘问题；本次没有持续负载、读写压力或掉电测试，不能据此宣称长期稳定。

### 当前 U-Boot 构建

审计的是交付镜像使用的源码/构建目录，不是另一份最新默认配置：

- 提交：`ece349ade2973e220f524ce59e59711cc919263f`，附项目 RK3582 开核补丁。
- `CONFIG_NVME_PCI=y`、`CONFIG_CMD_NVME=y`、`CONFIG_PCIE_DW_ROCKCHIP=y`、`CONFIG_PHY_ROCKCHIP_NANENG_COMBOPHY=y`、`CONFIG_FS_EXT4=y`。
- `CONFIG_BOOTSTD_FULL=y`、`CONFIG_BOOTMETH_EXTLINUX=y`；`bootcmd=bootflow scan -lb`。
- ROCK5C DT 已启用 `pcie2x1l2`，包含 PCIe 3.3 V 电源、复位 GPIO 和对应 PHY。
- 源码默认 `boot_targets=mmc1 mmc0 nvme scsi usb pxe dhcp spi`：**SD 上现有可启动系统排在 NVMe 前面**。只写好 SSD、原样保留 SD，不等于下次就会启动 SSD。
- `CONFIG_ENV_IS_NOWHERE=y`：不能设计成依赖一次 `setenv` + `saveenv` 来永久改变顺序。

现成轮子就是上游 **U-Boot Standard Boot + extlinux**，无需另造扫描磁盘、找内核的启动器。持久化策略优先使用板级 BootSTD 配置；上游支持 `bootdev-order`，但本构建的 `boot_targets` 会覆盖它，实施时须同步处理，不能只添加一个无效 DT 属性。[Standard Boot 文档](https://docs.u-boot.org/en/latest/develop/bootstd/overview.html)

### U-Boot 串口实测（用户授权软重启后）

COM3 / 1500000 / 8N1，先打开串口，再通过 SSH 执行正常 `reboot`，截停自动启动。观察到 SPL 从 MMC2 加载，U-Boot 显示 ROCK5C / RK3582 / 4 GiB，与交付构建版本一致。

- `printenv bootcmd boot_targets` 与上述构建默认值一致，未修改或保存环境。
- `pci enum` / `pci`：枚举到 `1d87:3588` PCIe 桥和 `1217:8760` NVMe 控制器。
- `nvme scan` / `nvme info`：设备 0、固件 `10100080`、`120831998 × 512` 字节，容量约 57.6 GiB。
- `nvme part`：成功读取 GPT；分区起止 LBA、Linux LVM 类型和分区 GUID 与 Linux 下记录一致。这一步也验证了 U-Boot 的实际磁盘读取，不只是配置中启用了驱动。
- `bootflow scan -lG nvme`：仅扫描 NVMe，跳过全局启动方法，不带自动启动参数；结果为 **`0 bootflows, 0 valid`**。不能据此认为现有分区没有数据，只能说明本次扫描没有发现可启动配置。
- 检查后执行原有 `run bootcmd`，观察到选择 SD 的 `/boot/extlinux/extlinux.conf` 并加载 `/boot/Image`。随后 Linux 7.2.7 和 SSH 恢复，根设备经 sysfs 确认为 `mmcblk1p1`；extlinux/fstab 内容及 NVMe GPT 与检查前记录一致，COM3 已释放。没有尝试启动 SSD 上未知内容。

**结论：U-Boot 阶段的 FPC/NVMe 枚举和 GPT 读取已通过；下一关是经数据处理授权后部署 NVMe 系统并验证内核、DTB、rootfs 均来自 NVMe。**

### SPI 路线当前缺什么

- 用户已确认 eMMC/SPI 共用插座为空：本机既没有 eMMC，也没有 SPI Flash 模块。现有硬件应先采用 SD 前级引导；不能只保留 NVMe、拔掉 SD 就独立开机。
- Linux `/proc/mtd` 为空，但运行时 SFC 节点 `spi@fe2b0000` 本身为 `disabled`，因此空 MTD **不能单独证明物理上没有 SPI 模块**。
- 当前 U-Boot 未启用 `CONFIG_ROCKCHIP_SPI_IMAGE`、`CONFIG_SPL_SPI` 或 `CONFIG_ROCKCHIP_SFC`，没有生成 `u-boot-rockchip-spi.bin`。
- SPI 方案需专用板级配置：确认模块型号/容量和引脚复用，启用 SFC 与 SPL 的 SPI 读取路径、相应 NOR 支持及 SPI 打包，并处理与 eMMC 的互斥。Linux 中要管理 SPI 时也需相应 DT 配置。
- 不可把现在的 `u-boot-rockchip.bin` 或 `.img.xz` 当作 SPI 固件。上游明确区分 SD 的 `u-boot-rockchip.bin` 与 SPI 的 `u-boot-rockchip-spi.bin`。[U-Boot Rockchip 刷写说明](https://docs.u-boot.org/en/latest/board/rockchip/rockchip.html#spi)
- 不能直接套 ROCK5B 的 SPI 镜像；也不能假定厂商现成 ROCK5C 引导保留本项目 RK3582 开核行为。优先复用当前已验证的引导源码、DDR/BL31 和板级补丁，单独构建/验证 SPI 产物。

## 验证顺序与后续步骤（恢复 NVMe 自动启动研究时）

1. 先确认 NVMe 现有数据；没有明确授权不重分区、不格式化、不覆盖。
2. **已完成**：经允许软重启后，COM3 截停 U-Boot，执行只读枚举：
   ```text
   pci enum
   nvme scan
   nvme info
   nvme part
   ```
   核对型号、容量和 PCIe 链路；失败则先排查 U-Boot 的供电/复位/PHY，而不是改 Linux root 参数。
3. **已完成**：使用已校验的交付镜像离线部署 NVMe 普通 ext4 系统及 `/boot/extlinux/extlinux.conf`，没有在线裸复制运行中的 SD 根文件系统。
4. **已完成，必须避免 SD/NVMe 克隆 UUID 冲突**：为目标盘生成独立 GPT 磁盘/分区身份及文件系统 UUID，同步它自己的 extlinux `root=PARTUUID=...` 与 fstab；已校验源 SD 身份未被改动。
5. **已完成一次冷启动后的临时选盘**：不修改默认引导、不依赖 `saveenv`。本次先显式 PCI/NVMe 探测，再用 `bootflow scan -lGH nvme` 扫描（不重复 hunter、跳过全局启动方法、不自动启动），检查配置后选择并启动该 bootflow。[bootflow 命令说明](https://docs.u-boot.org/en/latest/usage/cmd/bootflow.html)
6. **已完成**：串口证明 Image/DTB **从 NVMe 加载**，Linux `/proc/self/mountinfo` 的根设备 major:minor 经 sysfs 解析确实指向 NVMe。仅看到 `uname -r=7.2.7` 或 `/dev/root` 不足以证明迁移成功。
7. **待完成**：定位软重启探测超时，验证重复冷启动/暖重启、空闲/负载、NVMe 缺失时的恢复路径。成功后才持久化 NVMe 优先策略；保留可明确选择的 SD 救援系统。

**边界**：BootSTD 找不到 NVMe/引导文件时继续扫描救援介质，不等于 Linux 启动后卡死也能自动回滚。后者需要独立的健康确认、启动次数与恢复设计；当前项目尚未实现。

## 与后续内核更新的关系

- 正常内核更新只管理实际启动系统的 `/boot`、DTB 和模块；不把 SPI/SD 前级引导写入每次更新的路径。
- SPI/SD 引导固件更新独立、低频执行，先验证兼容与恢复手段。
- 当前 SWUpdate 仅完成安装器/签名基础设施，不能因换到 NVMe 就宣称已经具备内核切换或自动回滚。
- 将来实现时，NVMe 安装属于独立存储部署流程，ROCK5C 的 SPI 配置留在板级/厂商插件，不把板名判断塞入通用构建引擎。

本地只读证据保存在 `work/rock5c-nvme-research-20260923/`，未纳入版本控制。
