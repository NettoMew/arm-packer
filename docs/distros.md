# 发行版（`DISTRO=` 第三根插件轴）

内核 / 引导 / 镜像分区 / 板级钩子**与发行版无关、完全复用**；只有「用户态 = 包管理器 + init
系统 + 网络栈」由 `lib/distro/<distro>.sh` 插件提供（契约对称 `lib/vendor/*`）。加一个发行版 =
加一个同构插件，引擎不动。

| | `alpine`（默认） | `archlinux` | `debian` | `eweos` |
|---|---|---|---|---|
| libc / 工具 | musl + busybox | glibc + GNU | glibc + GNU | **musl + busybox** |
| 包管理 / init | apk + OpenRC | pacman + systemd | apt + systemd | **pacman + dinit** |
| 网络 | ifupdown `/etc/network/interfaces` | systemd-networkd（ALARM 自带 eth/en DHCP）| ifupdown + dhcpcd（`allow-hotplug`，不阻塞开机） | 全 DHCP 脚本服务（busybox `udhcpc` 扫所有有线网卡） |
| 校时 | chrony（aliyun NTP） | systemd-timesyncd（写 `NTP=`） | systemd-timesyncd（drop-in 写 `NTP=`） | busybox `ntpd` |
| rootfs 来源 | apk.static 离线装 sys-mode | 解上游 ALARM aarch64 tar.gz | mmdebstrap 直接引导进根分区（`important` variant + 显式包表） | 解上游 eweOS aarch64 tarball |
| 首启 | 装 GPU/wifi 在线包 + 扩容 | 早期 sfdisk 扩容（无网）+ 网络后 pacman 装 mesa/wifi | 早期 sfdisk 扩容（无网）+ 生成 SSH 主机密钥；其余构建期已装好 | dinit oneshot 扩容（无网，sfdisk + resize2fs） |

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

## Debian 专项处理

目标是**最小化但完整可用、开机快**：以 Debian 自己定义的基础系统（`important` 优先级，即最小
netinst 装出来的那一层）为底，再显式列出方案依赖的包；不装 Recommends、dbus、内核与 initramfs，
约 156 个包（rock5c 加 Wi-Fi 用户态 163 个）。全部包在构建期装完，首启不需要联网。

- **为什么不更薄**：`apt`/`required` variant 实测不够用——trixie 的 `login` 已不是 Essential，
  串口输完用户名不会问密码；没有 whiptail 时 debconf 在终端上找不到前端，每次 apt 都刷一屏警告。
  `important` 正好补上 login、whiptail、less、nano、vim-tiny、ping、procps、cron、logrotate、nftables。
  需要时可用 `DEBIAN_VARIANT` 换底。
- **引导**：`mmdebstrap --mode=unshare --variant=important` 直接写进刚格式化的根分区（只允许空的
  `lost+found`），自带私有 mount 命名空间，不碰宿主 `/dev/pts`。引导源已含 `-updates` 与
  `-security`，镜像出厂即打好补丁。
- **精简策略就是构建策略**：`resources/debian/dpkg.cfg`（排除 doc/man/info/locale，保留 copyright）
  与 `resources/debian/apt.conf`（不装 Recommends/Suggests、不下翻译）经 `--dpkgopt/--aptopt`
  作用于引导本身，并留在镜像里约束以后每次 `apt install`。`resources/debian/rootfs/` 在第一个包
  解包前铺进目标。
- **网络 = ifupdown + dhcpcd-base**：有线口写成 `allow-hotplug ethN`，由 udev 经 `ifup@.service`
  异步拉起，DHCP 不在 `networking.service` 里等，拔网线开机也不卡。网卡保留内核名（`eth0`/
  `wlan0`，与其它发行版一致），可预测名（`end0` 等）仍作为 altname 存在（覆盖层的
  `99-default.link`）。Wi-Fi 用 wpasupplicant 的 ifupdown 钩子（`wpa-conf`），不跑 dbus 版守护进程。
- **不触发 systemd「首次开机」**：`/etc/machine-id` 保持为空（Debian 惯例）。否则首启会跑交互式
  `systemd-firstboot` 向导（串口无人值守会卡住），并执行 preset-all 把 systemd-networkd 与
  wait-online 一并启用、和 ifupdown 抢网卡。SSH 主机密钥构建期删除，由 `sshd-keygen.service`
  的 drop-in 以「密钥不存在」为条件在板上生成，每块板一套。
- **少写存储**：journald 只放内存（`Storage=volatile`，上限 16M）；屏蔽 `apt-daily*`、
  `dpkg-db-backup`、`e2scrub*` 定时任务，保留 `fstrim.timer`。
- **不会装回发行版内核**：`preferences.d` 把 `linux-image-*`、`linux-headers-*`、initramfs 生成器
  钉为 -1。
- **默认无头**：`GPU_USERSPACE_PACKAGES` 默认空（Debian 的 Mesa 会带上 ~100M 的 libLLVM），需要时
  设为 `libgl1-mesa-dri libegl1 libgles2 libgbm1`；Wi-Fi 用户态只装 `wpasupplicant iw`，蓝牙
  （bluez 依赖 dbus）按需加进 `WIFI_USERSPACE_PACKAGES`。
- **systemd 公共件**：离线 enable/mask、串口 getty、早期扩容、local.d 适配放在
  `lib/distro/common/systemd.sh`，与 Arch 插件共用。
