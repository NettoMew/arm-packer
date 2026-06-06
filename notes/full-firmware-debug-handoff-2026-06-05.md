# E20C / M28K / RGB30 Alpine 固件构建与调试全量 Note

日期：2026-06-05  
当前工作目录：`/home/adam/Documents/package/e20c/alpine`  
相关 RGB30 项目：`/home/adam/Documents/package/rgb30/alpine`  
目标：完整记录目前所有构建方案、踩坑、修复、硬件测试现象、已验证结论和后续方向，便于继续交接。

---

## 0. 当前总体状态一句话

- **E20C / RK3528**：主线 U-Boot + 主线 Linux + Alpine sys-mode rootfs 的打包脚本已形成，核心打包问题基本解决；生成过 `out/radxa-e20c-alpine-mainline.img`。
- **M28K / RK3528**：同一脚本加入了 `BOARD=m28k` 分支、板级 DTS/defconfig 注入和 RK3528 USB backport，生成过 `out/widora-mangopi-m28k-alpine-mainline.img`。
- **RGB30 / RK3566**：主线 U-Boot 能进 kernel；kernel/rootfs/userspace 能启动；但 **mainline Linux 7.1 路线下只要启用 DSI0 内屏链路就会闪一下后黑屏/状态灯灭，且在 initramfs 写盘日志前挂住**。当前 TF 卡已恢复为 **DSI off + HDMI on** 的安全调试状态。

---

## 1. 用户偏好与约束

1. 希望尽量使用 **当前主线最新版本**：U-Boot `master`，Linux `master`。
2. Git 获取源码偏好：
   ```bash
   git clone --depth 1 --branch master ...
   ```
   但 U-Boot/rkbin 如果需要切分支或复用已有仓库，也可 update/fetch。
3. 必须下载的文件统一优先用 `aria2c`。
4. 不想继续用 Alpine `minirootfs` 做 SBC 固件 rootfs；更可靠方案是 `apk.static` 从 Alpine official uboot tarball 的 `apks/` 离线仓库构建 sys-mode rootfs。
5. 希望能直接编辑 TF 卡内容来迭代，而不是每次完整重打包。
6. 能接受先做安全可启动/可写日志状态，再逐步打开显示/网络/服务。
7. 当前交互偏好：自主推进，不要反复问“是否继续”。

---

## 2. 当前依赖清单

### 2.1 Debian/Ubuntu 系主机推荐依赖

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential pkg-config gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
  git bc bison flex swig device-tree-compiler python-is-python3 python3 \
  python3-setuptools python3-dev python3-pyelftools python3-yaml \
  libssl-dev uuid-dev libgnutls28-dev libncurses-dev kmod dwarves \
  qemu-user-static binfmt-support \
  kpartx dosfstools e2fsprogs parted util-linux udev aria2 \
  xz-utils gzip tar rsync cpio perl
