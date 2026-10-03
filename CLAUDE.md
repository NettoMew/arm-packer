# CLAUDE.md — 项目向导（给 Claude Code 看的）

主线 SBC 固件构建器：从主线源码为多块 Rockchip / Allwinner / Qualcomm 开发板构建可直接烧录的整盘镜像。
**三根正交插件轴：board × vendor × distro**，外加根文件系统轴（`lib/fs`）、用途轴（`lib/profile`，`PROFILE`）与 kconfig
片段/合约轴。引擎 `lib/*.sh` 里**没有任何 board/vendor/distro/profile 的 `if` 分支**——差异全在插件/配置里。加一块板/一个发行版/
一种用途 = 加一个文件，不改引擎。

## 入口 & 跑法
- `make <board>`（`e20c`/`m28k`/`m28k-noscreen`/`rock5c`/`rock5c-stock`/`opiz3`/`dragon-q8b`/`all`）→ 调 `scripts/build.sh`。
- 等价 `BOARD=rock5c DISTRO=archlinux scripts/build.sh`。Incus 主机：`DISTRO=debian PROFILE=incus make <board>`（见 `docs/incus.md`）。
- `make <board>-dry` / `scripts/build.sh --dry-run`：只解析配置、打印片段/钩子/镜像名，**不构建、不联网、不 sudo**（秒级，验证改动的首选）。
- `scripts/build.sh --stop-after-kconfig`：编到内核 `.config` 就停（用于对比 `.config`）。
- 默认源码版本集中在 `config/versions.conf`；`make kernel-check/kernel-build BOARD=... KERNEL_REF=vX.Y.Z`
  使用全新独立验证工作区，不取 U-Boot/固件、不做 rootfs。`kernel-promote` 需成功 build 报告与人工真机确认，见 `docs/kernel-updates.md`。
- 以普通用户跑；需要 root 的步骤自动 `sudo`。成品在 `out/`，镜像名 `<前缀>-<distro>[-<profile>]-<内核版本>.img.xz`。

## 目录 / 职责
```
scripts/build.sh    唯一入口(orchestrator)：解析 flags → 载 board.conf → 载 vendor+distro+fs+profile+hooks → 派生 → run_pipeline
lib/log,env,deps,workspace,sources,kernel,image,rootfs,wifi,pipeline.sh   引擎模块(distro/vendor 无关)
lib/aic8800.sh                       板子按需 source 的共享能力：AIC8800 驱动
lib/zfs.sh                           共享能力：OpenZFS 随内核编模块 + 装同版本用户态（ZFS 根与 incus profile 共用，一次构建只做一次）
lib/profile/{base,incus}.sh          用途插件(PROFILE)：profile_* 契约；base 什么都不加；incus = 合约 + Zabbly Incus + ZFS 池
lib/vendor/{rockchip,allwinner,qcom}.sh   厂商插件(启动链)：vendor_* 契约
lib/boot/{uboot,uefi}.sh             启动方式，由厂商插件 source：U-Boot + extlinux / 板载 UEFI + systemd-boot(ESP, BLS)
lib/distro/{alpine,archlinux,debian,eweos}.sh   发行版插件(用户态)：distro_* 契约
lib/distro/common/systemd.sh         systemd 系插件(archlinux/debian)共用的离线原语，由插件自行 source
lib/fs/{ext4,zfs}.sh                 根文件系统插件(ROOTFS_TYPE)：fs_* 契约；zfs 随内核编 OpenZFS 模块、带 initramfs
boards/<board>/board.conf            每板声明式配置(必填键见下)
boards/{m28k,rock5c}/hooks.sh        板级钩子(可选)：board_* 函数；就近放 DTS/补丁/固件移植/OLED
kconfig/*.fragment + distro-arm64.config   可组合内核片段(见 kconfig/README.md)
kconfig/*.contract                   能力合约(incus、dae)：profile 依赖的内核能力，既是请求也是门禁
resources/rootfs/                    固定 rootfs 文件(resize 脚本、wpa 模板、interfaces 基底)
resources/incus/                     Zabbly 密钥 + Incus 主机覆盖层(首启初始化、ARC 上限、sysctl/limits)
resources/systemd/  resources/debian/   systemd 早期扩容单元 / Debian 的 dpkg+apt 策略与 rootfs 覆盖层
work/  out/                          源码树工作区 / 成品
```

