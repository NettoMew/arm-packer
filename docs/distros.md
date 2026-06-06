# 发行版（`DISTRO=` 第三根插件轴）

内核 / 引导 / 镜像分区 / 板级钩子**与发行版无关、完全复用**；只有「用户态 = 包管理器 + init
系统 + 网络栈」由 `lib/distro/<distro>.sh` 插件提供（契约对称 `lib/vendor/*`）。加一个发行版 =
加一个同构插件，引擎不动。

| | `alpine`（默认） | `archlinux` | `eweos` |
|---|---|---|---|
| libc / 工具 | musl + busybox | glibc + GNU | **musl + busybox** |
| 包管理 / init | apk + OpenRC | pacman + systemd | **pacman + dinit** |
| 网络 | ifupdown `/etc/network/interfaces` | systemd-networkd（ALARM 自带 eth/en DHCP）| 全 DHCP 脚本服务（busybox `udhcpc` 扫所有有线网卡） |
| 校时 | chrony（aliyun NTP） | systemd-timesyncd（写 `NTP=`） | busybox `ntpd` |
| rootfs 来源 | apk.static 离线装 sys-mode | 解上游 ALARM aarch64 tar.gz | 解上游 eweOS aarch64 tarball |
| 首启 | 装 GPU/wifi 在线包 + 扩容 | 早期 sfdisk 扩容（无网）+ 网络后 pacman 装 mesa/wifi | dinit oneshot 扩容（无网，sfdisk + resize2fs） |

## Arch 专项处理

都用我们自己的主线内核，不是 ALARM 那个。

- **删 ALARM 自带内核**：删 `/boot` 内核 + `*-ARCH` 模块，`IgnorePkg = linux-aarch64` 屏蔽，
  首启 `pacman -Rdd` 清库（否则 `pacman -Syu` 会把内核+initramfs 装回来覆盖我们的 `/boot`）。
- **精简固件**（`ARCH_STRIP_ALL_FW=1`）：我们每板自带固件（Mali CSF + AIC8800），删整个
  `linux-firmware`（5.2M 只剩 aic8800+mali）；插外置 USB 网卡再 `pacman -S linux-firmware`。
- **keyring 出厂预置**（`ARCH_BUILD_KEYRING=1`）：构建期 qemu chroot 跑 `pacman-key
  --init/--populate`，首登即可 pacman，无首启竞态（首启保留幂等兜底）。
- **早期扩容**：独立 `firstboot-grow.service`（`sysinit.target`，无网络），用 base 自带的
  `sfdisk + resize2fs`，开机几秒扩满盘——不依赖联网装 growpart。

## eweOS 专项处理

eweOS = musl libc + busybox coreutils + pacman + dinit init，rolling，aarch64 Tier-1。
从上游 tarball 引导，再在 **qemu-aarch64 chroot 里跑 pacman** 装包（构建期完成，镜像即开箱可用）。

- **无 keyring 折腾**：pacman `SigLevel = Never`，不像 Arch 要构建期预置 keyring。
- **dinit 启停模型**：`enable` 一个服务 = 把它的定义 symlink 进 `/etc/dinit.d/boot.d/`（`boot`
  bundle 等待的目录，相当于离线版 `dinitctl enable`）。dinit 先搜 `/etc/dinit.d` 再搜
  `/usr/lib/dinit.d`，所以 `/etc/dinit.d/<name>` 可覆盖厂商默认（校时即用此法 shadow 掉自带 ntpd）。
- **跳过开机 root fsck**：fstab 根分区 `passno → 0`。eweOS 的 early-root-fsck 在根已 `rw` 挂载后
  跑 `fsck -a`，e2fsck 会拒绝（"is mounted … Cannot continue"）刷屏——置 0 跳过。
- **镜像大小**：默认 `2G`（`FULL_FIRMWARE=1` 时 `4G`）。
- **仓库**：`os-repo-auto.ewe.moe` + wsyu/sdust 镜像，repo 名 `main`。
