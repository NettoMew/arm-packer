#!/usr/bin/env bash
# lib/env.sh — generic build knobs (env-overridable) + derived paths + global state.
#
# Sourced by scripts/build.sh AFTER boards/<board>/board.conf, so the BOARD_*
# values a board declares become the defaults here. Everything stays
# ${VAR:-default} so every override the README documents still works. Board
# dispatch (the old `case BOARD`), the rkbin/ATF blob selection and the AIC8800
# per-bus table all moved out — to config/, lib/vendor/* and boards/*/hooks.sh.
#
# shellcheck disable=SC2034  # vars here are consumed by other sourced lib modules.

# Central defaults do not overwrite the effective env/board settings.
# shellcheck source=../config/versions.conf
source "${PROJECT_DIR}/config/versions.conf"

# Per-board declaration defaults (a board.conf may override any of these).
BOARD_SERIAL_BAUD="${BOARD_SERIAL_BAUD:-1500000}"
BOARD_KERNEL_CMDLINE_EXTRA="${BOARD_KERNEL_CMDLINE_EXTRA:-}"
BOARD_SECOND_NIC="${BOARD_SECOND_NIC:-0}"
# Number of wired NICs to bring up (all DHCP, no role split). Canonical knob;
# BOARD_SECOND_NIC=1 is the legacy spelling for "2". A board may set BOARD_NICS
# directly. Arch's shipped systemd-networkd catch-all covers any
# count; only Alpine's ifupdown enumerates per-NIC (lib/distro/alpine.sh).
if [[ -z "${BOARD_NICS:-}" ]]; then
  [[ "${BOARD_SECOND_NIC}" == "1" ]] && BOARD_NICS=2 || BOARD_NICS=1
fi
BOARD_KERNEL_FRAGMENTS="${BOARD_KERNEL_FRAGMENTS:-}"

# Image name = <board prefix>-<distro>-<linux kernel version>.img, e.g.
# radxa-e20c-alpine-<version>.img / radxa-rock5c-archlinux-<version>.img. The kernel
# version is resolved from the fetched source, so the name is FINALIZED after fetch
# (finalize_image_name in lib/sources.sh). A user-pinned IMAGE_NAME overrides.
IMAGE_NAME_PREFIX="${BOARD_IMAGE_PREFIX}-${DISTRO}"
IMAGE_NAME="${IMAGE_NAME:-}"   # empty = auto-compose with the kernel version after fetch
# IMAGE_SIZE is finalized in scripts/build.sh AFTER the distro plugin is sourced,
# from DISTRO_IMAGE_SIZE (Alpine's tiny rootfs fits 1G; the ALARM rootfs needs ~4G).
# The build image is sparse + xz-compressed + first-boot-resized, so a larger
# image costs almost nothing in the .img.xz (xz -T0 -6).
JOBS="${JOBS:-$(nproc)}"
export MAKEFLAGS="${MAKEFLAGS:--j${JOBS}}"

# Upstream stable Linux, pinned to a release tag for reproducible builds.
# Stable point releases live in stable/linux.git, not torvalds/linux.git.
# Override KERNEL_REPO/KERNEL_REF if you need a different mirror or branch/tag.
KERNEL_REPO="${KERNEL_REPO:-${DEFAULT_KERNEL_REPO}}"
KERNEL_REF="${KERNEL_REF:-${DEFAULT_KERNEL_REF}}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-defconfig}"
KERNEL_DTB="${KERNEL_DTB:-${BOARD_KERNEL_DTB}}"

# Optional SWUpdate test-image foundation; require explicit packages + trust key.
ENABLE_SWUPDATE="${ENABLE_SWUPDATE:-0}"
SWUPDATE_PACKAGE_DIR="${SWUPDATE_PACKAGE_DIR:-}"
SWUPDATE_PUBLIC_KEY="${SWUPDATE_PUBLIC_KEY:-}"

# Rootfs userspace (package manager + init system + network) is provided by the
# distro plugin lib/distro/${DISTRO}.sh — it owns its repo URLs, base package set
# and the GPU/Wi-Fi userspace package names.

