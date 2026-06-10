#!/usr/bin/env bash
# boards/hinlink-h88k/hooks.sh — Hinlink H88K (RK3588) board hooks.
#
# Pure runtime baseline: inject only the Armbian mainline H88K DTS and register
# the one DTB selected by board.conf.  Bootloader-side hooks mirror Armbian
# hinlink-h88k.csc: Radxa rock-5b defconfig patched to rk3588-evb, then rkbin
# DDR + SPL are packed into idbloader.img for the split Rockchip layout.

board_inject_sources() {
  section "Injecting Hinlink H88K board sources"
  local assets="${BOARD_ASSETS}/${BOARD}"
  [[ -d "${assets}" ]] || fatal "Board assets missing: ${assets}"

  local lx_dts_dir="${KERNEL_SRC_DIR}/arch/arm64/boot/dts/rockchip"
  [[ -d "${lx_dts_dir}" ]] || fatal "Kernel rockchip dts dir missing: ${lx_dts_dir}"

  run cp -f "${assets}/linux/dts/rk3588-hinlink-h88k.dts" "${lx_dts_dir}/"

  if ! grep -q 'rk3588-hinlink-h88k.dtb' "${lx_dts_dir}/Makefile"; then
    log "Registering rk3588-hinlink-h88k.dtb in kernel Makefile"
    printf 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-hinlink-h88k.dtb\n' >> "${lx_dts_dir}/Makefile"
  fi

  local up="${assets}/uboot/patches/0001-h88k-use-evb-dtb-and-enable-console.patch"
  if [[ -d "${UBOOT_DIR}/.git" ]]; then
    [[ -f "${up}" ]] || fatal "H88K U-Boot patch missing: ${up}"
    if ! git -C "${UBOOT_DIR}" apply --reverse --check "${up}" >/dev/null 2>&1; then
      log "Applying H88K Radxa U-Boot patch"
      git -C "${UBOOT_DIR}" apply "${up}" || fatal "H88K U-Boot patch failed to apply."
    else
      log "H88K Radxa U-Boot patch already applied."
    fi
  fi

  log "Hinlink H88K pure board source injected."
}

board_postprocess_uboot() {
  [[ "${ROCKCHIP_SPL_BLOBS:-0}" == "1" ]] || return 0

  section "Packing H88K Armbian-style Rockchip SPL blobs"
  local spl_bin="${RKBIN_DIR}/${TPL_BIN}"
  [[ -f "${spl_bin}" ]] || fatal "H88K DDR blob missing: ${spl_bin}"
  [[ -f "${UBOOT_DIR}/spl/u-boot-spl.bin" ]] || fatal "U-Boot SPL missing: ${UBOOT_DIR}/spl/u-boot-spl.bin"
  [[ -f "${UBOOT_DIR}/u-boot.itb" ]] || fatal "U-Boot ITB missing: ${UBOOT_DIR}/u-boot.itb"

  (
    cd "${UBOOT_DIR}"
    run tools/mkimage -n rk3588 -T rksd -d "${spl_bin}:spl/u-boot-spl.bin" idbloader.img
  )
  [[ -s "${UBOOT_DIR}/idbloader.img" ]] || fatal "idbloader.img was not created."
  log "H88K split bootloader ready: idbloader.img + u-boot.itb"
}

# Install an Armbian-compatible boot.scr alongside the engine's extlinux.conf.
#
# This board does not boot from the SD-card bootloader we build: it runs a
# pre-existing Rockchip vendor U-Boot from eMMC/SPI (proven by the device
# reporting DDR v1.18 at runtime while the official SD image carries v1.20).
# That vendor U-Boot scans the SD card and tries extlinux before boot.scr, but
# its sysboot/extlinux absolute-path handling is unreliable — the exact failure
# lib/env.sh already warns about ("find extlinux.conf yet fail loading
# /boot/Image"). Armbian sidesteps it with an explicit load+booti boot.scr; we
# do the same. extlinux.conf is left in place as a fallback for the case where
# the board is ever made to boot the modern SD U-Boot instead.
board_configure_runtime() {
  [[ "${BOARD_SOC}" == "rk3588" ]] || return 0
  section "Installing Armbian-style boot.scr (H88K eMMC vendor U-Boot path)"

  local tpl="${BOARD_ASSETS}/${BOARD}/boot/boot.cmd"
  [[ -f "${tpl}" ]] || fatal "H88K boot.cmd template missing: ${tpl}"
  [[ -n "${ROOT_PARTUUID}" ]] || read_root_partuuid

  local cmd="${BUILD_DIR}/h88k-boot.cmd" scr="${BUILD_DIR}/h88k-boot.scr"
  sed -e "s|@ROOT_PARTUUID@|${ROOT_PARTUUID}|g" \
      -e "s|@FDTFILE@|${KERNEL_DTB}|g" \
      -e "s|@SERIAL_CONSOLE@|${SERIAL_CONSOLE}|g" \
      -e "s|@SERIAL_BAUD@|${SERIAL_BAUD}|g" \
      "${tpl}" > "${cmd}"

  local mkimage="${UBOOT_DIR}/tools/mkimage"
  [[ -x "${mkimage}" ]] || mkimage="mkimage"
  run "${mkimage}" -C none -A arm -T script -d "${cmd}" "${scr}"

  run_sudo cp "${scr}" "${MOUNTPOINT_ROOT}/boot/boot.scr"

  # Armbian's boot.scr loads the DTB from /boot/dtb/<...>, the engine writes it
  # to /boot/dtbs/<...>; provide it at both paths.
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/boot/dtb/$(dirname "${KERNEL_DTB}")"
  run_sudo cp "${MOUNTPOINT_ROOT}/boot/dtbs/${KERNEL_DTB}" "${MOUNTPOINT_ROOT}/boot/dtb/${KERNEL_DTB}"

  run_sudo tee "${MOUNTPOINT_ROOT}/boot/armbianEnv.txt" >/dev/null <<EOF
verbosity=7
console=both
fdtfile=${KERNEL_DTB}
rootdev=PARTUUID=${ROOT_PARTUUID}
rootfstype=ext4
EOF

  log "H88K /boot: boot.scr + armbianEnv.txt + dtb/${KERNEL_DTB} (extlinux kept as fallback)."
}

board_install_extras() {
  log "H88K pure baseline: no LCD firmware installed."
}