```

脚本内检查的关键命令包括：

```text
git make gcc pkg-config aarch64-linux-gnu-gcc aarch64-linux-gnu-objcopy
bc bison flex swig dtc python3 openssl depmod parted sfdisk losetup lsblk
partprobe udevadm mkfs.ext4 tar xz gzip aria2c blkid rsync cpio perl awk sed
grep findmnt mount umount dd kpartx mkfs.vfat qemu-aarch64-static
```

### 2.2 Alpine rootfs 内推荐基础包

离线 rootfs 包列表使用 Bash 数组逐项传入 apk，不可整串传入：

```text
alpine-base
ifupdown-ng
dhcpcd
dhcpcd-openrc
e2fsprogs
openssh
openssh-server-common-openrc
chrony
chrony-openrc
```

后续联网后可补：

```bash
apk add ca-certificates usbutils pciutils wireless-tools wpa_supplicant linux-firmware-brcm linux-firmware-cypress
update-ca-certificates
```

---

## 3. E20C / RK3528 方案状态

### 3.1 项目路径与主脚本

```text
/home/adam/Documents/package/e20c/alpine/build_e20c_firmware.sh
/home/adam/Documents/package/e20c/alpine/e20c-mainline-work
/home/adam/Documents/package/e20c/alpine/out/radxa-e20c-alpine-mainline.img
```

脚本特点：

- `set -Eeuo pipefail` + `trap cleanup EXIT` + `trap ERR`。
- 顶部变量可配置：工作区、输出路径、BOARD、U-Boot/Linux/rkbin repo/ref、Alpine URL、镜像大小、串口、分区起始扇区、并行 JOBS。
- 默认 `JOBS=$(nproc)`，内核和 U-Boot 编译都使用 `-j${JOBS}`。
- 用 `aria2c` 下载 Alpine uboot tarball 和 `apk-tools-static`。
- 使用 `apk.static` 构建完整 Alpine rootfs，而不是 minirootfs。

### 3.2 默认 E20C 变量

```bash
BOARD=e20c
UBOOT_REPO=https://source.denx.de/u-boot/u-boot.git
UBOOT_REF=master
UBOOT_DEFCONFIG=radxa-e20c-rk3528_defconfig
KERNEL_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
KERNEL_REF=master
KERNEL_DTB=rockchip/rk3528-radxa-e20c.dtb
RKBIN_REPO=https://github.com/rockchip-linux/rkbin.git
RKBIN_REF=master
RK3528_BL31=bin/rk35/rk3528_bl31_v1.20.elf
RK3528_TPL=bin/rk35/rk3528_ddr_1056MHz_v1.11.bin
SERIAL_CONSOLE=ttyS0
SERIAL_BAUD=1500000
ROOTFS_PART_START_SECTOR=32768
BOOTLOADER_SEEK_SECTOR=64
IMAGE_SIZE=1G
```

### 3.3 E20C 当前已处理问题

#### 3.3.1 Mainline DTB 文件名问题

曾报错：

```text
[ERROR] Kernel DTB source missing: arch/arm64/boot/dts/rockchip/rk3528-radxa-e20c.dtb
```

说明当时 kernel tree 中不存在对应 DTS/DTB，后续脚本需在 fetch 后显式检查 DTS 是否存在；若不存在，要么切到有该 DTS 的 commit/tag，要么注入板级 DTS。

#### 3.3.2 PARTUUID 读取问题

曾报错：

```text
[ERROR] Could not read PARTUUID from /dev/loop0p1
```

修复原则：

- `losetup --find --show -P image.img`
- 分区后 `partprobe` + `udevadm settle`
- 等待 `${LOOPDEV}p1` 出现
- `blkid -s PARTUUID -o value` 失败时 fallback 到 `lsblk -no PARTUUID` 和 `sfdisk --part-uuid`
- 失败时打印 `blkid` / `lsblk` / `sfdisk -d` 诊断

#### 3.3.3 Alpine minirootfs 不适合当前固件

曾输出：

```text
[WARN] OpenRC service missing in minirootfs: networking
[WARN] OpenRC service missing in minirootfs: local
```

结论：minirootfs 更像最小 chroot/rootfs，不等价于完整可启动 SBC 系统。当前脚本已改为：

1. 下载 Alpine `alpine-uboot-*-aarch64.tar.gz`
2. 使用其中 `apks/` 作为离线 aarch64 repo
3. 下载 host x86_64 `apk-tools-static`
4. `apk.static --root ... --arch aarch64 add alpine-base ...`

#### 3.3.4 apk 包列表传参错误

曾报错：

```text
ERROR: 'alpine-base ifupdown-ng dhcpcd ...' is not a valid world dependency
```

原因：把空格分隔包列表作为单个 argv 传给 apk。

正确：

```bash
IFS=' ' read -r -a rootfs_packages <<< "${ALPINE_ROOTFS_PACKAGES}"
apk.static ... add "${rootfs_packages[@]}"
```

#### 3.3.5 Alpine TLS 证书问题

板端曾报：

```text
TLS: server certificate not trusted
```

原因组合：

- rootfs 未安装/未更新 `ca-certificates`
- 系统时间不准会导致 TLS 校验失败

修复方向：

```bash
apk add ca-certificates
update-ca-certificates
chronyc sources -v
```

如时间非常错，先临时：

```bash
date -u -s '2026-06-05 00:00:00'
rc-service chronyd restart
```

#### 3.3.6 chronyd 已运行时不能再次 `chronyd -q`

曾报：

```text
Fatal error : Another chronyd may already be running
```

正确处理：

```bash
chronyc tracking
chronyc sources -v
# 或者需要一次性校时时：
rc-service chronyd stop
chronyd -q 'server pool.ntp.org iburst'
rc-service chronyd start
```

### 3.4 E20C 串口命令

用户提供串口设备：`/dev/ttyUSB0`，波特率 `1500000`。

推荐：

```bash
sudo picocom -b 1500000 /dev/ttyUSB0
# 退出：Ctrl-A Ctrl-X
```

或：

```bash
sudo screen /dev/ttyUSB0 1500000
# 退出：Ctrl-A K Y
```

### 3.5 E20C 扩容硬盘/rootfs

如果镜像写入 TF/eMMC 后分区仍是 1G：

```bash
# 板端执行，确认根盘
findmnt /
lsblk