# Boot/runtime configuration. Console node + baud are per-board (declared in
# board.conf: RK3528 ttyS0 / RK3588 ttyS2 @ 1.5M, Allwinner H618 ttyS0 @ 115200).
SERIAL_CONSOLE="${SERIAL_CONSOLE:-${BOARD_SERIAL_CONSOLE}}"
SERIAL_BAUD="${SERIAL_BAUD:-${BOARD_SERIAL_BAUD}}"
# First partition starts at 16 MiB: clear of every vendor's raw-sector bootloader
# (Rockchip idbloader/u-boot.itb up to ~12 MiB, Allwinner SPL at 8 KiB).
ROOTFS_PART_START_SECTOR="${ROOTFS_PART_START_SECTOR:-32768}"
ROOTFS_LABEL="${ROOTFS_LABEL:-alpine_root}"
# Keep the root filesystem readable by U-Boot's conservative ext4 implementation.
# Recent e2fsprogs defaults can enable metadata_csum_seed/orphan_file/64bit; these
# are useful on large server filesystems but unnecessary for small SBC boot images
# and can make U-Boot find extlinux.conf yet fail loading /boot/Image.
ROOTFS_EXT4_FEATURES="${ROOTFS_EXT4_FEATURES:-^metadata_csum,^metadata_csum_seed,^orphan_file,^64bit}"
IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-${BOARD_HOSTNAME}}"

# Time sync. These boards have no battery-backed RTC, so the clock starts wrong
# every boot and chrony must step it once the network is up. Default to Aliyun
# NTP (reliable in CN) and Asia/Shanghai. Set TIMEZONE="" to keep UTC.
NTP_SERVERS="${NTP_SERVERS:-ntp.aliyun.com ntp1.aliyun.com cn.pool.ntp.org}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

# Root login baked into the image (ready-to-use). ROOT_PASSWORD="" leaves the
# account password-less (serial only); any non-empty value is hashed (SHA-512)
# into /etc/shadow. ROOT_AUTHORIZED_KEY, if set, is written to
# /root/.ssh/authorized_keys and PermitRootLogin is enabled so key/password SSH
# works on first boot. Set ROOT_AUTHORIZED_KEY="" to install no key.
ROOT_PASSWORD="${ROOT_PASSWORD:-120102}"
ROOT_AUTHORIZED_KEY="${ROOT_AUTHORIZED_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINMj1ZURxNE8MV9OkwEYruwBNQDgn61k0u2wQNWIxu7P}"

# First-boot auto-expand: a one-shot /etc/local.d script grows the root partition
# to fill the whole eMMC/SD and online-resizes ext4 on first boot, then disables
# itself. Needs `parted` in the image (installed online; resize2fs is already in
# e2fsprogs). Set AUTO_RESIZE=0 to skip.
AUTO_RESIZE="${AUTO_RESIZE:-1}"

# Build the kernel with the full container/Docker netfilter stack (nftables +
# iptables + NAT + bridge/veth/overlay + namespaces). Set DOCKER_KERNEL=0 for a
# leaner kernel without Docker networking support.
DOCKER_KERNEL="${DOCKER_KERNEL:-1}"

# Build the kernel with the modern eBPF stack: dae (daeuniverse) transparent
# proxy (BPF + BTF/CO-RE + tc clsact + kprobes), tproxy/socket match, WireGuard,
# TUN, BBR + fq/cake. Needs `pahole` on the host (for BTF). Set MODERN_KERNEL=0
# to skip (smaller/faster kernel without eBPF/dae support).
MODERN_KERNEL="${MODERN_KERNEL:-1}"

# Build a general-purpose / router-grade kernel with desktop-distro breadth
# (filesystems, full netfilter + QoS, tunnels incl. PPPoE, VLAN/bridge/bonding,
# IP_SET, conntrack helpers, USB NIC/modem drivers, device-mapper, binfmt_misc,
# full cgroups). Set DISTRO_KERNEL=0 for a slimmer board-only kernel.
DISTRO_KERNEL="${DISTRO_KERNEL:-1}"
DISTRO_CONFIG_FRAGMENT="${DISTRO_CONFIG_FRAGMENT:-${PROJECT_DIR}/kconfig/distro-arm64.config}"

