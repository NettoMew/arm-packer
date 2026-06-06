#!/usr/bin/env bash
# boards/rock5c/hooks.sh — Radxa ROCK 5C (RK3588S2/RK3582) board hooks.
#
# Optional RK3582 core-unlock (开核) U-Boot patch + AIC8800D80 (USB) Wi-Fi driver
# via lib/aic8800.sh. ROCK 5C is otherwise fully mainline (no DTS injection).

# RK3582 "core unlock" (开核): default on; a harmless no-op on a genuine RK3588S2
# (ft_system_setup returns when cpu-code != 0x3582). Set ROCK5C_UNLOCK=0 for stock.
ROCK5C_UNLOCK="${ROCK5C_UNLOCK:-1}"

# AIC8800D80 over USB: the parent dir builds both aic_load_fw + aic8800_fdrv. The
# driver's default firmware path for the D80 is /lib/firmware/aic8800D80.
AIC8800_BUS="usb"
AIC8800_DRV_SUBDIR="src/USB/driver_fw/drivers/aic8800"
AIC8800_FW_SUBDIR="src/USB/driver_fw/fw"
AIC8800_FW_DEST="/lib/firmware/aic8800D80"
AIC8800_PATCH="aic8800/0001-aic8800-usb-mainline-7.1-port.patch"
# shellcheck source=/dev/null
source "${LIB_DIR}/aic8800.sh"

board_inject_sources() {
  # ROCK 5C is fully mainline; the only optional U-Boot injection is the RK3582
  # core-unlock (开核) patch.
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
  # AIC8800 Wi-Fi/BT vendor driver: fetch + apply mainline (USB) port patch.
  aic8800_prepare_source
}

board_build_modules()     { aic8800_build; }
board_install_modules()   { aic8800_install; }
board_install_userspace() { aic8800_install_userspace; }
board_configure_runtime() { aic8800_configure_runtime; }
