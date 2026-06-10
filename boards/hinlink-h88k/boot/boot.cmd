# Hinlink H88K boot script (Armbian-compatible). Build-time template: the H88K
# board hook substitutes @ROOT_PARTUUID@ / @FDTFILE@ / @SERIAL_CONSOLE@ /
# @SERIAL_BAUD@ and compiles this to boot.scr with U-Boot mkimage.
#
# Why boot.scr instead of relying on extlinux: this board boots its bootloader
# from a pre-existing Rockchip vendor U-Boot in eMMC/SPI (it reports DDR v1.18 at
# runtime even when the SD card carries a v1.20 idbloader), which bypasses the SD
# bootloader entirely. That vendor U-Boot's sysboot/extlinux absolute-path
# handling is unreliable (it can find /boot/extlinux/extlinux.conf yet fail to
# load /boot/Image), so we use Armbian's explicit load + booti path, which is.
#
# No initrd: the rootfs drivers (dw_mmc-rockchip, sdhci-dwcmshc, ext4, rk3588 clk
# /pinctrl) are built into the kernel, so booti is given '-' for the ramdisk and
# root= uses PARTUUID (kernel-native for GPT; UUID= would need an initramfs).
#
# Recompile after editing: mkimage -C none -A arm -T script -d boot.cmd boot.scr

setenv rootdev "PARTUUID=@ROOT_PARTUUID@"
setenv fdtfile "@FDTFILE@"
setenv consoleargs "console=tty1 console=@SERIAL_CONSOLE@,@SERIAL_BAUD@n8"

# Optional editable overrides (rootdev/fdtfile) without recompiling boot.scr.
if test -e ${devtype} ${devnum}:${distro_bootpart} ${prefix}armbianEnv.txt; then
	load ${devtype} ${devnum}:${distro_bootpart} 0x09000000 ${prefix}armbianEnv.txt
	env import -t 0x09000000 ${filesize}
fi

setenv bootargs "root=${rootdev} rootwait rootfstype=ext4 ${consoleargs} consoleblank=0 loglevel=7 cma=256M cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory"

load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} ${prefix}Image
load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} ${prefix}dtb/${fdtfile}
fdt addr ${fdt_addr_r}
fdt resize 65536
booti ${kernel_addr_r} - ${fdt_addr_r}