## 契约（改引擎时照着调用，别加 if 分支）
- **board.conf**（纯赋值）必填：`BOARD_VENDOR BOARD_SOC BOARD_KERNEL_DTB BOARD_IMAGE_PREFIX
  BOARD_HOSTNAME BOARD_MENU_TITLE BOARD_SERIAL_CONSOLE` + 厂商要求的键（`vendor_required_keys`，
  U-Boot 厂商要 `BOARD_UBOOT_DEFCONFIG`）；选填 `BOARD_SERIAL_BAUD BOARD_KERNEL_CMDLINE_EXTRA
  BOARD_SECOND_NIC BOARD_NICS BOARD_KERNEL_FRAGMENTS BOARD_ROOTFS_TYPE`（默认 ext4）。
  可选 `firmware.lock`（按 commit + SHA-256 锁固件；`file`/`link`/`source`，URL 可用 `{path}` 占位）。
- **vendor_\***（`lib/vendor/<vendor>.sh`）：`vendor_required_keys / _select_blobs / _default_fragments /
  _fetch_extra / _fetch_assert_skip / _assert_sources / _build_bootloader / _partition_table /
  _partition_layout / _write_bootloader / _install_boot / _firmware_extras / _env_summary`。
  分区布局每行 `名称 大小 文件系统 挂载点`（`rest` 取剩余）；`IMAGE_SIZE` 只算根分区，ESP 另加。
  根分区行的文件系统须等于 `ROOTFS_TYPE`：UEFI 厂商照填，U-Boot 厂商从根分区读内核、固定 ext4。
- **distro_\***（`lib/distro/<distro>.sh`）：`distro_prepare / _bootstrap_rootfs / _install_pkgs /
  _write_repos / _configure_time / _configure_network / _add_wifi_iface / _configure_console /
  _enable_base_services / _enable_services / _install_oneshot / _adapt_local_d / _install_resize_service /
  _finalize / _default_fragments / _env_summary`；并设 `DISTRO_PRETTY DISTRO_IMAGE_SIZE
  GPU_USERSPACE_PACKAGES WIFI_USERSPACE_PACKAGES`。能用 ZFS 的另实现 `distro_install_zfs 版本`（同版本 OpenZFS
  用户态）；能引导 ZFS 根的再实现 `distro_build_initramfs 内核release 输出路径`（装 zfs-initramfs 并做 initramfs）
  （目前只有 debian；其余发行版配 zfs 在 dry-run 就报错）。可选 `distro_add_package_source 名 密钥 URI 组件`
  （第三方 apt 源，incus 用）。
  `_adapt_local_d`：把板子 `files/` 覆盖进来的 OpenRC `/etc/local.d/*.start` 在 systemd 发行版上转成 oneshot 单元（Alpine no-op）。
- **fs_\***（`lib/fs/<type>.sh`）：`fs_env_summary / _check_config / _check_host / _build_modules / _format /
  _mount / _release / _install / _root_cmdline / _fstab_root`；`fs_install` 可设 `ROOTFS_INITRD`，启动方式把它装到内核旁边。
- **profile_\***（`lib/profile/<profile>.sh`，`PROFILE` 默认 base）：`profile_env_summary / _check_config / _check_host /
  _kernel_contracts / _build_modules / _install`，可设 `PROFILE_IMAGE_TAG PROFILE_IMAGE_SIZE`。`_install` 在 `distro_finalize` 前跑；
  需要的发行版能力用 `declare -F` 查可选函数，缺了在 dry-run 就拒绝。
- **board_\* 钩子**（可选）：`board_inject_sources / _build_modules / _install_modules /
  _install_userspace / _configure_runtime / _install_extras`；pipeline 用 `board_hook <name>` 调，未定义即 no-op。
  源码注入按 `board_inject_uboot_sources / board_inject_kernel_sources / board_prepare_modules` 拆分，
  `board_inject_sources` 为完整镜像入口组合；独立内核验证只调用 kernel/modules 两类钩子。

## 关键约定 / 易踩坑（重要）
- **全局 `IFS=$'\n\t'`（不含空格）**：任何 `for x in $空格分隔列表` 都**不会按空格切分**！必须
  `IFS=' ' read -r -a arr <<< "$list"; for x in "${arr[@]}"`。（之前固件 strip、服务 enable 都栽在这。）
- **内核 = defconfig + 片段 merge_config**：顺序载重（distro 基线在前，essentials/vendor/SoC/board/leds/docker/modern 在后，
  后者覆盖前者重新强制内建）；**不要加 `-r`**；`CONFIG_DRM_PANTHOR=m` 必须是模块。改内核选项 = 改 `kconfig/*.fragment`，不要回到命令式。
- **能力合约 `kconfig/*.contract`**：profile 的合约紧跟 distro 基线作为请求合并（构建目录里生成 `<名>.contract.request`，
  `=m` 若前面已 `=y` 就不写，**绝不降级内建**），`olddefconfig` 后逐条核对最终 `.config`，不符即停；无法解析的行也算违约。
  片段把合约要的东西关掉 = 构建失败（这是门禁在工作，改片段或合约，别绕过）。`dae.contract` 与 vyos-rockchip 的
  `73-dae.config` 保持一致，另加 `NETKIT`（dae v2 首选 netkit，缺了退回 veth 兼容模式，真机日志可见），
  不含模块 BTF（`modern.fragment` 有意关着）。BTF 门禁与 profile 无关：`.config` 要 BTF，vmlinux
  就必须真有 `.BTF` 段（pahole 缺失会被 kbuild 静默丢掉）。
