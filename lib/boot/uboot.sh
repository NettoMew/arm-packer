#!/usr/bin/env bash
# lib/boot/uboot.sh — the U-Boot + extlinux boot scheme, shared by the vendor
# plugins whose boards boot a mainline U-Boot the builder compiles itself
# (rockchip, allwinner). Sourced by those plugins, not by the engine: a vendor
# whose firmware brings its own loader never sees any of this.
#
# The vendor keeps what is genuinely its own (blobs, make arguments, where the
# binary lands on the disk); this file owns the rest: the source tree, the
# build, and the extlinux.conf that U-Boot's distro boot reads from the rootfs.

UBOOT_REPO="${UBOOT_REPO:-${DEFAULT_UBOOT_REPO}}"
UBOOT_REF="${UBOOT_REF:-${DEFAULT_UBOOT_REF}}"
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-${BOARD_UBOOT_DEFCONFIG:-}}"
UBOOT_DIR="${SRC_DIR}/u-boot"

uboot_required_keys() { printf 'BOARD_UBOOT_DEFCONFIG\n'; }

uboot_fetch()        { git_clone_or_update "${UBOOT_REPO}" "${UBOOT_REF}" "${UBOOT_DIR}"; }
uboot_assert_fetched() { [[ -d "${UBOOT_DIR}/.git" ]] || fatal "SKIP_FETCH=1 but U-Boot tree missing: ${UBOOT_DIR}"; }

# Checked after the board hooks ran: a board may inject its own defconfig.
uboot_assert_defconfig() {
  [[ -f "${UBOOT_DIR}/configs/${UBOOT_DEFCONFIG}" ]] || fatal "U-Boot defconfig not found: configs/${UBOOT_DEFCONFIG}"
}

# uboot_build [MAKE_ARG...] — mrproper, defconfig, build with the vendor's args.
uboot_build() {
  section "Building mainline U-Boot (${BOARD}, ${UBOOT_DEFCONFIG})"
  pushd "${UBOOT_DIR}" >/dev/null || fatal "U-Boot dir missing: ${UBOOT_DIR}"
  run make mrproper
  run make "${UBOOT_DEFCONFIG}"
  run make -j"${JOBS}" CROSS_COMPILE=aarch64-linux-gnu- "$@"
  popd >/dev/null || true
}

uboot_env_summary() {
  [[ -z "${BOARD_BOOT_VARIANTS:-}" ]] || fatal "BOARD_BOOT_VARIANTS needs the UEFI boot scheme (lib/boot/uefi.sh)."
  log "u-boot source: ${UBOOT_REPO} @ ${UBOOT_REF}"
  log "u-boot defconfig: ${UBOOT_DEFCONFIG}"
}

# Kernel and DTB go to /boot on the rootfs; extlinux.conf points U-Boot at them.
boot_install_extlinux() {
  section "Installing kernel + extlinux.conf"
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/boot/dtbs/$(dirname "${KERNEL_DTB}")" "${MOUNTPOINT_ROOT}/boot/extlinux"
  run_sudo cp "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image" "${MOUNTPOINT_ROOT}/boot/Image"
  run_sudo cp "${KERNEL_BUILD_DIR}/arch/arm64/boot/dts/${KERNEL_DTB}" "${MOUNTPOINT_ROOT}/boot/dtbs/${KERNEL_DTB}"
  run_sudo tee "${MOUNTPOINT_ROOT}/boot/extlinux/extlinux.conf" >/dev/null <<EOF
TIMEOUT 30
DEFAULT mainline

MENU TITLE ${BOARD_MENU_TITLE} ${DISTRO_PRETTY:-Linux}

LABEL mainline
  MENU LABEL ${DISTRO_PRETTY:-Linux} mainline ${RESOLVED_KERNEL_VERSION}
  LINUX /boot/Image
  FDT /boot/dtbs/${KERNEL_DTB}
  APPEND $(kernel_cmdline)
EOF
}
