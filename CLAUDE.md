# CLAUDE.md — 项目向导（给 Claude Code 看的）

主线 SBC 固件构建器：从主线源码为多块 Rockchip / Allwinner / Qualcomm 开发板构建可直接烧录的整盘镜像。
**三根正交插件轴：board × vendor × distro**，外加 kconfig 片段轴。引擎 `lib/*.sh` 里**没有任何
board/vendor/distro 的 `if` 分支**——差异全在插件/配置里。加一块板/一个发行版 = 加一个文件，不改引擎。

## 入口 & 跑法
- `make <board>`（`e20c`/`m28k`/`m28k-noscreen`/`rock5c`/`rock5c-stock`/`opiz3`/`dragon-q8b`/`all`）→ 调 `scripts/build.sh`。
- 等价 `BOARD=rock5c DISTRO=archlinux scripts/build.sh`。
- `make <board>-dry` / `scripts/build.sh --dry-run`：只解析配置、打印片段/钩子/镜像名，**不构建、不联网、不 sudo**（秒级，验证改动的首选）。
- `scripts/build.sh --stop-after-kconfig`：编到内核 `.config` 就停（用于对比 `.config`）。
- 默认源码版本集中在 `config/versions.conf`；`make kernel-check/kernel-build BOARD=... KERNEL_REF=vX.Y.Z`
  使用全新独立验证工作区，不取 U-Boot/固件、不做 rootfs。`kernel-promote` 需成功 build 报告与人工真机确认，见 `docs/kernel-updates.md`。
- 以普通用户跑；需要 root 的步骤自动 `sudo`。成品在 `out/`，镜像名 `<前缀>-<distro>-<内核版本>.img.xz`。

## 目录 / 职责
```
scripts/build.sh    唯一入口(orchestrator)：解析 flags → 载 board.conf → 载 vendor+distro+hooks → 派生 → run_pipeline
lib/log,env,deps,workspace,sources,kernel,image,rootfs,pipeline,aic8800.sh   引擎模块(distro/vendor 无关)
lib/vendor/{rockchip,allwinner,qcom}.sh   厂商插件(启动链)：vendor_* 契约
lib/boot/{uboot,uefi}.sh             启动方式，由厂商插件 source：U-Boot + extlinux / 板载 UEFI + systemd-boot(ESP, BLS)
lib/distro/{alpine,archlinux,debian,eweos}.sh   发行版插件(用户态)：distro_* 契约
lib/distro/common/systemd.sh         systemd 系插件(archlinux/debian)共用的离线原语，由插件自行 source
boards/<board>/board.conf            每板声明式配置(必填键见下)
boards/{m28k,rock5c}/hooks.sh        板级钩子(可选)：board_* 函数；就近放 DTS/补丁/固件移植/OLED
kconfig/*.fragment + distro-arm64.config   可组合内核片段(见 kconfig/README.md)
resources/rootfs/                    固定 rootfs 文件(resize 脚本、wpa 模板、interfaces 基底)
resources/systemd/  resources/debian/   systemd 早期扩容单元 / Debian 的 dpkg+apt 策略与 rootfs 覆盖层
work/  out/                          源码树工作区 / 成品
```

## 三个契约（改引擎时照着调用，别加 if 分支）
- **board.conf**（纯赋值）必填：`BOARD_VENDOR BOARD_SOC BOARD_KERNEL_DTB BOARD_IMAGE_PREFIX
  BOARD_HOSTNAME BOARD_MENU_TITLE BOARD_SERIAL_CONSOLE` + 厂商要求的键（`vendor_required_keys`，
  U-Boot 厂商要 `BOARD_UBOOT_DEFCONFIG`）；选填 `BOARD_SERIAL_BAUD BOARD_KERNEL_CMDLINE_EXTRA
  BOARD_SECOND_NIC BOARD_NICS BOARD_KERNEL_FRAGMENTS`。可选 `firmware.lock`（按 commit + SHA-256 锁固件）。
