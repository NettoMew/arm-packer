#!/usr/bin/env bash
# lib/boot/uefi.sh — the UEFI + systemd-boot boot scheme, for boards whose own
# firmware is a UEFI implementation (e.g. Qualcomm boards with an EDK2 in SPI
# NOR). Nothing is compiled and nothing is written to raw disk sectors: the
# firmware finds \EFI\BOOT\BOOTAA64.EFI on the ESP, systemd-boot reads a Boot
# Loader Specification entry, and the kernel boots through its EFI stub.
#
# systemd-boot is taken from Debian's systemd-boot-efi package, pinned by version
# and SHA-256 in config/versions.conf. Only the single EFI binary is used, so the
# scheme works the same under every distro plugin.
#
# The kernel and DTB live on the ESP (systemd-boot reads FAT only), under a
# per-version directory so that a later kernel can sit beside this one.

SYSTEMD_BOOT_EFI=""   # set by uefi_fetch_systemd_boot

# Download (cached by checksum) and unpack systemd-bootaa64.efi. The URLs are
# tried in order; the Debian pool drops superseded versions, the snapshot
# archive keeps them forever, and the checksum is the same for both.
uefi_fetch_systemd_boot() {
  local deb="${DOWNLOAD_DIR}/systemd-boot-efi_${SYSTEMD_BOOT_VERSION}_arm64.deb"
  local -a urls
  IFS=' ' read -r -a urls <<< "${SYSTEMD_BOOT_URLS}"   # global IFS has no space
  if ! sha256_matches "${deb}" "${SYSTEMD_BOOT_SHA256}"; then
    section "Fetching systemd-boot ${SYSTEMD_BOOT_VERSION}"
    local url
    for url in "${urls[@]}"; do
      aria2_download "${url}" "${deb}.tmp" && sha256_matches "${deb}.tmp" "${SYSTEMD_BOOT_SHA256}" \
        && { mv -f "${deb}.tmp" "${deb}"; break; }
      warn "systemd-boot download failed or checksum mismatch: ${url}"
    done
    sha256_matches "${deb}" "${SYSTEMD_BOOT_SHA256}" || fatal "No verified systemd-boot ${SYSTEMD_BOOT_VERSION} package."
  fi
  local work="${BUILD_DIR}/systemd-boot" member
  rm -rf "${work}"; mkdir -p "${work}"
  member="$(cd "${work}" && ar t "${deb}" | grep '^data\.tar')" || fatal "No data member in ${deb}"
  (cd "${work}" && ar x "${deb}" "${member}" && tar -xf "${member}" ./usr/lib/systemd/boot/efi/systemd-bootaa64.efi) \
    || fatal "systemd-bootaa64.efi missing from ${deb}"
  SYSTEMD_BOOT_EFI="${work}/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
  log "systemd-boot: ${SYSTEMD_BOOT_EFI} (${SYSTEMD_BOOT_VERSION})"
}

# BOARD_BOOT_VARIANTS="NAME=DTB ..." adds loader entries that boot the same
# kernel with the same command line but another DTB, e.g. one the firmware reads
# as "start the OS at EL2". Parsed into UEFI_BOOT_VARIANTS ("NAME DTB" each).
UEFI_BOOT_VARIANTS=()
uefi_parse_boot_variants() {
  UEFI_BOOT_VARIANTS=()
  local -a pairs
  IFS=' ' read -r -a pairs <<< "${BOARD_BOOT_VARIANTS:-}"   # global IFS has no space
  local pair
  for pair in "${pairs[@]}"; do
    [[ "${pair}" =~ ^([a-z0-9]+)=([^=]+\.dtb)$ ]] || fatal "BOARD_BOOT_VARIANTS: expected NAME=path/to/board.dtb, got '${pair}'"
    UEFI_BOOT_VARIANTS+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}")
  done
}

uefi_env_summary() {
  log "boot: board UEFI firmware → systemd-boot ${SYSTEMD_BOOT_VERSION} (ESP, Boot Loader Specification)"
  uefi_parse_boot_variants
  local v
  for v in "${UEFI_BOOT_VARIANTS[@]}"; do
    log "boot variant: ${v% *} (${v#* })"
  done
}

# One BLS entry: ID, the label in the title's parentheses, and the DTB it boots.
bls_write_entry() {
  local id="$1" label="$2" dtb="$3"
  local esp="${MOUNTPOINT_ROOT}${ESP_MOUNT}" kdir="arm-packer/${RESOLVED_KERNEL_VERSION}"
  run_sudo tee "${esp}/loader/entries/${id}.conf" >/dev/null <<EOF
title      ${DISTRO_PRETTY:-Linux} ${RESOLVED_KERNEL_VERSION} (${label})
version    ${RESOLVED_KERNEL_VERSION}
linux      /${kdir}/Image
devicetree /${kdir}/dtbs/${dtb}
options    $(kernel_cmdline)
EOF
  log "Loader entry: ${id}.conf (${dtb})"
}

# Kernel, DTBs, systemd-boot and the BLS entries onto the ESP. The plain entry
# is the default; variants are picked from the menu (or made the default in
# loader.conf).
boot_install_bls() {
  section "Installing systemd-boot, kernel and loader entries on the ESP"
  [[ -f "${SYSTEMD_BOOT_EFI}" ]] || uefi_fetch_systemd_boot
  local esp="${MOUNTPOINT_ROOT}${ESP_MOUNT:?no ESP in the partition layout}"
  local ver="${RESOLVED_KERNEL_VERSION}" kdir="arm-packer/${RESOLVED_KERNEL_VERSION}"
  local dtbs="${KERNEL_BUILD_DIR}/arch/arm64/boot/dts"
  mountpoint -q "${esp}" || fatal "ESP is not mounted at ${esp}"
  uefi_parse_boot_variants

  run_sudo install -D -m 0644 "${SYSTEMD_BOOT_EFI}" "${esp}/EFI/BOOT/BOOTAA64.EFI"
  run_sudo install -D -m 0644 "${SYSTEMD_BOOT_EFI}" "${esp}/EFI/systemd/systemd-bootaa64.efi"
  run_sudo install -D -m 0644 "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image" "${esp}/${kdir}/Image"
  run_sudo install -D -m 0644 "${dtbs}/${KERNEL_DTB}" "${esp}/${kdir}/dtbs/${KERNEL_DTB}"

  run_sudo mkdir -p "${esp}/loader/entries"
  run_sudo tee "${esp}/loader/loader.conf" >/dev/null <<EOF
default arm-packer-${ver}.conf
timeout 3
console-mode keep
EOF
  bls_write_entry "arm-packer-${ver}" "${BOARD_MENU_TITLE}" "${KERNEL_DTB}"

  local v name dtb
  for v in "${UEFI_BOOT_VARIANTS[@]}"; do
    name="${v% *}" dtb="${v#* }"
    [[ -f "${dtbs}/${dtb}" ]] || fatal "Boot variant ${name}: ${dtb} was not built"
    run_sudo install -D -m 0644 "${dtbs}/${dtb}" "${esp}/${kdir}/dtbs/${dtb}"
    bls_write_entry "arm-packer-${ver}-${name}" "${BOARD_MENU_TITLE}, ${name^^}" "${dtb}"
  done
}
