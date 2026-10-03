#!/usr/bin/env bash
# lib/fs/zfs.sh — ZFS root filesystem plugin (ROOTFS_TYPE=zfs).
#
# The root partition holds a pool, rpool, with one boot environment dataset,
# rpool/ROOT/<distro>, mounted at /. The kernel cannot import a pool on its own,
# so the distro builds an initramfs that does (distro_build_initramfs), and the
# boot scheme loads it beside the kernel: the kernel must live outside the pool,
# on an ESP (lib/boot/uefi.sh). U-Boot boards, which read the kernel from the
# root filesystem, stay on ext4.
#
# The modules come from the OpenZFS release pinned in config/versions.conf,
# built with the image's kernel and installed with its other modules; the distro
# supplies the userspace of the same release (lib/zfs.sh). The pool is
# created on the build host, whose kernel therefore needs ZFS too: it is created
# under a temporary name, so it never clashes with a pool of the host's own, and
# limited to a feature set every OpenZFS since 2.2 imports, so a host newer than
# the image cannot enable a feature the image's modules lack. It is exported at
# the end, which lets the board import it without regard to the host it came from.
#
# Defines the fs_* contract, like lib/fs/ext4.sh.
#
# shellcheck disable=SC2034  # ROOTFS_INITRD is read by the boot scheme.

# shellcheck source=lib/zfs.sh
source "${LIB_DIR}/zfs.sh"

ZFS_POOL="${ZFS_POOL:-rpool}"
ZFS_POOL_COMPATIBILITY="${ZFS_POOL_COMPATIBILITY:-openzfs-2.2-linux}"
ZFS_BUILD_POOL="arm-packer-$$"   # the pool's name while the build host has it imported
ZFS_ROOT_DATASET="${ZFS_POOL}/ROOT/${DISTRO}"

fs_env_summary() {
  log "root filesystem: ZFS pool ${ZFS_POOL} (${ZFS_ROOT_DATASET} at /, features ${ZFS_POOL_COMPATIBILITY}), OpenZFS ${OPENZFS_VERSION} modules"
}

fs_check_config() {
  declare -F distro_install_zfs distro_build_initramfs >/dev/null \
    || fatal "DISTRO=${DISTRO} cannot boot a ZFS root (its plugin has no distro_install_zfs / distro_build_initramfs); use DISTRO=debian or ROOTFS_TYPE=ext4."
}

fs_check_host() {
  section "Checking OpenZFS on the build host"
  { have zpool && have zfs; } \
    || fatal "ROOTFS_TYPE=zfs creates the pool on the build host, which needs the OpenZFS tools (Debian/Ubuntu: apt install zfsutils-linux)."
  require_root_capability
  [[ -d /sys/module/zfs ]] || run_sudo modprobe zfs \
    || fatal "The build host's kernel has no zfs module (in a container, load it on the container's host: modprobe zfs)."
  log "Build host OpenZFS $(< /sys/module/zfs/version); pool feature set ${ZFS_POOL_COMPATIBILITY}."
}

fs_build_modules() { zfs_build_modules; }

# The pool and its datasets, then exported: fs_mount imports it like any disk.
# Only the boot environment has a mountpoint; the pool's own dataset mounts
# nowhere, and so does a new one until it is given a place.
fs_format() {
  local part="$1" prop
  local -a options=(-o cachefile=none -o "compatibility=${ZFS_POOL_COMPATIBILITY}" -O mountpoint=none -O canmount=off)
  local -a pool_props dataset_props
  IFS=' ' read -r -a pool_props <<< "${ZFS_POOL_PROPERTIES}"        # global IFS has no space
  IFS=' ' read -r -a dataset_props <<< "${ZFS_DATASET_PROPERTIES}"
  for prop in "${pool_props[@]}"; do options+=(-o "${prop}"); done
  for prop in "${dataset_props[@]}"; do options+=(-O "${prop}"); done
  log "zpool create ${ZFS_POOL} on ${part}"
  run_sudo zpool create -f -t "${ZFS_BUILD_POOL}" "${options[@]}" "${ZFS_POOL}" "${part}"
  run_sudo zfs create -o canmount=off -o mountpoint=none "${ZFS_BUILD_POOL}/ROOT"
  run_sudo zfs create -o canmount=noauto -o mountpoint=/ "$(_zfs_build_name "${ZFS_ROOT_DATASET}")"
  run_sudo zpool set bootfs="$(_zfs_build_name "${ZFS_ROOT_DATASET}")" "${ZFS_BUILD_POOL}"
  run_sudo zpool export "${ZFS_BUILD_POOL}"
}

fs_mount() {
  run_sudo zpool import -d "$1" -N -R "${MOUNTPOINT_ROOT}" -t "${ZFS_POOL}" "${ZFS_BUILD_POOL}"
  run_sudo zfs mount "$(_zfs_build_name "${ZFS_ROOT_DATASET}")"
}

# Once the root is unmounted: hand the freed blocks back to the sparse image
# (trim punches holes through the loop device), then export the pool.
fs_release() {
  run_sudo zpool list "${ZFS_BUILD_POOL}" >/dev/null 2>&1 || return 0
  run_sudo zpool trim -w "${ZFS_BUILD_POOL}" || warn "zpool trim failed; the image compresses less well."
  run_sudo zpool export "${ZFS_BUILD_POOL}"
}

# The modules into the rootfs with the kernel's own, the distro's userspace on
# top, then the initramfs that imports the pool at boot.
fs_install() {
  local krel
  zfs_install
  krel="$(kernel_release)"
  ROOTFS_INITRD="${BUILD_DIR}/initrd.img-${krel}"
  distro_build_initramfs "${krel}" "${ROOTFS_INITRD}"
}

fs_root_cmdline() { printf 'root=ZFS=%s rw\n' "${ZFS_ROOT_DATASET}"; }
fs_fstab_root()   { :; }   # the initramfs mounts the root; the pool knows its datasets

# A dataset of the pool as the build host names it (rpool/x → arm-packer-PID/x).
_zfs_build_name() { printf '%s/%s\n' "${ZFS_BUILD_POOL}" "${1#*/}"; }
