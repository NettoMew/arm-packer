#!/usr/bin/env bash
# lib/pipeline.sh — environment summary, board-hook dispatch, and the build
# pipeline (the old main()). Vendor differences go through vendor_* and
# board-specific extras through board_hook, so this stays a flat list of phases.

# Call board_<name> if the loaded boards/<board>/hooks.sh defines it; else no-op.
board_hook() {
  local fn="board_$1"; shift
  if declare -F "${fn}" >/dev/null; then "${fn}" "$@"; fi
  return 0
}

print_environment_summary() {
  section "Host environment summary"
  log "Target board: ${BOARD}"
  log "Project directory: ${PROJECT_DIR}"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log "OS: ${PRETTY_NAME:-unknown}"
  fi
  log "Kernel: $(uname -srmo)"
  log "CPU jobs: ${JOBS}"
  log "Workspace: ${WORKSPACE}"
  log "Output image: ${OUTPUT_DIR}/${IMAGE_NAME:-${IMAGE_NAME_PREFIX}-<kernelversion>.img} (finalized after fetch)"
  log "Vendor/SoC: ${BOARD_VENDOR}/${BOARD_SOC}"
  distro_env_summary
  vendor_env_summary
  log "Linux: ${KERNEL_REPO} @ ${KERNEL_REF} (${KERNEL_DEFCONFIG}, ${KERNEL_DTB})"
  log "Console: ${SERIAL_CONSOLE},${SERIAL_BAUD}n8"
}

run_pipeline() {
  print_environment_summary
  swupdate_preflight
  install_dependencies
  prepare_workspace
  distro_prepare                 # host-side payload + tooling (apk.static / rootfs tarball)
  fetch_sources
  if [[ "${SKIP_BUILD}" == "1" ]]; then
    section "SKIP_BUILD=1: reusing existing bootloader + kernel artifacts"
    [[ -f "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image" ]] || fatal "SKIP_BUILD=1 but kernel Image missing — build once for this board first."
    [[ -f "${KERNEL_BUILD_DIR}/arch/arm64/boot/dts/${KERNEL_DTB}" ]] || fatal "SKIP_BUILD=1 but kernel DTB missing (${KERNEL_DTB}) — last build was a different board?"
  else
    vendor_build_bootloader      # U-Boot (+ ATF on Allwinner); nothing on UEFI boards
    build_kernel
    if [[ "${STOP_AFTER_KCONFIG:-0}" == "1" ]]; then
      section "STOP_AFTER_KCONFIG=1: stopping after kernel .config (no image built)"
      return 0
    fi
  fi
  board_hook build_modules       # out-of-tree drivers (e.g. AIC8800; incremental)
  make_empty_image_and_partition
  write_bootloader_to_image
  attach_loop
  format_partitions
  mount_root_partition
  populate_rootfs
  finalize_image
  compress_image

  section "Done"
  if [[ "${COMPRESS_IMAGE}" == "1" && -f "${IMAGE_PATH}.xz" ]]; then
    log "Firmware image: ${IMAGE_PATH}.xz (select directly in balenaEtcher)"
    log "To write to removable media (verify the target device!): xz -dc '${IMAGE_PATH}.xz' | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress"
  else
    log "Firmware image: ${IMAGE_PATH}"
    log "To write to removable media (verify the target device!): sudo dd if='${IMAGE_PATH}' of=/dev/sdX bs=4M conv=fsync status=progress"
  fi
}
