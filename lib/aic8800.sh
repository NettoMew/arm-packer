#!/usr/bin/env bash
# lib/aic8800.sh — AIC8800 out-of-tree Wi-Fi/BT driver (radxa-pkg/aic8800, ported
# to mainline 7.1). Shared by the boards that carry the chip; each board's
# hooks.sh sets the per-bus vars (AIC8800_BUS + DRV/FW subdirs + patch) and wires
# its board_* hooks to these helpers. Bus dispatch (sdio vs usb) is genuine
# hardware difference, not board dispatch.

AIC8800_REPO="${AIC8800_REPO:-${DEFAULT_AIC8800_REPO}}"
AIC8800_COMMIT="${AIC8800_COMMIT:-${DEFAULT_AIC8800_COMMIT}}"
AIC8800_DIR="${AIC8800_DIR:-${SRC_DIR}/aic8800}"
# WIFI_USERSPACE_PACKAGES default + the install/enable/iface primitives are
# distro-provided (lib/distro/<distro>.sh), so this driver layer is distro-agnostic.

# Clone/refresh the driver source and apply the per-bus mainline port patch.
# Idempotent: checkout -- . then re-apply. Called from a board's inject_sources.
aic8800_prepare_source() {
  section "Preparing AIC8800 Wi-Fi driver source (${AIC8800_BUS})"
  if [[ -d "${AIC8800_DIR}/.git" ]]; then
    if [[ "${SKIP_FETCH}" == "1" ]]; then
      log "SKIP_FETCH=1: reusing existing AIC8800 clone."
    else
      run git -C "${AIC8800_DIR}" fetch --depth 1 origin "${AIC8800_COMMIT}"
    fi
    run git -C "${AIC8800_DIR}" checkout -q "${AIC8800_COMMIT}"
    run git -C "${AIC8800_DIR}" checkout -- .
  else
    run git clone --filter=blob:none "${AIC8800_REPO}" "${AIC8800_DIR}"
    run git -C "${AIC8800_DIR}" checkout -q "${AIC8800_COMMIT}"
  fi
  log "AIC8800 HEAD: $(git -C "${AIC8800_DIR}" rev-parse --short HEAD)"
  local aic_patch="${BOARD_ASSETS}/${BOARD}/${AIC8800_PATCH}"
  [[ -f "${aic_patch}" ]] || fatal "AIC8800 port patch missing: ${aic_patch}"
  log "git apply $(basename "${aic_patch}")"
  git -C "${AIC8800_DIR}" apply "${aic_patch}" || fatal "AIC8800 port patch failed to apply."
}

# Build the out-of-tree module(s) against the just-built kernel.
aic8800_build() {
  local drv="${AIC8800_DIR}/${AIC8800_DRV_SUBDIR}"
  [[ -d "${drv}" ]] || fatal "AIC8800 driver dir missing: ${drv}"
  if [[ "${AIC8800_BUS}" == "sdio" ]]; then
    section "Building AIC8800 Wi-Fi modules (SDIO, wifi-only)"
    # WiFi-only (CONFIG_SDIO_BT=n): on the M28K's AIC8800D80 the combo BT bring-up
    # deterministically hangs the chip — aicbt_patch_table_load times out mid-burst
    # (cmd 1026 reqcfm, ~entry 107), and since aicbsp_driver_fw_init runs aicbt_init
    # BEFORE aicwifi_init and bails on its failure, wlan0 never comes up. The port
    # patch gates the D80 `btenable` on CONFIG_SDIO_BT, so =n skips BT entirely and
    # loads the pure-wifi fmacfw (verified: wlan0 scans on a real M28K). Flip to =y
    # only if/when the BT path is fixed.
    run make -C "${KERNEL_BUILD_DIR}" M="${drv}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
      -j"${JOBS}" \
      CONFIG_SDIO_BT=n CONFIG_AIC8800_BTLPM_SUPPORT=n \
      CONFIG_AIC_FW_PATH="\"${AIC8800_FW_DEST}\"" \
      modules
    [[ -f "${drv}/aic8800_fdrv/aic8800_fdrv.ko" ]] || fatal "aic8800_fdrv.ko not built."
    [[ -f "${drv}/aic8800_bsp/aic8800_bsp.ko" ]] || fatal "aic8800_bsp.ko not built."
    log "AIC8800 modules built: aic8800_bsp.ko, aic8800_fdrv.ko (BT-over-SDIO included)."
  else
    # USB (ROCK 5C AIC8800D80): the parent dir builds both aic_load_fw (firmware
    # loader) and aic8800_fdrv (the Wi-Fi driver).
    section "Building AIC8800 Wi-Fi modules (USB: aic_load_fw + aic8800_fdrv)"
    run make -C "${KERNEL_BUILD_DIR}" M="${drv}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
      -j"${JOBS}" modules
    [[ -f "${drv}/aic8800_fdrv/aic8800_fdrv.ko" ]] || fatal "aic8800_fdrv.ko (USB) not built."
    [[ -f "${drv}/aic_load_fw/aic_load_fw.ko" ]] || fatal "aic_load_fw.ko not built."
    log "AIC8800 USB modules built: aic_load_fw.ko, aic8800_fdrv.ko."
  fi
}

