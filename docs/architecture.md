# 架构

声明式、可插拔架构：**三根正交插件轴 board × vendor × distro**，外加根文件系统轴与 kconfig 片段轴。引擎
`lib/*.sh` 里**没有任何 board/vendor/distro 的 `if` 分支**——差异全在插件/配置里。加一块板 /
一个发行版 = 加一个文件，不改引擎。

## 契约

- **board.conf**（纯赋值）必填：`BOARD_VENDOR BOARD_SOC BOARD_KERNEL_DTB BOARD_IMAGE_PREFIX
  BOARD_HOSTNAME BOARD_MENU_TITLE BOARD_SERIAL_CONSOLE`，再加厂商启动方式要求的键
  （`vendor_required_keys`，U-Boot 厂商要 `BOARD_UBOOT_DEFCONFIG`，UEFI 厂商不要）；选填
  `BOARD_SERIAL_BAUD BOARD_KERNEL_CMDLINE_EXTRA BOARD_SECOND_NIC BOARD_NICS BOARD_KERNEL_FRAGMENTS
  BOARD_ROOTFS_TYPE`（根文件系统，默认 ext4）。
  板目录里可放 `firmware.lock`：按 commit 与 SHA-256 锁定的固件清单，引擎逐个下载校验后装进 `/lib/firmware`；
  `link` 行对应 linux-firmware WHENCE 的 `Link:`，`source` URL 里的 `{path}` 用于只能靠查询参数锁版本的地址。
- **vendor_\***（`lib/vendor/<vendor>.sh`，启动链）：`vendor_required_keys / _select_blobs /
  _default_fragments / _fetch_extra / _fetch_assert_skip / _assert_sources / _build_bootloader /
  _partition_table / _partition_layout / _write_bootloader / _install_boot / _firmware_extras /
  _env_summary`。启动方式由厂商 source 的 `lib/boot/*.sh` 提供：
  - `lib/boot/uboot.sh`：U-Boot 取源/构建，内核与 dtb 放 `/boot`，写 `extlinux.conf`（rockchip、allwinner）。
  - `lib/boot/uefi.sh`：板载 UEFI，systemd-boot（Debian 包锁版本与 SHA-256）装进 ESP，
    内核、dtb 与根文件系统需要的 initramfs 放 ESP，写一条 BLS 启动项，`loader.conf` 精确指定它为默认（qcom）。
  - `vendor_partition_layout` 每行一个分区 `名称 大小 文件系统 挂载点`，`rest` 取剩余；
    `IMAGE_SIZE` 只算根分区，ESP 等另加。根分区那行的文件系统就是 `ROOTFS_TYPE`：UEFI 厂商照填，
    U-Boot 厂商从根分区读内核，固定写 ext4，与 `ROOTFS_TYPE` 不符即报错。vfat 分区在 fstab 里
    fsck 序号为 2（固件留下的 FAT 脏标记
    由 fsck 清掉），引擎为此装 dosfstools。
  - `BOARD_KERNEL_DTB` 可以是组合 DTB（基础 `.dtb` + `.dtbo`，由 dts 目录 Makefile 的 `-dtbs :=` 规则生成）。
- **distro_\***（`lib/distro/<distro>.sh`，用户态）：`distro_prepare / _bootstrap_rootfs /
  _install_pkgs / _write_repos / _configure_time / _configure_network / _add_wifi_iface /
  _configure_console / _enable_base_services / _enable_services / _install_oneshot /
  _adapt_local_d / _install_resize_service / _finalize / _default_fragments / _env_summary`；
  能引导 ZFS 根的发行版另有 `distro_install_zfs 版本`（装同版本 OpenZFS 用户态）与
  `distro_build_initramfs 内核release 输出路径`（目前只有 debian）。
- **fs_\***（`lib/fs/<type>.sh`，根文件系统，由 `ROOTFS_TYPE` 选）：`fs_env_summary / _check_config /
  _check_host / _build_modules / _format / _mount / _release / _install / _root_cmdline / _fstab_root`。
  ext4 由内核直接挂载，全是空操作或一行；zfs 从锁版本的 OpenZFS 发布包随内核编模块，在构建机上以临时名
  建池（`rpool`，特性集限定 `openzfs-2.2-linux`）并挂 `rpool/ROOT/<distro>`，由发行版装同版本用户态、
  做 initramfs，UEFI 启动项带上 `initrd`，命令行 `root=ZFS=rpool/ROOT/<distro>`，fstab 不写根；
  收尾先 `zpool trim` 把空闲块还给稀疏镜像，再导出。首启扩容脚本认得两种根：ext4 `resize2fs`，
  ZFS `zpool online -e`。
