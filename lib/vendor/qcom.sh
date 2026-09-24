#!/usr/bin/env bash
# lib/vendor/qcom.sh — Qualcomm boot-chain plugin.
#
# Qualcomm boards ship their own, signed boot chain in SPI NOR (PBL → XBL →
# TrustZone → an EDK2 UEFI), which the builder neither builds nor touches. The
# firmware boots any GPT disk with an EFI System Partition, so the image is an
# ESP plus the root filesystem, booted by systemd-boot (lib/boot/uefi.sh) with
# the board's own DTB named in the loader entry.
#
# Defines the same vendor_* contract as lib/vendor/rockchip.sh.
#
# shellcheck disable=SC2034  # BL31_BIN/TPL_BIN are engine globals (no blobs here).

# shellcheck source=../boot/uefi.sh
source "${LIB_DIR}/boot/uefi.sh"

# 512 MiB of ESP holds a few kernel versions side by side (~90 MB each).
QCOM_ESP_SIZE="${QCOM_ESP_SIZE:-512M}"

vendor_required_keys() { :; }
vendor_select_blobs()  { BL31_BIN=""; TPL_BIN=""; }

vendor_default_fragments() {
  case "${BOARD_SOC}" in
    sc8280xp) printf 'qcom-sc8280xp\n' ;;
    *) fatal "Unknown qcom BOARD_SOC=${BOARD_SOC}" ;;
  esac
}

# The only boot-chain artifact is the pinned systemd-boot binary; it is cached
# by checksum, so the SKIP_FETCH path simply reuses the same call.
vendor_fetch_extra() {
  have ar || fatal "ar (binutils) is required to unpack systemd-boot."
  uefi_fetch_systemd_boot
}
vendor_fetch_assert_skip() { vendor_fetch_extra; }
vendor_assert_sources()    { :; }

vendor_build_bootloader() { log "UEFI firmware lives on the board; no bootloader to build."; }

vendor_partition_table() { printf 'gpt\n'; }
vendor_partition_layout() {
  printf 'esp %s vfat /boot/efi\n' "${QCOM_ESP_SIZE}"
  printf 'root rest ext4 /\n'
}

vendor_write_bootloader() { :; }   # nothing lives in raw disk sectors
vendor_install_boot()     { boot_install_bls; }
vendor_firmware_extras()  { :; }   # boards pin theirs in firmware.lock

vendor_env_summary() { uefi_env_summary; }