# Keep the full linux-firmware pool instead of slimming it. Cross-distro intent: on
# Arch it forces ARCH_STRIP_ALL_FW=0 + keeps the linux-firmware packages (see
# lib/distro/archlinux.sh); on Alpine it installs the linux-firmware meta. Default
# off (each distro keeps its lean default); a board may override it.
FULL_FIRMWARE="${FULL_FIRMWARE:-0}"

# Directory holding the composable kconfig fragments merged on top of defconfig.
KCONFIG_DIR="${KCONFIG_DIR:-${PROJECT_DIR}/kconfig}"
# Directory holding fixed rootfs reference files (resize script, wpa template,
# /etc/network/interfaces base + eth1 stanza) overlaid/rendered into the image.
RESOURCES_DIR="${RESOURCES_DIR:-${PROJECT_DIR}/resources}"

# GPU userspace (Mesa Gallium: lima RK3528 / panfrost H618) package names are
# distro-specific and declared by the distro plugin (GPU_USERSPACE_PACKAGES).

# Dependency behavior. Set INSTALL_DEPS=0 to only check and fail if missing.
INSTALL_DEPS="${INSTALL_DEPS:-1}"
APT_ASSUME_YES="${APT_ASSUME_YES:--y}"
PACMAN_ASSUME_YES="${PACMAN_ASSUME_YES:---needed --noconfirm}"

# Build behavior.
CLEAN_WORKSPACE="${CLEAN_WORKSPACE:-0}"
KEEP_MOUNTS_ON_ERROR="${KEEP_MOUNTS_ON_ERROR:-0}"
# Set SKIP_FETCH=1 to reuse already-cloned U-Boot/Linux/firmware trees instead of
# fetching the configured refs. Useful for reproducible iteration and to keep a
# tree state that the m28k backport patches are known to apply against.
SKIP_FETCH="${SKIP_FETCH:-0}"
# Kernel build is INCREMENTAL by default: the build dir is reused and `make` only
# recompiles what changed (the .config is regenerated from defconfig+fragments
# each time, so it never carries stale options across boards). Set CLEAN_KERNEL=1
# to wipe the build dir and compile from scratch.
CLEAN_KERNEL="${CLEAN_KERNEL:-0}"
# Set SKIP_BUILD=1 to skip the U-Boot + kernel compile entirely and reuse the
# existing artifacts (fast iteration on rootfs/distro/image only). Asserts the
# artifacts exist; they must be from a prior build of THIS same board.
SKIP_BUILD="${SKIP_BUILD:-0}"

# Set COMPRESS_IMAGE=0 to keep the raw .img only. Default (1) runs `xz` on the
# finished image to produce <image>.img.xz and removes the raw .img.
COMPRESS_IMAGE="${COMPRESS_IMAGE:-1}"

# ------------------------------ Derived paths --------------------------------
DOWNLOAD_DIR="${WORKSPACE}/downloads"
SRC_DIR="${WORKSPACE}/src"
BUILD_DIR="${WORKSPACE}/build"
KERNEL_SRC_DIR="${SRC_DIR}/linux"
KERNEL_BUILD_DIR="${BUILD_DIR}/linux-build"
IMAGE_PATH="${OUTPUT_DIR}/${IMAGE_NAME}"
# Boot-chain source trees + blob paths (UBOOT_DIR / RKBIN_DIR / ATF_DIR / BL31_BIN / …)
# are declared by lib/vendor/<vendor>.sh and the lib/boot/*.sh scheme it sources.

# ------------------------------ Global state ---------------------------------
LOOPDEV=""
MOUNTPOINT_ROOT=""
ROOT_PARTUUID=""
# Partition of the layout that mounts at / (1-based), and where the ESP mounts
# when the layout has one; set by load_partition_layout (lib/image.sh).
ROOT_PART=""
ESP_MOUNT=""
SUDO=""
RESOLVED_KERNEL_VERSION=""
RESOLVED_ALPINE_URL=""
ALPINE_REPO_DIR=""
APK_STATIC=""
# Kernel fragment list, assembled by lib/kernel.sh from vendor + SoC + board + features.
KERNEL_FRAGMENT_LIST=()
