#!/usr/bin/env bash
# boards/dragon-q8b/hooks.sh — Radxa Dragon Q8B board hooks.
#
# The board is not in mainline yet: its DTS, the TC956x 2.5 GbE driver, the
# CH7218A HDMI bridge and a set of display, PCI and thermal fixes come as one
# patch series, taken from Armbian's tested sc8280xp-edge series and refreshed
# for this kernel (see linux/README.md for provenance). The series also builds
# the EL2 DTB the image boots and the driver for the fan service on the ADSP;
# the board firmware starts the DSPs before the kernel attaches to them. The
# M.2 Wi-Fi card uses the in-tree iwlwifi driver and the shared Wi-Fi
# userspace (lib/wifi.sh).

board_inject_kernel_sources() {
  section "Applying Dragon Q8B kernel series"
  local p count=0
  for p in "${BOARD_ASSETS}/dragon-q8b/linux/patches/"*.patch; do
    git -C "${KERNEL_SRC_DIR}" apply "${p}" || fatal "Kernel patch failed to apply: $(basename "${p}")"
    count=$((count + 1))
  done
  log "Applied ${count} patches."
}

# Full-image path; kernel validation calls board_inject_kernel_sources directly.
board_inject_sources()    { board_inject_kernel_sources; }

board_install_userspace() { wifi_install_userspace; }
board_configure_runtime() { wifi_configure_runtime; }