- **board_\* 钩子**（可选）：`board_inject_sources / _build_modules / _install_modules /
  _install_userspace / _configure_runtime / _install_extras`；pipeline 用 `board_hook <name>` 调，
  未定义即 no-op。
  源码注入拆为 `board_inject_uboot_sources / board_inject_kernel_sources / board_prepare_modules`：
  `board_inject_sources` 保留为完整镜像构建的组合入口；独立内核验证只调用后两者，不碰 U-Boot。
  新增有源码补丁的板子必须按此拆分，不能仅实现混合的旧入口。

## 目录结构

```
Makefile                      # 入口：make <板子> / make <板>-dry（调用 scripts/build.sh）
config/versions.conf          # 共享源码默认版本；环境/板级覆盖优先
scripts/build.sh              # 构建入口：载 config → 载 vendor+hooks → 跑 pipeline
scripts/kernel-update.sh      # 显式候选 check/build + 真机确认后的 promote
lib/                          # 引擎模块（无 board/vendor/distro 分支）
  log/env/deps/workspace/     #   日志、旋钮+派生路径、依赖、工作区
  sources/kernel/             #   取源(+定镜像名)、内核(片段合并)
  image/rootfs/pipeline.sh    #   镜像分区/写引导、共享 rootfs 落地、run_pipeline + 钩子分派
  fs/ext4.sh                  #   根文件系统 ext4（默认）：内核直接挂载，无 initramfs
  fs/zfs.sh                   #   根文件系统 ZFS：随内核编 OpenZFS 模块、构建机建池、initramfs 导入
  wifi.sh                     #   Wi-Fi/BT 用户态（wpa_supplicant 模板 + wlan0 + 服务），各带无线的板共用
  aic8800.sh                  #   AIC8800 Wi-Fi/BT 驱动能力（m28k SDIO / rock5c USB 共用）
  kernel-update.sh            #   独立工作区、检查/编译报告、默认版本更新检查
  vendor/rockchip.sh          #   rkbin blob / u-boot-rockchip.bin@s64 / GPT / Panthor 固件
  vendor/allwinner.sh         #   现编 ATF BL31 / u-boot-sunxi-with-spl.bin@8KiB / MBR
  vendor/qcom.sh              #   板载 UEFI：不编引导程序，GPT = ESP + 根分区，systemd-boot
  boot/uboot.sh               #   U-Boot 启动方式：取源/构建、/boot 内核 + extlinux.conf
  boot/uefi.sh                #   UEFI 启动方式：锁版本的 systemd-boot、ESP 内核 + BLS 启动项
  distro/alpine.sh            #   apk + OpenRC + ifupdown
  distro/archlinux.sh         #   ALARM + pacman + systemd（删自带内核/固件、预置 keyring、早期扩容）
  distro/debian.sh            #   mmdebstrap 最小 trixie + apt + systemd + ifupdown（构建期装全，首启免网）
  distro/common/systemd.sh    #   systemd 系插件共用的离线原语（enable/mask、串口 getty、早期扩容、local.d 适配）
  distro/eweos.sh             #   eweOS tarball + pacman + dinit（musl/busybox，qemu chroot 装包、跳 root fsck）
boards/<board>/board.conf     # 每块板的声明式配置（vendor/soc/defconfig/dtb/镜像前缀/串口…）
boards/m28k/                  #   有屏 M28K：hooks.sh + kernel.fragment + 注入源
    hooks.sh                  #     源码注入 + AIC8800(SDIO) + OLED 仪表盘
    kernel.fragment           #     板级内核片段（SSD130X + wifi/bt core）
    {uboot,linux,aic8800,oled,files}/   # DTS/补丁/固件移植/OLED 源/开机脚本
boards/rock5c/                #   hooks.sh（RK3582 开核 + AIC8800 USB）+ uboot/aic8800 补丁
boards/dragon-q8b/            #   board.conf + hooks.sh + kernel.fragment + firmware.lock + linux/patches（78 个）+ files/（风扇定速）
# e20c / opiz3 纯主线，只有 board.conf，无 hooks/注入源
kconfig/                      # 可组合内核片段 + distro-arm64.config 基线（见 kconfig/README.md）
resources/rootfs/             # 固定 rootfs 文件（resize 脚本、wpa 模板、interfaces 基底）
work/                         # 源码树工作区（U-Boot/Linux + rkbin/aic8800 或 arm-trusted-firmware）
work/kernel-validation/       # 候选内核的独立工作区/产物/报告（不动日常构建树）
out/                          # 成品镜像（*.img.xz）
```

## 内核 = defconfig + 片段 merge_config

见 [kconfig/README.md](../kconfig/README.md)。片段按顺序合并（distro 基线在前，
essentials/vendor/SoC/board/leds/docker/modern 在后，后者覆盖前者重新强制内建）。改内核选项 =
改 `kconfig/*.fragment`，不要回到命令式。
