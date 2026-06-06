#!/usr/bin/env bash
# lib/rootfs.sh — distro-agnostic rootfs assembly. The userspace specifics
# (package manager, init system, network) live behind the distro_* contract
# (lib/distro/<distro>.sh); this file owns only the parts shared by every distro:
# kernel Image/dtb/modules, extlinux + fstab (bootloader level), hostname, root
# access, the chrony NTP config, and the GPU/board overlays. Board extras come in
# via board_hook, vendor firmware via vendor_firmware_extras.

populate_rootfs() {
  distro_bootstrap_rootfs

  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/boot/dtbs/$(dirname "${KERNEL_DTB}")" "${MOUNTPOINT_ROOT}/boot/extlinux"
  run_sudo cp "${KERNEL_BUILD_DIR}/arch/arm64/boot/Image" "${MOUNTPOINT_ROOT}/boot/Image"
  run_sudo cp "${KERNEL_BUILD_DIR}/arch/arm64/boot/dts/${KERNEL_DTB}" "${MOUNTPOINT_ROOT}/boot/dtbs/${KERNEL_DTB}"

  install_kernel_modules
  board_hook install_modules      # out-of-tree drivers (e.g. AIC8800)
  board_hook install_userspace    # online wifi/bt userspace
  install_gpu_userspace
  vendor_firmware_extras          # e.g. RK3588 Mali CSF firmware
  install_board_files
  distro_adapt_local_d            # OpenRC /etc/local.d/*.start boot scripts → systemd units on Arch
  board_hook install_extras       # e.g. M28K OLED dashboard

  [[ -n "${ROOT_PARTUUID}" ]] || read_root_partuuid

  # extlinux.conf + fstab are bootloader/kernel level — identical across distros.
  log "Writing extlinux.conf"
  run_sudo tee "${MOUNTPOINT_ROOT}/boot/extlinux/extlinux.conf" >/dev/null <<EOF
TIMEOUT 30
DEFAULT mainline

MENU TITLE ${BOARD_MENU_TITLE} ${DISTRO_PRETTY:-Linux}

LABEL mainline
  MENU LABEL ${DISTRO_PRETTY:-Linux} mainline ${RESOLVED_KERNEL_VERSION}
  LINUX /boot/Image
  FDT /boot/dtbs/${KERNEL_DTB}
  APPEND root=PARTUUID=${ROOT_PARTUUID} rootwait rw console=tty1 console=${SERIAL_CONSOLE},${SERIAL_BAUD}n8 earlycon${BOARD_KERNEL_CMDLINE_EXTRA:+ ${BOARD_KERNEL_CMDLINE_EXTRA}}
EOF

  log "Writing fstab, hostname"
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/fstab" >/dev/null <<EOF
PARTUUID=${ROOT_PARTUUID} / ext4 rw,noatime 0 1
devpts /dev/pts devpts gid=5,mode=620 0 0
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF
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

  run_sudo sync
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
