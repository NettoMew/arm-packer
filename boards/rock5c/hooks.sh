#!/usr/bin/env bash
# boards/rock5c/hooks.sh — Radxa ROCK 5C (RK3588S2/RK3582) board hooks.
#
# Optional RK3582 core-unlock / NVMe-first U-Boot profiles + AIC8800D80 Wi-Fi
# via lib/aic8800.sh. ROCK 5C is otherwise fully mainline (no DTS injection).

# RK3582 "core unlock" (开核): default on; a harmless no-op on a genuine RK3588S2
# (ft_system_setup returns when cpu-code != 0x3582). Set ROCK5C_UNLOCK=0 for stock.
ROCK5C_UNLOCK="${ROCK5C_UNLOCK:-1}"

# Opt-in firmware profile: NVMe carries /boot and rootfs, SD remains rescue.
# This does not install to or format any disk; the default remains SD-first.
ROCK5C_NVME_BOOT="${ROCK5C_NVME_BOOT:-0}"

# AIC8800D80 over USB: the parent dir builds both aic_load_fw + aic8800_fdrv. The
# driver's default firmware path for the D80 is /lib/firmware/aic8800D80.
AIC8800_BUS="usb"
AIC8800_DRV_SUBDIR="src/USB/driver_fw/drivers/aic8800"
AIC8800_FW_SUBDIR="src/USB/driver_fw/fw"
AIC8800_FW_DEST="/lib/firmware/aic8800D80"
AIC8800_PATCH="aic8800/0001-aic8800-usb-mainline-port.patch"
# shellcheck source=/dev/null
source "${LIB_DIR}/aic8800.sh"

board_inject_uboot_sources() {
  case "${ROCK5C_NVME_BOOT}" in
    0|1) ;;
    *) fatal "ROCK5C_NVME_BOOT must be 0 or 1." ;;
  esac
  # Both opt-in policy changes stay board-local; no generic engine branches.
  if [[ "${ROCK5C_UNLOCK}" == "1" ]]; then
    section "Applying RK3582 core-unlock (开核) patch to mainline U-Boot"
    local up="${BOARD_ASSETS}/rock5c/uboot/patches/0001-rk3582-unlock-cores-gpu.patch"
    [[ -f "${up}" ]] || fatal "rock5c unlock patch missing: ${up}"
    log "git apply $(basename "${up}")"
    git -C "${UBOOT_DIR}" apply "${up}" || fatal "rock5c rk3582 unlock patch failed to apply."
    log "RK3582 开核 applied (segmentation policy for big cluster2 + GPU removed; genuine OTP defects still honored)."
  else
    log "ROCK5C_UNLOCK=0: stock mainline U-Boot (RK3582 stays binned)."
  fi
  case "${ROCK5C_NVME_BOOT}" in
    0) ;;
    1)
      local nvme_patch="${BOARD_ASSETS}/rock5c/uboot/patches/0002-rock5c-nvme-first-bootstd.patch"
      [[ -f "${nvme_patch}" ]] || fatal "rock5c NVMe boot patch missing: ${nvme_patch}"
      git -C "${UBOOT_DIR}" apply "${nvme_patch}" || fatal "rock5c NVMe boot patch failed to apply."
      log "ROCK5C_NVME_BOOT=1: upstream BootSTD extlinux, NVMe first, SD/eMMC/USB fallback; no saved environment."
      ;;
  esac
}

board_prepare_modules() { aic8800_prepare_source; }

board_inject_sources() {
  board_inject_uboot_sources
  board_prepare_modules
}

board_build_modules()     { aic8800_build; }
board_install_modules()   { aic8800_install; }
board_install_userspace() { wifi_install_userspace; }
board_configure_runtime() { wifi_configure_runtime; }
