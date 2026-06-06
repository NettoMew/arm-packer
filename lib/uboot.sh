#!/usr/bin/env bash
# lib/uboot.sh — mainline U-Boot build. Vendor-dispatched make args + output
# assertion (rockchip: BL31/ROCKCHIP_TPL → u-boot-rockchip.bin; allwinner:
# BL31/SCP=/dev/null → u-boot-sunxi-with-spl.bin). BL31 for allwinner is built
# first by vendor_build_firmware (a no-op on rockchip).

build_uboot() {
  section "Building mainline U-Boot (${BOARD}, ${UBOOT_DEFCONFIG})"
  pushd "${UBOOT_DIR}" >/dev/null || fatal "U-Boot dir missing: ${UBOOT_DIR}"
  run make mrproper
  run make "${UBOOT_DEFCONFIG}"
  local -a vargs
  mapfile -t vargs < <(vendor_uboot_make_args)
  run make -j"${JOBS}" CROSS_COMPILE=aarch64-linux-gnu- "${vargs[@]}"
  popd >/dev/null || true
  vendor_uboot_output
}
