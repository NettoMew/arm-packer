#!/usr/bin/env bash
# lib/image.sh — disk image: allocate, partition (vendor layout), write bootloader
# (vendor), loop-attach, format, mount, finalize, compress.
#
# The vendor declares the partitions (vendor_partition_layout), one per line:
#   NAME SIZE FSTYPE MOUNTPOINT
# SIZE is an IEC size (512M) or "rest" for the remainder; exactly one partition
# mounts at "/" and at most one takes "rest", and it comes last. IMAGE_SIZE is the
# root filesystem's budget: every sized partition grows the image by its own size,
# so a board with an ESP gets the same root space as one without.
#
# shellcheck disable=SC2034  # ESP_MOUNT is read by the boot scheme (lib/boot/uefi.sh).

PART_NAMES=(); PART_SIZES=(); PART_FS=(); PART_MOUNTS=()

load_partition_layout() {
  PART_NAMES=(); PART_SIZES=(); PART_FS=(); PART_MOUNTS=(); ROOT_PART=""; ESP_MOUNT=""
  local name size fs mnt
  while IFS=' ' read -r name size fs mnt; do
    [[ -n "${name}" ]] || continue
    (( ${#PART_SIZES[@]} == 0 )) || [[ "${PART_SIZES[-1]}" != rest ]] \
      || fatal "Partition layout: only the last partition may take the rest."
    PART_NAMES+=("${name}"); PART_SIZES+=("${size}"); PART_FS+=("${fs}"); PART_MOUNTS+=("${mnt}")
    [[ "${mnt}" == / ]] && ROOT_PART="${#PART_NAMES[@]}"
    [[ "${name}" == esp ]] && ESP_MOUNT="${mnt}"
  done < <(vendor_partition_layout)
  [[ -n "${ROOT_PART}" ]] || fatal "Partition layout has no root (/) partition."
}

# One line per partition, for the dry run and the build log.
describe_partition_layout() {
  local i
  for i in "${!PART_NAMES[@]}"; do
    printf 'p%d %s %s %s %s\n' "$((i + 1))" "${PART_NAMES[i]}" "${PART_SIZES[i]}" "${PART_FS[i]}" "${PART_MOUNTS[i]}"
  done
}

make_empty_image_and_partition() {
  section "Creating and partitioning firmware image"
  load_partition_layout
  mkdir -p "${OUTPUT_DIR}"
  rm -f "${IMAGE_PATH}"
  log "Allocating ${IMAGE_SIZE} image (root budget): ${IMAGE_PATH}"
  run dd if=/dev/zero of="${IMAGE_PATH}" bs=1 count=0 seek="${IMAGE_SIZE}"
  local i
  for i in "${!PART_NAMES[@]}"; do
    [[ "${PART_SIZES[i]}" == rest ]] || run truncate -s "+${PART_SIZES[i]}" "${IMAGE_PATH}"
  done

  local table; table="$(vendor_partition_table)"
  log "Creating ${table} label; first partition at sector ${ROOTFS_PART_START_SECTOR}"
  run_sudo parted -s "${IMAGE_PATH}" mklabel "${table}"
  local start="${ROOTFS_PART_START_SECTOR}" n end label fs
  for i in "${!PART_NAMES[@]}"; do
    n=$((i + 1))
    # msdos takes a partition type here, gpt a partition name.
    [[ "${table}" == msdos ]] && label=primary || label="${PART_NAMES[i]}"
    case "${PART_FS[i]}" in vfat) fs=fat32 ;; *) fs="${PART_FS[i]}" ;; esac
    if [[ "${PART_SIZES[i]}" == rest ]]; then
      end=100%
    else
      end="$((start + $(numfmt --from=iec "${PART_SIZES[i]}") / 512 - 1))s"
    fi
    run_sudo parted -s "${IMAGE_PATH}" unit s mkpart "${label}" "${fs}" "${start}s" "${end}"
    [[ "${PART_NAMES[i]}" == esp && "${table}" == gpt ]] && run_sudo parted -s "${IMAGE_PATH}" set "${n}" esp on
    [[ "${end}" == 100% ]] || start=$(( ${end%s} + 1 ))
  done
  # MBR (Allwinner) marks the rootfs partition bootable; GPT does not.
  [[ "${table}" == "msdos" ]] && run_sudo parted -s "${IMAGE_PATH}" set "${ROOT_PART}" boot on
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

# partition_partuuid N — the PARTUUID of partition N of the attached image.
partition_partuuid() {
  local n="$1" part="${LOOPDEV}p$1" uuid=""
  wait_for_partition_metadata "${part}" || true
  uuid="$(run_sudo blkid -s PARTUUID -o value "${part}" 2>/dev/null || true)"
  if [[ -z "${uuid}" ]]; then
    uuid="$(run_sudo lsblk -no PARTUUID "${part}" 2>/dev/null | awk 'NF {print $1; exit}' || true)"
  fi
  if [[ -z "${uuid}" ]]; then
    uuid="$(run_sudo sfdisk --part-uuid "${LOOPDEV}" "${n}" 2>/dev/null || true)"
  fi
  if [[ -z "${uuid}" ]]; then
    warn "PARTUUID lookup failed; diagnostics follow."
    run_sudo blkid "${LOOPDEV}" "${part}" || true
    run_sudo lsblk -o NAME,PATH,FSTYPE,LABEL,UUID,PARTUUID "${LOOPDEV}" || true
    run_sudo sfdisk -d "${LOOPDEV}" || true
    fatal "Could not read PARTUUID from ${part}"
  fi
  printf '%s\n' "${uuid}"
}

read_root_partuuid() {
  ROOT_PARTUUID="$(partition_partuuid "${ROOT_PART}")"
  log "Root PARTUUID: ${ROOT_PARTUUID}"
}

attach_loop() {
  section "Attaching loop device"
  require_root_capability
  LOOPDEV="$(run_sudo losetup --find --show -P "${IMAGE_PATH}")"
  log "Loop device: ${LOOPDEV}"
  local n
  for n in $(seq 1 "${#PART_NAMES[@]}"); do
    wait_for_partition_metadata "${LOOPDEV}p${n}" || fatal "Partition node did not appear: ${LOOPDEV}p${n}"
  done
}

format_partitions() {
  section "Formatting partitions"
  local i part
  for i in "${!PART_NAMES[@]}"; do
    part="${LOOPDEV}p$((i + 1))"
    case "${PART_FS[i]}" in
      ext4)
        local -a mkfs_features=()
        [[ -z "${ROOTFS_EXT4_FEATURES:-}" ]] || mkfs_features=(-O "${ROOTFS_EXT4_FEATURES}")
        log "mkfs.ext4 ${part} label=${ROOTFS_LABEL}${ROOTFS_EXT4_FEATURES:+ features=${ROOTFS_EXT4_FEATURES}}"
        run_sudo mkfs.ext4 -F -L "${ROOTFS_LABEL}" "${mkfs_features[@]}" "${part}" ;;
      vfat)
        run_sudo mkfs.vfat -F 32 -n "${PART_NAMES[i]^^}" "${part}" ;;
      *) fatal "Unsupported filesystem in partition layout: ${PART_FS[i]}" ;;
    esac
  done
  read_root_partuuid
}

