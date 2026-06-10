#!/usr/bin/env bash
# lib/vendor/rockchip.sh — Rockchip boot-chain plugin.
#
# Prebuilt rkbin DDR + BL31 blobs feed either mainline combined u-boot-rockchip.bin
# or a board-selected split idbloader.img + u-boot.itb flow. Sourced by
# scripts/build.sh after lib/env.sh; defines
# the vendor_* contract the engine calls (no `if vendor==…` left in lib/).

# rkbin DDR init (ROCKCHIP_TPL) + BL31 (ATF) blobs, one pair per SoC. Versions
# match the OpenWrt/immortalwrt mainline rockchip target.
RKBIN_REPO="${RKBIN_REPO:-https://github.com/rockchip-linux/rkbin.git}"
RKBIN_REF="${RKBIN_REF:-master}"
RKBIN_DIR="${SRC_DIR}/rkbin"
RK3528_BL31="${RK3528_BL31:-bin/rk35/rk3528_bl31_v1.20.elf}"
RK3528_TPL="${RK3528_TPL:-bin/rk35/rk3528_ddr_1056MHz_v1.11.bin}"
RK3588_BL31="${RK3588_BL31:-bin/rk35/rk3588_bl31_v1.51.elf}"
RK3588_TPL="${RK3588_TPL:-bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.19.bin}"

# RK3588 Mali-G610 (Panthor) CSF firmware: a single ~280 KB file from upstream
# linux-firmware (avoids the ~240 MB linux-firmware-arm package). arch10.8 matches
# the ROCK 5C's G610. Used by vendor_firmware_extras for BOARD_SOC=rk3588 only.
MALI_CSF_FW_URL="${MALI_CSF_FW_URL:-https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/arm/mali/arch10.8/mali_csffw.bin}"

# Pick the blob pair for this board's SoC. Sets the engine-global BL31_BIN/TPL_BIN.
vendor_select_blobs() {
  case "${BOARD_SOC}" in
    rk3528) BL31_BIN="${RK3528_BL31}"; TPL_BIN="${RK3528_TPL}" ;;
    rk3588) BL31_BIN="${RK3588_BL31}"; TPL_BIN="${RK3588_TPL}" ;;
    *) fatal "Unknown rockchip BOARD_SOC=${BOARD_SOC}" ;;
  esac
}

# Kernel fragments this vendor/SoC contributes (one name per line).
vendor_default_fragments() {
  printf 'rockchip\n'
  [[ "${BOARD_SOC}" == "rk3588" ]] && printf 'rk3588\n'
  return 0
}

# Fetch the extra source tree (clone path) / assert it exists (SKIP_FETCH path).
vendor_fetch_extra()      { git_clone_or_update "${RKBIN_REPO}" "${RKBIN_REF}" "${RKBIN_DIR}"; }
vendor_fetch_assert_skip(){ [[ -d "${RKBIN_DIR}" ]] || fatal "SKIP_FETCH=1 but rkbin tree missing: ${RKBIN_DIR}"; }

# Assert the blobs are present after fetch/injection.
vendor_assert_sources() {
  [[ -f "${RKBIN_DIR}/${BL31_BIN}" ]] || fatal "${BOARD_SOC} BL31 not found: ${RKBIN_DIR}/${BL31_BIN}"
  [[ -f "${RKBIN_DIR}/${TPL_BIN}" ]] || fatal "${BOARD_SOC} TPL/DDR not found: ${RKBIN_DIR}/${TPL_BIN}"
}

# BL31 is prebuilt; nothing to compile.
vendor_build_firmware() { return 0; }

# Extra `make` args fed to the U-Boot build (one per line).
vendor_uboot_make_args() {
  if [[ "${ROCKCHIP_SPL_BLOBS:-0}" == "1" ]]; then
    # Armbian's spl-blobs flow builds SPL plus the FIT payload explicitly, then
    # the board hook packs DDR+SPL into idbloader.img.  A plain `make BL31=...`
    # may stop after SPL/TPL on Radxa U-Boot, leaving no u-boot.itb to write.
    printf '%s\n'       "BL31=${RKBIN_DIR}/${BL31_BIN}"       "spl/u-boot-spl.bin"       "u-boot.dtb"       "u-boot.itb"
  else
    printf '%s\n' "BL31=${RKBIN_DIR}/${BL31_BIN}" "ROCKCHIP_TPL=${RKBIN_DIR}/${TPL_BIN}"
  fi
}

