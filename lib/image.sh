#!/usr/bin/env bash
# lib/image.sh — disk image: allocate, partition (vendor table), write bootloader
# (vendor), loop-attach, format, mount, finalize, compress.

make_empty_image_and_partition() {
  section "Creating and partitioning firmware image"
  mkdir -p "${OUTPUT_DIR}"
  rm -f "${IMAGE_PATH}"
  log "Allocating ${IMAGE_SIZE} image: ${IMAGE_PATH}"
  run dd if=/dev/zero of="${IMAGE_PATH}" bs=1 count=0 seek="${IMAGE_SIZE}"

  local table; table="$(vendor_partition_table)"
  log "Creating ${table} with root partition starting at sector ${ROOTFS_PART_START_SECTOR}"
  run_sudo parted -s "${IMAGE_PATH}" mklabel "${table}"
  run_sudo parted -s "${IMAGE_PATH}" unit s mkpart primary ext4 "${ROOTFS_PART_START_SECTOR}" 100%
  # MBR (Allwinner) marks the rootfs partition bootable; GPT (Rockchip) does not.
  [[ "${table}" == "msdos" ]] && run_sudo parted -s "${IMAGE_PATH}" set 1 boot on
  run_sudo parted -s "${IMAGE_PATH}" print
}

write_bootloader_to_image() {
  vendor_write_bootloader
}

wait_for_partition_metadata() {
  local part="$1"
  for _ in {1..30}; do
    run_sudo partprobe "${LOOPDEV}" || true
    run_sudo udevadm settle || true
    if [[ -b "${part}" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

read_root_partuuid() {
  local part="${LOOPDEV}p1"
  local uuid=""

  wait_for_partition_metadata "${part}" || true

  uuid="$(run_sudo blkid -s PARTUUID -o value "${part}" 2>/dev/null || true)"
  if [[ -z "${uuid}" ]]; then
    uuid="$(run_sudo lsblk -no PARTUUID "${part}" 2>/dev/null | awk 'NF {print $1; exit}' || true)"
  fi
  if [[ -z "${uuid}" ]]; then
    uuid="$(run_sudo sfdisk --part-uuid "${LOOPDEV}" 1 2>/dev/null || true)"
  fi
  if [[ -z "${uuid}" ]]; then
    warn "PARTUUID lookup failed; diagnostics follow."
    run_sudo blkid "${LOOPDEV}" "${part}" || true
    run_sudo lsblk -o NAME,PATH,FSTYPE,LABEL,UUID,PARTUUID "${LOOPDEV}" || true
    run_sudo sfdisk -d "${LOOPDEV}" || true
    fatal "Could not read PARTUUID from ${part}"
  fi

  ROOT_PARTUUID="${uuid}"
  log "Root PARTUUID: ${ROOT_PARTUUID}"
}

attach_loop() {
  section "Attaching loop device"
  require_root_capability
  LOOPDEV="$(run_sudo losetup --find --show -P "${IMAGE_PATH}")"
  log "Loop device: ${LOOPDEV}"

  local part="${LOOPDEV}p1"
  wait_for_partition_metadata "${part}" || fatal "Partition node did not appear: ${part}"
}

format_root_partition() {
  section "Formatting root partition"
  local part="${LOOPDEV}p1"
  local -a mkfs_features=()

  if [[ -n "${ROOTFS_EXT4_FEATURES:-}" ]]; then
    mkfs_features=(-O "${ROOTFS_EXT4_FEATURES}")
    log "mkfs.ext4 ${part} label=${ROOTFS_LABEL} features=${ROOTFS_EXT4_FEATURES}"
  else
    log "mkfs.ext4 ${part} label=${ROOTFS_LABEL}"
  fi

  run_sudo mkfs.ext4 -F -L "${ROOTFS_LABEL}" "${mkfs_features[@]}" "${part}"
  read_root_partuuid
}

mount_root_partition() {
  section "Mounting root partition"
  MOUNTPOINT_ROOT="${WORKSPACE}/mnt-root"
  mkdir -p "${MOUNTPOINT_ROOT}"
  run_sudo mount "${LOOPDEV}p1" "${MOUNTPOINT_ROOT}"
}

finalize_image() {
  section "Finalizing image"
  run_sudo sync
  if mountpoint -q "${MOUNTPOINT_ROOT}"; then
    if ! run_sudo umount "${MOUNTPOINT_ROOT}" 2>/dev/null; then
      warn "Root umount busy; killing stray rootfs holders (e.g. qemu gpg-agent) and retrying."
      run_sudo pkill -f 'qemu-aarch64-static' 2>/dev/null || true
      run_sudo fuser -km "${MOUNTPOINT_ROOT}" 2>/dev/null || true
      sleep 2; run_sudo sync
      run_sudo umount "${MOUNTPOINT_ROOT}" || fatal "Root partition still busy after retry: ${MOUNTPOINT_ROOT}"
    fi
  fi
  if [[ -n "${LOOPDEV}" ]]; then
    run_sudo losetup -d "${LOOPDEV}"
    LOOPDEV=""
  fi
  log "Image ready: ${IMAGE_PATH}"
  run ls -lh "${IMAGE_PATH}"
}

compress_image() (
  [[ "${COMPRESS_IMAGE}" == "1" ]] || { log "Image compression disabled (COMPRESS_IMAGE=0)."; return 0; }
  section "Compressing image to .xz (balenaEtcher compatible)"
  command -v xz >/dev/null 2>&1 || fatal "xz is required for image packaging; raw .img retained."
  local out="${IMAGE_PATH}.xz" tmp
  tmp="$(mktemp "${out}.tmp.XXXXXX")" || fatal "Could not create temporary XZ output."
  # Subshell-local cleanup: don't replace the build's mount/loop cleanup trap.
  trap 'rm -f -- "${tmp}"' EXIT
  # Standard XZ/LZMA2 + CRC64; preset 6 needs only an 8 MiB decode dictionary.
  # Keep the raw image and any previous package until compression AND testing pass.
  if ! run xz --format=xz --check=crc64 -T0 -6 --stdout -- "${IMAGE_PATH}" > "${tmp}"; then
    fatal "XZ compression failed; raw image and previous package retained."
  fi
  if ! run xz --format=xz --test -- "${tmp}"; then
    fatal "XZ integrity check failed; raw image and previous package retained."
  fi
  run chmod --reference="${IMAGE_PATH}" "${tmp}" || fatal "Could not preserve image permissions; raw image retained."
  run mv -f -- "${tmp}" "${out}" || fatal "Could not publish XZ package; raw image retained."
  run rm -- "${IMAGE_PATH}"
  log "Packaged: ${out} ($(du -h "${out}" | cut -f1)); raw .img removed."
  run ls -lh "${out}"
)
