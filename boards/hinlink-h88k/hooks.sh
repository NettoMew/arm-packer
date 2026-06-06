#!/usr/bin/env bash
# boards/hinlink-h88k/hooks.sh — Hinlink H88K (RK3588) board hooks.
#
# The board DTS is not upstream, so board_inject_sources drops it into the mainline
# kernel tree (and registers it in the dtb Makefile) the same way m28k does. U-Boot
# needs no injection — board.conf reuses rock5b-rk3588_defconfig.
#
# Screen flavour (H88K_LCD=1): the 240x135 SPI LCD lives in the device tree, so the
# panel fragment dtsi is #include'd into the board DTS and its init-sequence
# firmware is copied into the rootfs. noscreen omits both.

board_inject_sources() {
  section "Injecting Hinlink H88K board sources"
  local assets="${BOARD_ASSETS}/${BOARD}"
  [[ -d "${assets}" ]] || fatal "Board assets missing: ${assets}"

  local lx_dts_dir="${KERNEL_SRC_DIR}/arch/arm64/boot/dts/rockchip"
  [[ -d "${lx_dts_dir}" ]] || fatal "Kernel rockchip dts dir missing: ${lx_dts_dir}"

  # Pristine board DTS (+ LCD panel fragment) into the kernel tree. cp -f every
  # build so a prior screen build's appended #include never leaks into noscreen.
  run cp -f "${assets}/linux/dts/rk3588-hinlink-h88k.dts"      "${lx_dts_dir}/"
  run cp -f "${assets}/linux/dts/rk3588-hinlink-h88k-lcd.dtsi" "${lx_dts_dir}/"

  if [[ "${H88K_LCD}" == "1" ]]; then
    log "Screen flavour: merging 240x135 LCD panel into board DTS"
    printf '\n#include "rk3588-hinlink-h88k-lcd.dtsi"\n' \
      >> "${lx_dts_dir}/rk3588-hinlink-h88k.dts"
  fi

  if ! grep -q 'rk3588-hinlink-h88k.dtb' "${lx_dts_dir}/Makefile"; then
    log "Registering rk3588-hinlink-h88k.dtb in kernel Makefile"
    printf 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-hinlink-h88k.dtb\n' \
      >> "${lx_dts_dir}/Makefile"
  fi

  log "Hinlink H88K board sources injected."
}

board_install_extras() {
  # Screen flavour only: the panel-mipi-dbi-spi driver derives its firmware name
  # from compatible[0] → hinlink-h88k-240x135-lcd.bin, loaded from /lib/firmware.
  [[ "${H88K_LCD}" == "1" ]] || { log "LCD firmware not included (H88K_LCD=${H88K_LCD:-0})."; return 0; }
  section "Installing 240x135 LCD init-sequence firmware"
  local fw="${BOARD_ASSETS}/${BOARD}/lcd/hinlink-h88k-240x135-lcd.bin"
  [[ -f "${fw}" ]] || fatal "LCD firmware missing: ${fw} (vendored from github.com/armbian/firmware)."
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/lib/firmware"
  run_sudo cp "${fw}" "${MOUNTPOINT_ROOT}/lib/firmware/hinlink-h88k-240x135-lcd.bin"
  log "LCD firmware installed: /lib/firmware/hinlink-h88k-240x135-lcd.bin"
}