# Assert + name the U-Boot artifact.
vendor_uboot_output() {
  if [[ "${ROCKCHIP_SPL_BLOBS:-0}" == "1" ]]; then
    [[ -f "${UBOOT_DIR}/idbloader.img" && -f "${UBOOT_DIR}/u-boot.itb" ]] || fatal "U-Boot split output missing. Expected idbloader.img + u-boot.itb."
    log "U-Boot split images: idbloader.img + u-boot.itb"
  elif [[ -f "${UBOOT_DIR}/u-boot-rockchip.bin" ]]; then
    log "U-Boot combined image: ${UBOOT_DIR}/u-boot-rockchip.bin"
  elif [[ -f "${UBOOT_DIR}/idbloader.img" && -f "${UBOOT_DIR}/u-boot.itb" ]]; then
    log "U-Boot split images: idbloader.img + u-boot.itb"
  else
    fatal "U-Boot output missing. Expected u-boot-rockchip.bin or idbloader.img + u-boot.itb."
  fi
}

# Partition table label (image.sh adds the partition; boot flag only for msdos).
vendor_partition_table() { printf 'gpt\n'; }

# Write the bootloader into the image's reserved sectors.
vendor_write_bootloader() {
  section "Writing Rockchip bootloader into reserved sectors"
  if [[ "${ROCKCHIP_SPL_BLOBS:-0}" == "1" ]]; then
    [[ -f "${UBOOT_DIR}/idbloader.img" && -f "${UBOOT_DIR}/u-boot.itb" ]] || fatal "U-Boot split output missing. Expected idbloader.img + u-boot.itb."
    log "U-Boot split images: idbloader.img + u-boot.itb"
  elif [[ -f "${UBOOT_DIR}/u-boot-rockchip.bin" ]]; then
    log "Writing combined u-boot-rockchip.bin at sector ${BOOTLOADER_SEEK_SECTOR}"
    run dd if="${UBOOT_DIR}/u-boot-rockchip.bin" of="${IMAGE_PATH}" bs=512 seek="${BOOTLOADER_SEEK_SECTOR}" conv=notrunc status=progress
  else
    log "Writing idbloader.img at sector 64 and u-boot.itb at sector 16384"
    run dd if="${UBOOT_DIR}/idbloader.img" of="${IMAGE_PATH}" bs=512 seek=64 conv=notrunc status=progress
    run dd if="${UBOOT_DIR}/u-boot.itb" of="${IMAGE_PATH}" bs=512 seek=16384 conv=notrunc status=progress
  fi
  sync
}

# Extra firmware into the rootfs: RK3588 Mali-G610 (Panthor) CSF blob.
vendor_firmware_extras() {
  [[ "${BOARD_SOC}" == "rk3588" ]] || return 0
  section "Installing Mali-G610 (Panthor CSF) firmware"
  local dst="${MOUNTPOINT_ROOT}/lib/firmware/arm/mali/arch10.8"
  local tmp="${BUILD_DIR}/mali_csffw.bin"
  run_sudo mkdir -p "${dst}"
  if aria2_download "${MALI_CSF_FW_URL}" "${tmp}" && [[ -s "${tmp}" ]]; then
    run_sudo cp "${tmp}" "${dst}/mali_csffw.bin"
    log "Installed mali_csffw.bin ($(du -h "${tmp}" | cut -f1))."
  else
    warn "Could not download Mali CSF firmware; GPU (panthor) will not bind. URL: ${MALI_CSF_FW_URL}"
  fi
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/modules-load.d"
  printf 'panthor\n' | run_sudo tee "${MOUNTPOINT_ROOT}/etc/modules-load.d/panthor.conf" >/dev/null
}

# One-line boot-chain summary for the environment banner.
vendor_env_summary() {
  local layout="combined"
  [[ "${ROCKCHIP_SPL_BLOBS:-0}" == "1" ]] && layout="split-spl-blobs"
  log "Blobs: rkbin BL31=${BL31_BIN} TPL=${TPL_BIN} layout=${layout}"
}