# Install modules + firmware + modules-load.d into the rootfs.
aic8800_install() {
  section "Installing AIC8800 modules + firmware into rootfs (${AIC8800_BUS})"
  local drv="${AIC8800_DIR}/${AIC8800_DRV_SUBDIR}"
  local krel; krel="$(make -s -C "${KERNEL_BUILD_DIR}" kernelrelease)"
  [[ -n "${krel}" ]] || fatal "Could not resolve kernel release for module install."

  # Out-of-tree modules into the rootfs module tree, then depmod.
  if [[ "${AIC8800_BUS}" == "sdio" ]]; then
    run_sudo make -C "${KERNEL_BUILD_DIR}" M="${drv}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
      INSTALL_MOD_PATH="${MOUNTPOINT_ROOT}" \
      CONFIG_SDIO_BT=n CONFIG_AIC8800_BTLPM_SUPPORT=n \
      modules_install
  else
    run_sudo make -C "${KERNEL_BUILD_DIR}" M="${drv}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
      INSTALL_MOD_PATH="${MOUNTPOINT_ROOT}" \
      modules_install
  fi
  run_sudo depmod -b "${MOUNTPOINT_ROOT}" "${krel}"

  # Firmware blobs into the dest the driver searches.
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}${AIC8800_FW_DEST}"
  local fwdirs d
  if [[ "${AIC8800_BUS}" == "usb" ]]; then
    # AIC8800D80 USB: driver loads fmacfw_8800d80*/fw_patch_8800d80* from
    # /lib/firmware/aic8800D80. Copy the generic + D80 sets (D80 last = wins).
    fwdirs=("aic8800" "aic8800D80")
  else
    # SDIO: all variants, driver auto-selects by chip id.
    fwdirs=()
    for d in "${AIC8800_DIR}/${AIC8800_FW_SUBDIR}"/*/; do fwdirs+=("$(basename "${d}")"); done
  fi
  for d in "${fwdirs[@]}"; do
    [[ -d "${AIC8800_DIR}/${AIC8800_FW_SUBDIR}/${d}" ]] || continue
    run_sudo cp -a "${AIC8800_DIR}/${AIC8800_FW_SUBDIR}/${d}/"* "${MOUNTPOINT_ROOT}${AIC8800_FW_DEST}/" 2>/dev/null || true
  done

  # Autoload on boot.
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/modules-load.d"
  if [[ "${AIC8800_BUS}" == "sdio" ]]; then
    printf 'aic8800_bsp\naic8800_fdrv\n' | run_sudo tee "${MOUNTPOINT_ROOT}/etc/modules-load.d/aic8800.conf" >/dev/null
  else
    printf 'aic_load_fw\naic8800_fdrv\n' | run_sudo tee "${MOUNTPOINT_ROOT}/etc/modules-load.d/aic8800.conf" >/dev/null
  fi
  log "AIC8800 modules installed for kernel ${krel}; firmware in ${AIC8800_FW_DEST}."
}

# Online Wi-Fi/BT userspace (wpa_supplicant, bluez). Sets WIFI_USERSPACE_OK.
aic8800_install_userspace() {
  section "Installing Wi-Fi/BT userspace online (wpa_supplicant, bluez)"
  if ! distro_install_pkgs "${WIFI_USERSPACE_PACKAGES}"; then
    warn "Online install of Wi-Fi/BT userspace failed (no network?). Driver+firmware are still in the image; install '${WIFI_USERSPACE_PACKAGES}' after boot."
    WIFI_USERSPACE_OK=0
    return 0
  fi
  WIFI_USERSPACE_OK=1
  log "Wi-Fi/BT userspace installed."
}

# wpa_supplicant credential template + wlan0 stanza + service enablement, all via
# distro primitives so the board layer stays distro-agnostic.
aic8800_configure_runtime() {
  section "Configuring Wi-Fi/BT (credential template + services)"
  # wpa_supplicant credential template (user fills SSID/PSK on first boot).
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/wpa_supplicant"
  run_sudo cp "${RESOURCES_DIR}/rootfs/etc/wpa_supplicant/wpa_supplicant.conf" \
    "${MOUNTPOINT_ROOT}/etc/wpa_supplicant/wpa_supplicant.conf"
  distro_add_wifi_iface
  [[ "${WIFI_USERSPACE_OK:-0}" == "1" ]] && distro_enable_services "wpa_supplicant bluetooth"
  return 0
}