- **内核默认增量编译**（不删 build 目录，`make` 只编改动）；`CLEAN_KERNEL=1` 从头编；`SKIP_BUILD=1` 跳过 uboot+内核。
- **栈 ulimit / `Argument list too long`**：distro 级内核 ~4000+ 模块，modfinal 的 argv 很长；某些会话 `ulimit -s` 软限只有
  ~12MB → execve 上限=栈/4≈3.1MB → 在 `.module-common.o` 炸 `Argument list too long`。`scripts/build.sh` 启动即
  `ulimit -S -s 131072` 抬高（硬限通常 unlimited），别删这行。
- **镜像名在取源后定**：`finalize_image_name`（lib/sources.sh）用 `make kernelversion` 填 `<前缀>-<distro>-<版本>.img`；
  dry-run 显示 `<kernelversion>` 占位。
- **Arch 专项**：① 删 ALARM 自带内核（`IgnorePkg=linux-aarch64` + 首启 `pacman -Rdd`）；
  ② `ARCH_STRIP_ALL_FW=1` 删整个 linux-firmware（每板固件单独加，安全）；
  ③ `ARCH_BUILD_KEYRING=1` 构建期 qemu chroot 预置 keyring——两个坑：(a) 卸载前必须 `gpgconf --kill all` + 杀
  qemu-gpg，否则 gpg-agent 赖在挂载里 `umount busy` 整 build 崩；(b) chroot 的 /dev **必须非递归 `--bind` +
  `--make-private`**，绝不能 `--rbind`/`umount -lR`——递归绑定会把宿主机 devpts 卸掉（挂载传播），导致**整机
  pty 失效、sudo/终端全崩**（救活：`pkexec mount -t devpts devpts /dev/pts -o gid=5,mode=620,ptmxmode=666`）；
  ④ 扩容是独立早期 `firstboot-grow.service`（sfdisk+resize2fs，无网），不依赖装 growpart。
- 厂商差异：Rockchip = rkbin blob + `u-boot-rockchip.bin`@s64 + GPT；Allwinner = 现编 ATF BL31 +
  `u-boot-sunxi-with-spl.bin`@8KiB + MBR；Qualcomm = 板载 UEFI，不写任何引导扇区，GPT = 512M ESP +
  根分区，systemd-boot 读 BLS 启动项（内核、dtb 都在 ESP）。UEFI 固件每次开机都把 ESP 的 FAT 脏标记留着，
  所以 vfat 分区在 fstab 里 fsck 序号为 2，引擎会装 dosfstools（`install_filesystem_tools`）。
- **内核源码树每次构建都 `git clean`**（内核 O= 树外编译，安全）：板子补丁新增的文件不会残留到下一块板；
  U-Boot 树只 `checkout`，因为它树内编译、`SKIP_BUILD=1` 要复用产物。
- **Dragon Q8B**：80 个补丁在 `boards/dragon-q8b/linux/patches`（来源与刷新记录见同目录 README）。镜像只跑 EL2：
  DTB 是 `-el2.dtb`（`radxa,enable-kvm` 让固件进 EL2）；DSP 由 BIOS（≥260916，“Remoteproc firmware preload”
  默认 Auto）在 EL2 下预启动、内核 attach，旧 BIOS 下没有 DSP。不要再往 ESP 装 qebspil：它会和 BIOS 的预启动
  重复启动 DSP（崩溃或 DSP offline）。BIOS 第三方兼容选项与 Hypervisor Settings 须保持默认。风扇由 ADSP 上的
  Radxa 服务驱动（补丁 0076–0078 的 `radxa_svc_glink`，hwmon `pwm1`）；固件全速与高温时的自动曲线都输出 0 占空，
  这只风扇（Heatsink 6845B）会停转，所以 `files/etc/local.d/q8b-fan.start` 开机切手动、先 128 起转再定在 190。
  Iris 在 EL2 下由内核自己加载固件（补丁 0071 + overlay 的 `video-firmware` 子节点）。
  2.5G 网口（TC956x，`1179:0220`）：**不要在宿主上解绑/卸载 `tc956x_pci`，也不要对它 FLR**，两者都会让芯片
  停止响应，随后的配置空间访问变成 SError、整机 panic（补丁 0079 用 quirk 去掉了 FLR 与总线复位）；
  KVM 直通靠开机就把两个功能交给 vfio-pci，做法见 `docs/dragon-q8b.md`。接收 FIFO 只给单个队列（补丁 0080），
  测吞吐用 iperf3，busybox nc 的 1K 读缓冲本身就把单流限在约 300 Mbit/s。
  `DRM_MSM=m`、`EEPROM_AT24=y` 都是有意的：前者内建会在根分区挂载前请求 GPU 固件而报错，后者做成模块会让 PCIe（TC9563
  的 pwrctrl 要从这块 EEPROM 读 MAC）一直延迟重试到 udev 起来。组合 DTB（base + `.dtbo`）没有 `.dts`，
  引擎按 Makefile 的 `-dtbs :=` 规则认它（`kernel_dtb_has_source`）。