mount_root_partition() {
  section "Mounting root partition"
  MOUNTPOINT_ROOT="${WORKSPACE}/mnt-root"
  mkdir -p "${MOUNTPOINT_ROOT}"
  run_sudo mount "${LOOPDEV}p${ROOT_PART}" "${MOUNTPOINT_ROOT}"
}

# The other partitions mount once the distro has laid down the rootfs: some
# bootstrappers (mmdebstrap) insist on an empty target directory.
mount_boot_partitions() {
  local i
  for i in "${!PART_NAMES[@]}"; do
    [[ "${PART_MOUNTS[i]}" == / ]] && continue
    run_sudo mkdir -p "${MOUNTPOINT_ROOT}${PART_MOUNTS[i]}"
    run_sudo mount "${LOOPDEV}p$((i + 1))" "${MOUNTPOINT_ROOT}${PART_MOUNTS[i]}"
  done
}

unmount_boot_partitions() {
  local i
  for (( i = ${#PART_NAMES[@]} - 1; i >= 0; i-- )); do
    [[ "${PART_MOUNTS[i]}" == / ]] && continue
    if mountpoint -q "${MOUNTPOINT_ROOT}${PART_MOUNTS[i]}"; then
      run_sudo umount "${MOUNTPOINT_ROOT}${PART_MOUNTS[i]}"
    fi
  done
}

finalize_image() {
  section "Finalizing image"
  run_sudo sync
  unmount_boot_partitions
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
