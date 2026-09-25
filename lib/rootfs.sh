#!/usr/bin/env bash
# lib/rootfs.sh — distro-agnostic rootfs assembly. The userspace specifics
# (package manager, init system, network) live behind the distro_* contract
# (lib/distro/<distro>.sh); the boot scheme (kernel placement + loader config)
# behind vendor_install_boot (lib/boot/*.sh). This file owns only the parts
# shared by every distro and every boot scheme: modules, the kernel command
# line, fstab, hostname, root access, firmware and the board overlays.

populate_rootfs() {
  distro_bootstrap_rootfs
  mount_boot_partitions           # e.g. the ESP at /boot/efi

  install_kernel_modules
  install_filesystem_tools        # e.g. fsck.vfat for an ESP
  board_hook install_modules      # out-of-tree drivers (e.g. AIC8800)
  board_hook install_userspace    # online wifi/bt userspace
  install_gpu_userspace
  vendor_firmware_extras          # e.g. RK3588 Mali CSF firmware
  install_firmware_lock           # boards/<board>/firmware.lock, checksum-pinned
  install_board_files
  distro_adapt_local_d            # OpenRC /etc/local.d/*.start boot scripts → systemd units on Arch
  board_hook install_extras       # e.g. M28K OLED dashboard

  [[ -n "${ROOT_PARTUUID}" ]] || read_root_partuuid

  vendor_install_boot             # kernel + DTB + extlinux.conf or ESP loader entry
  write_fstab
  printf '%s\n' "${IMAGE_HOSTNAME}" | run_sudo tee "${MOUNTPOINT_ROOT}/etc/hostname" >/dev/null

  distro_write_repos
  distro_configure_network        # base lo/eth0 (+ eth1 if BOARD_SECOND_NIC)
  # Must run after the base network is written (the wlan0 stanza appends to it).
  board_hook configure_runtime
  distro_configure_time           # chrony (Alpine) / timesyncd (Arch) + timezone
  distro_configure_console
  distro_enable_base_services
  configure_root_access
  distro_install_resize_service
  distro_finalize                 # distro wrap-up (e.g. Arch first-boot oneshot)

  install_swupdate               # optional signed offline updater; no service

  run_sudo sync
}

# The kernel command line, identical for every boot scheme.
kernel_cmdline() {
  printf '%s\n' "root=PARTUUID=${ROOT_PARTUUID} rootwait rw console=tty1 console=${SERIAL_CONSOLE},${SERIAL_BAUD}n8 earlycon${BOARD_KERNEL_CMDLINE_EXTRA:+ ${BOARD_KERNEL_CMDLINE_EXTRA}}"
}

# fsck for the layout's vfat partitions (dosfstools), which write_fstab has
# checked before they are mounted.
install_filesystem_tools() {
  local fs
  for fs in "${PART_FS[@]}"; do
    [[ "${fs}" == vfat ]] || continue
    section "Installing dosfstools (fsck for the vfat partitions)"
    distro_install_pkgs dosfstools || fatal "Could not install dosfstools, which the vfat partitions need."
    return 0
  done
}

# Root first, then every other partition of the layout, mounted with nofail so
# that a missing one never keeps the system from booting. vfat ones are checked
# first: UEFI firmware opens the ESP for writing at every boot and leaves its
# dirty bit set, which fsck clears before Linux mounts it and complains.
write_fstab() {
  log "Writing fstab"
  {
    printf 'PARTUUID=%s / ext4 rw,noatime 0 1\n' "${ROOT_PARTUUID}"
    local i
    for i in "${!PART_NAMES[@]}"; do
      [[ "${PART_MOUNTS[i]}" == / ]] && continue
      if [[ "${PART_FS[i]}" == vfat ]]; then
        printf 'PARTUUID=%s %s vfat umask=0077,noatime,nofail 0 2\n' "$(partition_partuuid "$((i + 1))")" "${PART_MOUNTS[i]}"
      else
        printf 'PARTUUID=%s %s %s noatime,nofail 0 0\n' "$(partition_partuuid "$((i + 1))")" "${PART_MOUNTS[i]}" "${PART_FS[i]}"
      fi
    done
    printf 'devpts /dev/pts devpts gid=5,mode=620 0 0\n'
    printf 'tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0\n'
  } | run_sudo tee "${MOUNTPOINT_ROOT}/etc/fstab" >/dev/null
}

