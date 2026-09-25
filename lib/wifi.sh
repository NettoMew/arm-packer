#!/usr/bin/env bash
# lib/wifi.sh — Wi-Fi/Bluetooth userspace, shared by every board with a radio,
# whatever its driver (AIC8800 out of tree, iwlwifi in tree). The package list,
# the service names and the wlan0 stanza are distro primitives
# (WIFI_USERSPACE_PACKAGES, distro_enable_services, distro_add_wifi_iface), so
# this layer is distro-agnostic. Boards wire their install_userspace and
# configure_runtime hooks to these two helpers.

# Online Wi-Fi/BT userspace (wpa_supplicant and friends). Sets WIFI_USERSPACE_OK.
wifi_install_userspace() {
  section "Installing Wi-Fi/BT userspace online (${WIFI_USERSPACE_PACKAGES})"
  if ! distro_install_pkgs "${WIFI_USERSPACE_PACKAGES}"; then
    warn "Online install of Wi-Fi/BT userspace failed (no network?). Driver+firmware are still in the image; install '${WIFI_USERSPACE_PACKAGES}' after boot."
    WIFI_USERSPACE_OK=0
    return 0
  fi
  WIFI_USERSPACE_OK=1
  log "Wi-Fi/BT userspace installed."
}

# wpa_supplicant credential template + wlan0 stanza + service enablement. Must run
# after the base network is written (the wlan0 stanza appends to it).
wifi_configure_runtime() {
  section "Configuring Wi-Fi/BT (credential template + services)"
  # wpa_supplicant credential template (user fills SSID/PSK on first boot).
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/wpa_supplicant"
  run_sudo cp "${RESOURCES_DIR}/rootfs/etc/wpa_supplicant/wpa_supplicant.conf" \
    "${MOUNTPOINT_ROOT}/etc/wpa_supplicant/wpa_supplicant.conf"
  distro_add_wifi_iface
  [[ "${WIFI_USERSPACE_OK:-0}" == "1" ]] && distro_enable_services "wpa_supplicant bluetooth"
  return 0
}