# 假设根盘是 /dev/mmcblk0p1，整盘 /dev/mmcblk0
apk add e2fsprogs parted
parted /dev/mmcblk0 ---pretend-input-tty resizepart 1 100%
resize2fs /dev/mmcblk0p1
df -h /
```

若根盘是 `/dev/mmcblk1p1`，整盘对应 `/dev/mmcblk1`。

---

## 4. M28K / RK3528 分支状态

### 4.1 项目状态

E20C 脚本已加入：

```bash
BOARD=m28k
```

生成过：

```text
/home/adam/Documents/package/e20c/alpine/out/widora-mangopi-m28k-alpine-mainline.img
```

相关日志：

```text
logs/m28k-build.log
logs/m28k-build2.log
logs/m28k-build3.log
logs/m28k-build4.log
```

板级资源：

```text
boards/m28k/README.md
boards/m28k/uboot/dts/...
boards/m28k/uboot/dtsi/...
boards/m28k/uboot/configs/mangopi-m28k-rk3528_defconfig
boards/m28k/linux/dts/...
boards/m28k/linux/patches/*.patch
```

### 4.2 M28K 方案要点

- 与 E20C 同属 RK3528，共用 rkbin BL31/TPL、镜像布局、Alpine rootfs 流程。
- 不在 mainline 的板级 DTS/defconfig 通过 `inject_board_sources()` 注入。
- Linux tree 会在注入前 `git checkout -- .`，再应用 RK3528 USB backport patches。
- 构建时检查 kernel Makefile 是否注册 `rk3528-mangopi-m28k.dtb`，没有则追加。

---

## 5. RGB30 / RK3566 方案状态

### 5.1 项目路径与主脚本

```text
/home/adam/Documents/package/rgb30/alpine
/home/adam/Documents/package/rgb30/alpine/build_rgb30_firmware.sh
/home/adam/Documents/package/rgb30/alpine/out/powkiddy-rgb30-alpine.img
/home/adam/Documents/package/rgb30/alpine/rgb30-mainline-work
```

已有详细 handoff：

```text
/home/adam/Documents/package/rgb30/alpine/notes/rgb30-mainline-debug-handoff-2026-06-05.md
```

### 5.2 RGB30 默认构建变量

```bash
UBOOT_REPO=https://github.com/u-boot/u-boot.git
UBOOT_REF=master
UBOOT_DEFCONFIG=anbernic-rgxx3-rk3566_defconfig
KERNEL_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
KERNEL_REF=master
KERNEL_DTB=rockchip/rk3566-powkiddy-rgb30.dtb
RKBIN_REPO=https://github.com/RetroGFX/rkbin.git
RKBIN_REF=5257e54cc6c15fef28c3b73bd95ca1b55cc8c8cd
RK3566_BL31=bin/rk35/rk3568_bl31_v1.43.elf
RK3566_TPL=bin/rk35/rk3566_ddr_1056MHz_v1.18.bin
SERIAL_CONSOLE=ttyS2
SERIAL_BAUD=1500000
BOOT_LAYOUT=single
IMAGE_SIZE=1G
```

### 5.3 U-Boot 路线结论

#### 5.3.1 BSP U-Boot 编译坑

早期用 RK3566 BSP U-Boot / `rk3568_defconfig` 遇到：

```text
ln: failed to create symbolic link 'arch/arm64/include/asm/arch': No such file or directory
```

后续换构建方式后又遇到 GCC 15 报错：

```text
include/linux/compiler-gcc.h:200:9: error: 'unreachable' redefined [-Werror]
/usr/lib/gcc/aarch64-linux-gnu/15.2.0/include/stddef.h:468:9: note: previous definition
cc1: all warnings being treated as errors
```

处理方向：可以 patch 掉 `unreachable` 重定义或降低 Werror，但最终转向 mainline U-Boot。

#### 5.3.2 mainline U-Boot 可行方向

查 UOS/UnofficialOS 和 mainline 后，RGB30 没有单独 defconfig，主线使用类似 Anbernic RGXX3/RK3566 multi-device 路线：

```text
anbernic-rgxx3-rk3566_defconfig
```

mainline U-Boot 里含 Powkiddy RGB30 检测/fdtfile 处理。当前证据表明：

- U-Boot 能启动 kernel。
- kernel 能挂 rootfs。
- Alpine userspace 能运行。

因此 **U-Boot 不是当前主要黑屏/断电问题**。

### 5.4 RGB30 镜像布局

当前恢复为单分区布局：

```text
前 32768 扇区保留给 Rockchip bootloader
p1 ext4 rootfs 从 sector 32768 开始
/boot 位于 rootfs 内
```

曾试 dArkOS 风格多分区：

```text
p1 uboot
p2 resource
p3 FAT boot
p4 ext4 rootfs
```

但用户反馈“直接不亮了”，所以当前回到单分区。

bootloader 写入逻辑：

- 若有 `u-boot-rockchip.bin`：写到 sector 64
- 否则 split：`idbloader.img` 到 sector 64，`u-boot.itb` 到 sector 16384

### 5.5 RGB30 当前 TF 卡状态

来自交接记录：

```text
当前 TF 卡：host /dev/sdd1，board /dev/mmcblk1p1
```

当前安全配置：

```text
rgb30_probe=darkos_safe_hdmi_dsi_off
initcall_blacklist=panfrost_driver_init
modprobe.blacklist=panfrost
video=HDMI-A-1:1280x720@60
```

当前所有 RGB30 DTB 副本：

```text
/dsi@fe060000 = disabled
/dsi@fe060000/panel@0 = disabled
/hdmi@fe0a0000 = okay
/hdmi-sound = disabled
/vop@fe040000 = okay
```

重要 boot 文件多份兼容拷贝：

```text
/Image
/uInitrd
/rk3566-rgb30.dtb
/rk3566-powkiddy-rgb30.dtb
/dtbs/rockchip/rk3566-powkiddy-rgb30.dtb
/boot/Image
/boot/rk3566-rgb30.dtb
/boot/rk3566-powkiddy-rgb30.dtb
/boot/dtbs/rockchip/rk3566-powkiddy-rgb30.dtb
/boot/extlinux/extlinux.conf
/extlinux/extlinux.conf
```

日志路径：

```text
/boot/firstboot-debug/
/boot/firstboot-debug/initramfs-early.log
/boot/firstboot-debug/pid1-early.log
/boot/firstboot-debug/latest.log
/boot/firstboot-debug/boot-*.log
/var/log/messages
```

### 5.6 RGB30 已验证启动链

已从 TF 卡日志确认过：

```text
/dev/mmcblk1p1 /newroot ext4 rw
EXT4-fs (mmcblk1p1): mounted filesystem ... r/w
Run /init as init process
/proc/device-tree/model: Powkiddy RGB30
/proc/device-tree/compatible: powkiddy,rgb30 rockchip,rk3566
PID 1 /sbin/init
sshd: /usr/sbin/sshd [listener]
chronyd running
dhcpcd running but no valid interfaces
```

结论：

- U-Boot 可用。
- kernel 能启动。
- initramfs 能挂载 rootfs。
- Alpine userspace 能启动。
- sshd 能运行。

### 5.7 RGB30 显示链 probe 矩阵

#### safe / 全禁显示链

禁用：

```text
rockchip_drm_init
st7703_driver_init
panfrost_driver_init
inno_dsidphy_driver_init
pwm_backlight_driver_init
```

结果：能启动并写日志。

#### phy_backlight_only

```text
rgb30_probe=phy_backlight_only
initcall_blacklist=rockchip_drm_init,st7703_driver_init,panfrost_driver_init
modprobe.blacklist=rockchipdrm,panel_sitronix_st7703,panfrost
```

结果：能写日志。结论：DSI PHY / PWM backlight 不是单独致命点。

#### st7703_only

```text
rgb30_probe=st7703_only
initcall_blacklist=rockchip_drm_init,panfrost_driver_init
modprobe.blacklist=rockchipdrm,panfrost
```

日志出现过：

```text
calling st7703_driver_init
initcall st7703_driver_init returned 0
Run /init as init process
EXT4-fs (mmcblk1p1): mounted filesystem
sshd: Server listening
```

结论：ST7703 driver 注册本身不是致命点。

#### drm_no_panfrost

```text
rgb30_probe=drm_no_panfrost
initcall_blacklist=panfrost_driver_init
modprobe.blacklist=panfrost
```

DTB 当时 DSI0 + panel + HDMI 正常启用。

现象：

```text
屏幕闪一下
状态灯熄灭
没有新的 /boot/firstboot-debug 顶层日志
```

结论：完整显示输出链启用后，在 initramfs 写盘前挂住/断电。

#### drm_core_no_outputs

DTB：

```text
/dsi@fe060000 disabled
/hdmi@fe0a0000 disabled
/hdmi-sound disabled
/vop@fe040000 okay
```

结果：能启动并写日志。

结论：Rockchip DRM 核心 + VOP 不是致命点。

#### drm_hdmi_only

DTB：

```text
/dsi@fe060000 disabled
/hdmi@fe0a0000 okay
/hdmi-sound disabled
/vop@fe040000 okay
```

日志出现过：

```text
rockchip-drm display-subsystem: bound fe040000.vop
dwhdmi-rockchip fe0a0000.hdmi: Detected HDMI TX controller
rockchip-drm display-subsystem: bound fe0a0000.hdmi
[drm] Initialized rockchip 1.0.0 for display-subsystem on minor 0
Run /init as init process
rgb30_probe=drm_hdmi_only
EXT4-fs (mmcblk1p1): mounted filesystem
sshd listener running
```

结论：HDMI 输出路径安全。

#### drm_dsi_no_panel

DTB：

```text
/dsi@fe060000 okay
/dsi@fe060000/panel@0 disabled
/hdmi@fe0a0000 disabled
/hdmi-sound disabled
/vop@fe040000 okay
```

结果：无新日志，屏幕/状态类似挂住或断电。

最强结论：

```text
mainline 7.1 下，只要 DSI0 启用，即使 panel@0 禁用，也会在 initramfs 写盘前挂住/断电。
```

因此问题比 panel init sequence 更早，位于：

```text
Rockchip DRM + RK3566 DSI host + DSI PHY + VOP MIPI route 绑定阶段
```

### 5.8 用户拍到的屏幕现象

用户曾提供照片路径：

```text
/home/adam/Downloads/IMG_0461(20260605-083546)..PNG
/home/adam/.config/QQ/nt_qq_4b349216dd7f4cf081ad558a60afd84b/nt_data/Pic/2026-06/Thumb/561ced00ecadbb30c4eaa0ec12794e85_720.png
```

当时现象：屏幕亮/闪一下后黑。照片说明内屏确实被短暂初始化或被 U-Boot/kernel 早期显示链碰到，但后续显示链或电源/DRM 绑定导致系统不可继续写日志。

### 5.9 RGB30 当前不建议做的事

1. 不建议在当前 mainline 7.1 上直接恢复 DSI0：已验证会无日志挂住。
2. 不建议直接把 dArkOS DTB 塞给 mainline kernel：BSP DTS binding 与 mainline 驱动模型不同。
3. 不建议优先纠结 panel init sequence：因为 `panel@0 disabled` 时 DSI0 仍会挂。

---

## 6. dArkOS / BSP 参考结论

用户要求参考：

```text
/home/adam/Documents/package/dArkOS
```

RGB30 相关脚本：

```text
/home/adam/Documents/package/dArkOS/build_rgb30.sh
/home/adam/Documents/package/dArkOS/build_kernel-rk3566.sh
/home/adam/Documents/package/dArkOS/finishing_touches-rk3566.sh
/home/adam/Documents/package/dArkOS/scripts/rgb30/rgb30versioncheck.sh
```

实际使用内核：

```text
https://github.com/christianhaitian/kernel_5_10_226.git
```

已克隆到：

```text
/home/adam/Documents/package/rgb30/alpine/rgb30-mainline-work/src/darkos-kernel
```

关键 DTS：

```text
arch/arm64/boot/dts/rockchip/rk3566-rgb30.dts
arch/arm64/boot/dts/rockchip/rk3566-rgb30-v2.dts
```

dArkOS/BSP panel 节点：

```dts
compatible = "elida,kd35t133", "simple-panel-dsi";
```

并使用 BSP 风格属性/节点：

```text
panel-init-sequence
panel-exit-sequence
display-timings
route_dsi0
video_phy0
dsi0_in_vp1
```

mainline 当前使用：

```dts
compatible = "powkiddy,rgb30-panel";
```

对应驱动：

```text
drivers/gpu/drm/panel/panel-sitronix-st7703.c
```

mainline panel desc mode flags：

```c
MIPI_DSI_MODE_VIDEO |
MIPI_DSI_MODE_VIDEO_BURST |
MIPI_DSI_MODE_NO_EOT_PACKET |
MIPI_DSI_MODE_LPM
```

BSP DTS flags 含 `MIPI_DSI_MODE_EOT_PACKET`。但当前主要证据仍是：**panel 禁用也挂，所以优先查 DSI host/PHY/VOP route。**

### 6.1 dArkOS 写 bootloader/resource 的参考位置

```bash
sudo dd if=Anbernic_Stock_loader1.img of=$LOOP_DEV bs=$SECTOR_SIZE seek=64 conv=notrunc
sudo dd if=trust.img of=$LOOP_DEV bs=$SECTOR_SIZE seek=8192 conv=notrunc
sudo dd if=uboot.img of=$LOOP_DEV bs=$SECTOR_SIZE seek=16384 conv=notrunc
sudo dd if=rk3566_tool/Image/resource.img of=$LOOP_DEV bs=$SECTOR_SIZE seek=24576 conv=notrunc
```

这属于 BSP/dArkOS route，不等同于 mainline U-Boot `u-boot-rockchip.bin` route。

---

## 7. RGB30 后续可选方向

### 7.1 方向 A：稳定可启动系统优先

保持当前：

```text
DSI off + HDMI on + Panfrost off
```

然后处理：

- rootfs 自动扩容
- Wi-Fi/SDIO
- chrony/CA 证书
- ssh 登录
- 删除错误 ttyS2 getty 或调整到正确串口
- 调整 RGB30 网络配置（不是 E20C 的 eth0/eth1 双网口）

### 7.2 方向 B：BSP/dArkOS 内屏方案

使用：

```text
christianhaitian/kernel_5_10_226
rk3566-rgb30.dtb / rk3566-rgb30-v2.dtb
BSP rk356x uboot/resource/trust 链
```

优点：最接近已跑通的 RGB30 内屏方案。  
缺点：不是纯主线；需要 Alpine rootfs 与 BSP modules/firmware 适配。

### 7.3 方向 C：继续 mainline 7.1 修内屏

重点对比/移植：

```text
mainline drivers/gpu/drm/rockchip/dw-mipi-dsi-rockchip.c
mainline drivers/gpu/drm/rockchip/rockchip_drm_vop2.c
mainline drivers/phy/rockchip/phy-rockchip-inno-dsidphy.c
BSP 5.10 对应驱动
```

优先查：

- RK3566 DSI0 host probe/bind
- DPHY power/clock/reset/regulator 顺序
- VOP2 到 DSI route 绑定
- display-subsystem endpoints / ports / graph
- 是否某个 regulator/backlight/panel supply 在 DSI host 绑定阶段触发断电

---

## 8. RGB30 常用命令

### 8.1 读 TF 卡日志

```bash
mnt=/tmp/rgb30-tf-read
sudo umount "$mnt" 2>/dev/null || true
sudo mkdir -p "$mnt"
sudo mount -o ro /dev/sdd1 "$mnt"

sudo find "$mnt/boot/firstboot-debug" -maxdepth 3 \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %M %10s %p\n' | sort | tail -120

sudo grep -aRInE 'rgb30_probe|rockchip_drm|dsi|hdmi|vop|st7703|panfrost|Run /init|EXT4-fs|sshd|panic|Oops|Call Trace|failed|error|deferred|sync_state' \
  "$mnt/boot/firstboot-debug" | tail -260

sudo umount "$mnt"
```

### 8.2 检查 DTB 状态

```bash
mnt=/tmp/rgb30-tf-read
sudo mount -o ro /dev/sdd1 "$mnt"
for dtb in \
  "$mnt/rk3566-rgb30.dtb" \
  "$mnt/boot/rk3566-rgb30.dtb" \
  "$mnt/dtbs/rockchip/rk3566-powkiddy-rgb30.dtb" \
  "$mnt/boot/dtbs/rockchip/rk3566-powkiddy-rgb30.dtb"; do
  [ -f "$dtb" ] || continue
  echo "--- ${dtb#$mnt/} ---"
  for node in /dsi@fe060000 /dsi@fe060000/panel@0 /hdmi@fe0a0000 /hdmi-sound /vop@fe040000; do
    printf '%s=' "$node"
    sudo fdtget "$dtb" "$node" status 2>/dev/null || true
  done
done
sudo umount "$mnt"
```

### 8.3 安全编辑 TF 卡

```bash
mnt=/tmp/rgb30-sd-edit
sudo umount "$mnt" 2>/dev/null || true
sudo mkdir -p "$mnt"
sudo mount /dev/sdd1 "$mnt"

# 同步编辑：
#   $mnt/extlinux/extlinux.conf
#   $mnt/boot/extlinux/extlinux.conf
# 同步修改所有 dtb 副本。

sudo sync
sudo umount "$mnt"
```

---

## 9. 当前脚本/项目文件索引

### E20C/M28K

```text
/home/adam/Documents/package/e20c/alpine/build_e20c_firmware.sh
/home/adam/Documents/package/e20c/alpine/boards/m28k/README.md
/home/adam/Documents/package/e20c/alpine/logs/m28k-build.log
/home/adam/Documents/package/e20c/alpine/logs/m28k-build2.log
/home/adam/Documents/package/e20c/alpine/logs/m28k-build3.log
/home/adam/Documents/package/e20c/alpine/logs/m28k-build4.log
/home/adam/Documents/package/e20c/alpine/out/radxa-e20c-alpine-mainline.img
/home/adam/Documents/package/e20c/alpine/out/widora-mangopi-m28k-alpine-mainline.img
```

### RGB30

```text
/home/adam/Documents/package/rgb30/alpine/build_rgb30_firmware.sh
/home/adam/Documents/package/rgb30/alpine/README.md
/home/adam/Documents/package/rgb30/alpine/out/powkiddy-rgb30-alpine.img
/home/adam/Documents/package/rgb30/alpine/notes/research.md
/home/adam/Documents/package/rgb30/alpine/notes/boot-layout.md
/home/adam/Documents/package/rgb30/alpine/notes/display-uos-notes.md
/home/adam/Documents/package/rgb30/alpine/notes/uboot-mainline-x55-test.md
/home/adam/Documents/package/rgb30/alpine/notes/firstboot-debug-log.md
/home/adam/Documents/package/rgb30/alpine/notes/darkos-layout-next-step.md
/home/adam/Documents/package/rgb30/alpine/notes/rgb30-mainline-debug-handoff-2026-06-05.md
```

---

## 10. 已知风险和不要忘的点

1. **主线最新 master 是移动目标**：今天能编过，后续可能因 Linux/U-Boot API 变化而失败；必要时记录 commit hash 固化。
2. **rkbin 仍是必要二进制**：所谓“全主线”在 Rockchip DDR init/BL31 层面通常仍需要 rkbin 或等价固件。
3. **RGB30 内屏不是简单 DTB patch**：当前证据指向 DSI host/PHY/VOP route 绑定问题。
4. **Alpine rootfs 要保证 CA/time**：否则 `apk upgrade` 会 TLS fail。
5. **OpenRC 服务 symlink 要基于实际 rootfs 是否存在**：不要再按 minirootfs 假设。
6. **apk 包列表必须数组传参**。
7. **loop 分区元数据必须等待**：`partprobe`/`udevadm settle`/blkid fallback。
8. **串口不是 RGB30 当前可依赖调试口**：用户没找到 TTL；RGB30 主要靠写盘日志。
9. **当前 RGB30 TF 卡安全状态是有意关闭内屏**：不要误判为“内屏修好了”。
10. **如果要继续调 RGB30 内屏**，先决定 BSP/dArkOS 路线还是 mainline driver route；不要再盲开 DSI0。

---

## 11. 下一步建议排序

### 如果继续 E20C/M28K

1. 固化当前成功构建所用 U-Boot/Linux commit。
2. 给 Alpine rootfs 加 `ca-certificates` 和首启 `update-ca-certificates`。
3. 加首启自动扩容 rootfs。
4. 针对 E20C 双网口确认 `eth0/eth1` driver 和 PHY。
5. 针对 M28K 验证 USB/SD/eMMC/网络/LED/按键。

### 如果继续 RGB30

1. 保持当前 safe HDMI-only profile，确认能继续写 fresh logs。
2. 修 rootfs 扩容、CA/time、sshd、网络基础。
3. 若目标是内屏：优先做 BSP/dArkOS kernel + Alpine rootfs 的混合镜像，作为已知可亮屏 baseline。
4. 再做 mainline driver 对比：DSI host/PHY/VOP2 route，不要从 panel init sequence 开始。

---

## 12. 最短恢复上下文

如果新 agent 只看这一段：

```text
E20C: build_e20c_firmware.sh 已是主线 U-Boot/Linux + Alpine apk.static rootfs 的主脚本；minirootfs、apk 参数、PARTUUID、TLS/chrony 等坑已修正/记录。

RGB30: build_rgb30_firmware.sh 使用 mainline U-Boot anbernic-rgxx3-rk3566_defconfig + mainline Linux rk3566-powkiddy-rgb30.dtb；U-Boot/kernel/rootfs/userspace 都证明能跑。当前黑屏致命点不是 U-Boot，也不是 Panfrost，也不是 ST7703 driver 注册，而是 mainline 下启用 DSI0 即在 initramfs 写盘前挂住。当前 TF 卡恢复为 DSI disabled + HDMI enabled 的安全状态。

下一步：稳定系统就保持 DSI off；要内屏就走 dArkOS/BSP 5.10 baseline 或系统性修 mainline RK3566 DSI host/PHY/VOP route。
```
