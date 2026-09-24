#!/usr/bin/env bash
# lib/vendor/allwinner.sh — Allwinner boot-chain plugin (no closed blobs).
#
# H616/H618 DRAM init is open source in the U-Boot SPL and BL31 is built from
# upstream arm-trusted-firmware (PLAT=sun50i_h616), yielding
# u-boot-sunxi-with-spl.bin written at 8 KiB on an MBR disk. Defines the same
# vendor_* contract as lib/vendor/rockchip.sh.
#
# shellcheck disable=SC2034  # BL31_BIN/TPL_BIN are engine globals (no rkbin pair here).

# shellcheck source=../boot/uboot.sh
source "${LIB_DIR}/boot/uboot.sh"

ATF_REPO="${ATF_REPO:-${DEFAULT_ATF_REPO}}"
ATF_REF="${ATF_REF:-${DEFAULT_ATF_REF}}"
ATF_PLAT="${ATF_PLAT:-sun50i_h616}"
ATF_DIR="${SRC_DIR}/arm-trusted-firmware"
ATF_BL31_BIN="${ATF_DIR}/build/${ATF_PLAT}/release/bl31.bin"
# u-boot-sunxi-with-spl.bin is written at 8 KiB (sunxi BROM contract); the rootfs
# starts at sector 32768 (16 MiB), well clear of it.
SPL_SEEK_KIB="${SPL_SEEK_KIB:-8}"

vendor_required_keys() { uboot_required_keys; }

# Allwinner builds BL31 from source, so there is no rkbin blob pair.
vendor_select_blobs() { BL31_BIN=""; TPL_BIN=""; }

vendor_default_fragments() {
  case "${BOARD_SOC}" in
    h618) printf 'allwinner-h618\n' ;;
    *) fatal "Unknown allwinner BOARD_SOC=${BOARD_SOC}" ;;
  esac
}

vendor_fetch_extra() {
  uboot_fetch
  git_clone_or_update "${ATF_REPO}" "${ATF_REF}" "${ATF_DIR}"
}
vendor_fetch_assert_skip() {
  uboot_assert_fetched
  [[ -d "${ATF_DIR}/.git" ]] || fatal "SKIP_FETCH=1 but ATF tree missing: ${ATF_DIR}"
}
vendor_assert_sources() { uboot_assert_defconfig; }

# BL31 from upstream arm-trusted-firmware, then U-Boot around it. The
# open-source SPL handles DRAM init (no ROCKCHIP_TPL); SCP=/dev/null skips the
# optional crust SCP firmware.
vendor_build_bootloader() {
  section "Building ARM Trusted Firmware BL31 (PLAT=${ATF_PLAT})"
  run make -C "${ATF_DIR}" CROSS_COMPILE=aarch64-linux-gnu- PLAT="${ATF_PLAT}" DEBUG=0 -j"${JOBS}" bl31
  [[ -f "${ATF_BL31_BIN}" ]] || fatal "BL31 not generated: ${ATF_BL31_BIN}"
  log "BL31: ${ATF_BL31_BIN}"
  uboot_build "BL31=${ATF_BL31_BIN}" "SCP=/dev/null"
  [[ -f "${UBOOT_DIR}/u-boot-sunxi-with-spl.bin" ]] || fatal "U-Boot output missing: u-boot-sunxi-with-spl.bin"
  log "U-Boot sunxi image: ${UBOOT_DIR}/u-boot-sunxi-with-spl.bin"
}

# MBR (msdos), NOT GPT: the SPL sits at 8 KiB and would clobber the GPT
# partition-entry array (LBA 2..33 = 1..17 KiB). MBR lives only in LBA0.
vendor_partition_table()  { printf 'msdos\n'; }
vendor_partition_layout() { printf 'root rest ext4 /\n'; }

vendor_write_bootloader() {
  section "Writing u-boot-sunxi-with-spl.bin at ${SPL_SEEK_KIB} KiB"
  run dd if="${UBOOT_DIR}/u-boot-sunxi-with-spl.bin" of="${IMAGE_PATH}" bs=1024 seek="${SPL_SEEK_KIB}" conv=notrunc status=progress
  sync
}

vendor_install_boot() { boot_install_extlinux; }

vendor_firmware_extras() { return 0; }

vendor_env_summary() {
  uboot_env_summary
  log "BL31: ${ATF_REPO} @ ${ATF_REF} (PLAT=${ATF_PLAT}, built from source)"
}