# boards/<board>/firmware.lock pins every firmware file the board needs:
#   source NAME BASE_URL
#   file   NAME PATH SHA256
#   link   LINK TARGET
# PATH is relative to /lib/firmware and to the source's BASE_URL, appended to it,
# or put in its place when the URL holds {path} (for URLs that pin by a query).
# LINK is a symlink under /lib/firmware to TARGET, which is relative to LINK's
# directory. Files are cached by checksum in DOWNLOAD_DIR, so a rebuild
# downloads nothing.
install_firmware_lock() {
  local lock="${BOARD_ASSETS}/${BOARD}/firmware.lock"
  [[ -f "${lock}" ]] || return 0
  section "Installing pinned firmware (${lock#"${PROJECT_DIR}/"})"
  local -A base=()
  local kind name path sum url cached count=0 links=0
  while IFS=' ' read -r kind name path sum; do
    case "${kind}" in
      ''|'#'*) continue ;;
      source) base["${name}"]="${path}" ;;
      file)
        [[ -n "${base[${name}]:-}" ]] || fatal "firmware.lock: unknown source '${name}' for ${path}"
        # A source URL either takes the path appended, or names its place as {path}.
        url="${base[${name}]}"
        if [[ "${url}" == *'{path}'* ]]; then url="${url//\{path\}/${path}}"; else url="${url}/${path}"; fi
        cached="${DOWNLOAD_DIR}/firmware/${sum}"
        if ! sha256_matches "${cached}" "${sum}"; then
          aria2_download "${url}" "${cached}" || fatal "Firmware download failed: ${path}"
          sha256_matches "${cached}" "${sum}" || fatal "Firmware checksum mismatch: ${path}"
        fi
        run_sudo install -D -m 0644 "${cached}" "${MOUNTPOINT_ROOT}/lib/firmware/${path}"
        count=$((count + 1)) ;;
      link)
        # link LINK TARGET, as linux-firmware's WHENCE "Link:" (TARGET relative to LINK).
        run_sudo mkdir -p "$(dirname "${MOUNTPOINT_ROOT}/lib/firmware/${name}")"
        run_sudo ln -sfn "${path}" "${MOUNTPOINT_ROOT}/lib/firmware/${name}"
        links=$((links + 1)) ;;
      *) fatal "firmware.lock: unknown directive '${kind}'" ;;
    esac
  done < "${lock}"
  log "Installed ${count} pinned firmware file(s) and ${links} link(s)."
}

install_gpu_userspace() {
  [[ -n "${GPU_USERSPACE_PACKAGES}" ]] || { log "GPU_USERSPACE_PACKAGES empty; skipping."; return 0; }
  section "Installing GPU userspace (Mesa Gallium)"
  # Kernel-side DRM driver is in-tree and autoloads; this adds the Mesa userspace
  # so GL_RENDERER becomes the real GPU instead of software.
  if ! distro_install_pkgs "${GPU_USERSPACE_PACKAGES}"; then
    warn "Online Mesa install failed (no network?). Kernel GPU still works; install later: ${GPU_USERSPACE_PACKAGES}"
    return 0
  fi
  log "Mesa GPU userspace installed."
}

install_board_files() {
  # Overlay any boards/<board>/files/ tree into the rootfs (e.g. M28K LED setup).
  # Generic: no-op when the board has no files/ dir. NOTE: such overlays may be
  # init-system flavoured (e.g. an /etc/local.d OpenRC script).
  local files_dir="${BOARD_ASSETS}/${BOARD}/files"
  [[ -d "${files_dir}" ]] || return 0
  section "Overlaying ${BOARD} rootfs files"
  run_sudo cp -a "${files_dir}/." "${MOUNTPOINT_ROOT}/"
  run_sudo chmod +x "${MOUNTPOINT_ROOT}/etc/local.d/"*.start 2>/dev/null || true
  log "Board files overlaid from ${files_dir}."
}

configure_root_access() {
  section "Configuring root password + SSH access"
  local shadow="${MOUNTPOINT_ROOT}/etc/shadow"
  if [[ ! -f "${shadow}" ]]; then
    warn "${shadow} missing; root password not set."
  elif [[ -z "${ROOT_PASSWORD}" ]]; then
    warn "ROOT_PASSWORD empty: leaving root password-less (serial-console login only)."
    run_sudo sed -i 's/^root:[^:]*:/root::/' "${shadow}"
  else
    local hash
    hash="$(openssl passwd -6 "${ROOT_PASSWORD}")" || fatal "openssl passwd failed"
    # SHA-512 crypt hashes only use [./0-9A-Za-z$]; '|' is a safe sed delimiter.
    run_sudo sed -i "s|^root:[^:]*:|root:${hash}:|" "${shadow}"
    log "Root password set (baked into image)."
  fi
  if [[ -n "${ROOT_AUTHORIZED_KEY}" ]]; then
    run_sudo mkdir -p "${MOUNTPOINT_ROOT}/root/.ssh"
    printf '%s\n' "${ROOT_AUTHORIZED_KEY}" > "${BUILD_DIR}/root_authorized_keys"
    run_sudo cp "${BUILD_DIR}/root_authorized_keys" "${MOUNTPOINT_ROOT}/root/.ssh/authorized_keys"
    run_sudo chmod 700 "${MOUNTPOINT_ROOT}/root/.ssh"
    run_sudo chmod 600 "${MOUNTPOINT_ROOT}/root/.ssh/authorized_keys"
    log "Installed root authorized_keys."
  fi
  local sshd="${MOUNTPOINT_ROOT}/etc/ssh/sshd_config"
  if [[ -f "${sshd}" ]]; then
    if grep -qE '^[# ]*PermitRootLogin' "${sshd}"; then
      run_sudo sed -i 's|^[# ]*PermitRootLogin.*|PermitRootLogin yes|' "${sshd}"
    else
      printf 'PermitRootLogin yes\n' | run_sudo tee -a "${sshd}" >/dev/null
    fi
    log "Enabled PermitRootLogin yes."
  fi
}