- **vendor_\***（`lib/vendor/<vendor>.sh`）：`vendor_required_keys / _select_blobs / _default_fragments /
  _fetch_extra / _fetch_assert_skip / _assert_sources / _build_bootloader / _partition_table /
  _partition_layout / _write_bootloader / _install_boot / _firmware_extras / _env_summary`。
  分区布局每行 `名称 大小 文件系统 挂载点`（`rest` 取剩余）；`IMAGE_SIZE` 只算根分区，ESP 另加。
- **distro_\***（`lib/distro/<distro>.sh`）：`distro_prepare / _bootstrap_rootfs / _install_pkgs /
  _write_repos / _configure_time / _configure_network / _add_wifi_iface / _configure_console /
  _enable_base_services / _enable_services / _install_oneshot / _adapt_local_d / _install_resize_service /
  _finalize / _default_fragments / _env_summary`；并设 `DISTRO_PRETTY DISTRO_IMAGE_SIZE
  GPU_USERSPACE_PACKAGES WIFI_USERSPACE_PACKAGES`。
  `_adapt_local_d`：把板子 `files/` 覆盖进来的 OpenRC `/etc/local.d/*.start` 在 systemd 发行版上转成 oneshot 单元（Alpine no-op）。
- **board_\* 钩子**（可选）：`board_inject_sources / _build_modules / _install_modules /
  _install_userspace / _configure_runtime / _install_extras`；pipeline 用 `board_hook <name>` 调，未定义即 no-op。
  源码注入按 `board_inject_uboot_sources / board_inject_kernel_sources / board_prepare_modules` 拆分，
  `board_inject_sources` 为完整镜像入口组合；独立内核验证只调用 kernel/modules 两类钩子。

## 关键约定 / 易踩坑（重要）
- **全局 `IFS=$'\n\t'`（不含空格）**：任何 `for x in $空格分隔列表` 都**不会按空格切分**！必须
  `IFS=' ' read -r -a arr <<< "$list"; for x in "${arr[@]}"`。（之前固件 strip、服务 enable 都栽在这。）
- **内核 = defconfig + 片段 merge_config**：顺序载重（distro 基线在前，essentials/vendor/SoC/board/leds/docker/modern 在后，
  后者覆盖前者重新强制内建）；**不要加 `-r`**；`CONFIG_DRM_PANTHOR=m` 必须是模块。改内核选项 = 改 `kconfig/*.fragment`，不要回到命令式。
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
  根分区，systemd-boot 读 BLS 启动项（内核、dtb 都在 ESP）。
- **内核源码树每次构建都 `git clean`**（内核 O= 树外编译，安全）：板子补丁新增的文件不会残留到下一块板；
  U-Boot 树只 `checkout`，因为它树内编译、`SKIP_BUILD=1` 要复用产物。
- **Dragon Q8B**：60 个补丁在 `boards/dragon-q8b/linux/patches`（来源与刷新记录见同目录 README）；
  `DRM_MSM=y` 依赖 `QCOM_OCMEM` 不能是 m（片段里已处理）；BIOS 第三方兼容选项须保持默认。

## 验证手段
- 改完先 `bash -n` 全部脚本 + 各板 `--dry-run`（看 vendor/SoC、分区表、片段列表与顺序、钩子、镜像名、IMAGE_SIZE）。
- 真验证镜像：先 `xz -dk out/X.img.xz`，再 `sudo losetup --read-only -fP --show out/X.img` 只读挂载抽查（firmware、keyring、grow 单元、hostname、modules 大小）。
- `make test-image`：真实 XZ 压缩/解压、禁用压缩及失败保留旧包/原图回归，不写磁盘设备。
- 内核语义无损：`--stop-after-kconfig` 后 diff 新旧 `.config`。

## 加新东西
- **加板**：丢 `boards/<board>/board.conf`（+ 需要时 `hooks.sh`/`kernel.fragment`/资源），引擎零改动。
- **加发行版**：写 `lib/distro/<name>.sh` 实现 `distro_*` 契约（systemd 系直接复用 `lib/distro/common/systemd.sh`），引擎零改动。

注：仓库目录名是 `rockchip/alpine`（历史），但现已多厂商多发行版；别被名字误导。
