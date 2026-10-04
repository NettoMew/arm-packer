#!/usr/bin/env bash
# lib/fs/ext4.sh — ext4 root filesystem plugin, the default (ROOTFS_TYPE=ext4).
#
# The kernel mounts ext4 straight from the root partition, so this plugin needs
# no initramfs, no modules of its own and nothing on the build host beyond
# e2fsprogs. U-Boot reads the kernel from it as well (lib/boot/uboot.sh).
#
# Defines the fs_* contract; lib/fs/zfs.sh is the other implementation.

# Boot and fstab find the root by PARTUUID; the label only names it for people.
ROOTFS_LABEL="${ROOTFS_LABEL:-root}"
# Keep the root filesystem readable by U-Boot's conservative ext4 implementation.
# Recent e2fsprogs defaults can enable metadata_csum_seed/orphan_file/64bit; these
# are useful on large server filesystems but unnecessary for small SBC boot images
# and can make U-Boot find extlinux.conf yet fail loading /boot/Image.
ROOTFS_EXT4_FEATURES="${ROOTFS_EXT4_FEATURES:-^metadata_csum,^metadata_csum_seed,^orphan_file,^64bit}"

fs_env_summary() {
  log "root filesystem: ext4 (label ${ROOTFS_LABEL}${ROOTFS_EXT4_FEATURES:+, features ${ROOTFS_EXT4_FEATURES}})"
}

fs_check_config()  { :; }
fs_check_host()    { :; }   # mkfs.ext4 is a base dependency (lib/deps.sh)
fs_build_modules() { :; }

fs_format() {
  local part="$1"
  local -a features=()
  [[ -z "${ROOTFS_EXT4_FEATURES}" ]] || features=(-O "${ROOTFS_EXT4_FEATURES}")
  log "mkfs.ext4 ${part} label=${ROOTFS_LABEL}${ROOTFS_EXT4_FEATURES:+ features=${ROOTFS_EXT4_FEATURES}}"
  run_sudo mkfs.ext4 -F -L "${ROOTFS_LABEL}" "${features[@]}" "${part}"
}

fs_mount()   { run_sudo mount "$1" "${MOUNTPOINT_ROOT}"; }
fs_release() { :; }
fs_install() { :; }

fs_root_cmdline() { printf 'root=PARTUUID=%s rootwait rw\n' "${ROOT_PARTUUID}"; }
fs_fstab_root()   { printf 'PARTUUID=%s / ext4 rw,noatime 0 1\n' "${ROOT_PARTUUID}"; }
