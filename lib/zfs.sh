#!/usr/bin/env bash
# lib/zfs.sh — OpenZFS for the image's own kernel, as a capability: the modules
# from the release pinned in config/versions.conf, built against the kernel just
# compiled and installed with its other modules, and the distro's userspace of
# the same release (distro_install_zfs). Sourced by what needs ZFS: the ZFS root
# (lib/fs/zfs.sh) and the Incus profile (lib/profile/incus.sh). Each step runs
# once per build, however many of them ask for it.

# Pool properties, then the dataset properties every dataset inherits; xattr=sa
# and posixacl serve journald and containers. Shared by every pool arm-packer
# creates, on the build host or on the board.
ZFS_POOL_PROPERTIES="${ZFS_POOL_PROPERTIES:-ashift=12 autotrim=on}"
ZFS_DATASET_PROPERTIES="${ZFS_DATASET_PROPERTIES:-compression=zstd atime=off xattr=sa acltype=posixacl dnodesize=auto}"

: "${ZFS_MODULES_BUILT:=0}" "${ZFS_INSTALLED:=0}"

# The release tarball, cached by checksum, unpacked afresh and configured against
# the kernel just built, so the modules always match it.
zfs_build_modules() {
  [[ "${ZFS_MODULES_BUILT}" == 1 ]] && return 0
  local tarball="${DOWNLOAD_DIR}/zfs-${OPENZFS_VERSION}.tar.gz" src
  src="$(zfs_source_dir)"
  if ! sha256_matches "${tarball}" "${OPENZFS_SHA256}"; then
    section "Fetching OpenZFS ${OPENZFS_VERSION}"
    aria2_download "${OPENZFS_URL}" "${tarball}" || fatal "OpenZFS download failed: ${OPENZFS_URL}"
    sha256_matches "${tarball}" "${OPENZFS_SHA256}" || fatal "OpenZFS checksum mismatch: ${tarball}"
  fi
  section "Building OpenZFS ${OPENZFS_VERSION} kernel modules"
  rm -rf "${src}"
  tar -xzf "${tarball}" -C "$(dirname "${src}")"
  [[ -f "${src}/META" ]] || fatal "OpenZFS tarball did not unpack to ${src}"

  local kernel maximum
  kernel="$(make -s -C "${KERNEL_SRC_DIR}" kernelversion)"
  maximum="$(awk '$1 == "Linux-Maximum:" { print $2 }' "${src}/META")"
  [[ "$(printf '%s\n' "${kernel%.*}" "${maximum}" | sort -V | tail -n 1)" == "${maximum}" ]] \
    || fatal "OpenZFS ${OPENZFS_VERSION} supports Linux up to ${maximum}, not ${kernel}; pin a newer release in config/versions.conf."

  (cd "${src}" && run ./configure --quiet --with-config=kernel --host=aarch64-linux-gnu \
    --with-linux="${KERNEL_SRC_DIR}" --with-linux-obj="${KERNEL_BUILD_DIR}" \
    KERNEL_ARCH=arm64 KERNEL_CROSS_COMPILE=aarch64-linux-gnu-) || fatal "OpenZFS configure failed against Linux ${kernel}."
  run make -C "${src}/module" -j"${JOBS}"
  [[ -f "${src}/module/zfs.ko" && -f "${src}/module/spl.ko" ]] || fatal "OpenZFS build produced no zfs.ko/spl.ko."
  ZFS_MODULES_BUILT=1
  log "OpenZFS ${OPENZFS_VERSION} modules built for Linux ${kernel}."
}

# The modules into the rootfs beside the kernel's own, then the userspace.
zfs_install() {
  [[ "${ZFS_INSTALLED}" == 1 ]] && return 0
  local krel src
  krel="$(kernel_release)"
  src="$(zfs_source_dir)"
  section "Installing OpenZFS ${OPENZFS_VERSION} modules for ${krel}"
  [[ -f "${src}/module/zfs.ko" ]] || fatal "OpenZFS modules were not built (${src}/module)."
  run_sudo make -C "${src}/module" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH="${MOUNTPOINT_ROOT}" INSTALL_MOD_STRIP=1 modules_install
  run_sudo depmod -b "${MOUNTPOINT_ROOT}" "${krel}"
  distro_install_zfs "${OPENZFS_VERSION}"
  ZFS_INSTALLED=1
}

zfs_source_dir() { printf '%s/zfs-%s\n' "${BUILD_DIR}" "${OPENZFS_VERSION}"; }