- **ZFS 根**（dragon-q8b 默认，`lib/fs/zfs.sh`）：OpenZFS 版本锁在 `config/versions.conf`，须与 Debian contrib 的
  zfsutils-linux 同版本，且 META 的 `Linux-Maximum` 要覆盖内核（升内核时 `kernel-build` 会一并编 ZFS）。池在构建机上
  建，构建机内核要有 zfs 模块（容器里要在宿主上 `modprobe zfs`）；以临时名 `arm-packer-<pid>` 导入，永不与宿主的
  `rpool` 冲突，结束时 trim + 导出。zfs-initramfs 依赖 `zfs-modules | zfs-dkms`，由空包 `arm-packer-zfs-modules`
  声明满足。`/etc/hostid` 随镜像固定（initramfs 与系统必须一致），不要在 finalize 里删。
- **Incus（`PROFILE=incus`，`docs/incus.md`）**：只用 Debian、只用 ZFS 存储，**不提供 dir 退路**（用户明确要求）。ZFS 根 →
  数据集 `rpool/incus`；ext4 根（U-Boot 板）→ `grow-rootfs` 按 `/etc/default/grow-rootfs` 把根停在 8G、余下建分区，
  `incus-init` 用本板新生成的 hostid 建池 `incus`；盘 <16G 明确失败。**数据分区的起点必须显式给在根分区之后**：
  `sfdisk --append` 默认会填进根分区前面的空隙，而 U-Boot 板的引导程序就在那里（`make test-grow` 曾抓到）。
  br0 不默认配（用户要求自己配，文档给做法）。ARC 每次开机设为内存 1/4。`incusbr0` 网段由 machine-id 推出、只避开
  本机已有路由，**不要改回 Incus 的 `auto`**：它靠 ping/TCP 探测选网段，遇到对所有连接都应答的透明代理会全部判占用而失败。
  Debian 的 `contrib`（zfsutils 所在）由 `distro_install_zfs` 按需加入，不再看根文件系统类型。
  排在 `zfs-import.target` 之前的单元（如 ARC 上限）**必须 `DefaultDependencies=no`**：默认依赖让它排在 sysinit 之后，
  而 import → zfs-mount → local-fs → firstboot-grow → sysinit，成环后 systemd 会悄悄删掉首启扩容或 local-fs（QEMU 实测）。
  启动测试要 grep 控制台的 `ordering cycle`。

## 验证手段
- 改完先 `bash -n` 全部脚本 + 各板 `--dry-run`（看 vendor/SoC、分区表、片段列表与顺序、钩子、镜像名、IMAGE_SIZE）。
- 真验证镜像：先 `xz -dk out/X.img.xz`，再 `sudo losetup --read-only -fP --show out/X.img` 只读挂载抽查（firmware、keyring、grow 单元、hostname、modules 大小）。
- `make test-image`：真实 XZ 压缩/解压、禁用压缩及失败保留旧包/原图回归，不写磁盘设备。
- `make test-kernel`：含全部板 × 发行版 × incus 的 dry-run 矩阵与合约语义单测。
- `make test-grow IMAGE=<U-Boot 板 ext4 根镜像>`（root）：首启扩容 + Incus ZFS 分区在 loop 盘上实测（MBR/GPT/小盘），逐字节核对引导区。
- 内核语义无损：`--stop-after-kconfig` 后 diff 新旧 `.config`。

## 加新东西
- **加板**：丢 `boards/<board>/board.conf`（+ 需要时 `hooks.sh`/`kernel.fragment`/资源），引擎零改动。
- **加发行版**：写 `lib/distro/<name>.sh` 实现 `distro_*` 契约（systemd 系直接复用 `lib/distro/common/systemd.sh`），引擎零改动。
- **加用途**：写 `lib/profile/<name>.sh` 实现 `profile_*` 契约（照 `base.sh`），内核依赖写成 `kconfig/<名>.contract`，引擎零改动。

注：仓库目录名是 `rockchip/alpine`（历史），但现已多厂商多发行版；别被名字误导。
