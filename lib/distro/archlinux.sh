#!/usr/bin/env bash
# lib/distro/archlinux.sh — Arch Linux ARM distro plugin (pacman + systemd).
# Same distro_* contract as lib/distro/alpine.sh.
#
# Tuned to the real ArchLinuxARM-aarch64 generic rootfs (inspected): base already
# ships bash, pacman, systemd, openssh (sshd ENABLED), e2fsprogs (resize2fs),
# tzdata, agetty, and a working /etc/pacman.d/mirrorlist; systemd-networkd +
# systemd-timesyncd are pre-enabled and it ships /etc/systemd/network/{eth,en}.network
# (DHCP). So the build does offline-only setup and QUEUES the few online extras
# (mesa, wifi, growpart) + the rootfs grow into one first-boot systemd oneshot.
#
# shellcheck disable=SC2034

# shellcheck source=common/systemd.sh
source "${LIB_DIR}/distro/common/systemd.sh"

ARCH_ROOTFS_URL="${ARCH_ROOTFS_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
GPU_USERSPACE_PACKAGES="${GPU_USERSPACE_PACKAGES:-mesa}"
WIFI_USERSPACE_PACKAGES="${WIFI_USERSPACE_PACKAGES:-wpa_supplicant iw bluez bluez-utils}"
DISTRO_PRETTY="${DISTRO_PRETTY:-Arch Linux}"
# The full ALARM rootfs is ~2.5-3 GB uncompressed (extracted before the slim strip
# runs), so the build image needs room for it. Sparse + xz + first-boot resize make
# the larger size almost free in the final .img.xz. FULL_FIRMWARE keeps the whole
# linux-firmware pool (~1 GB+), so size up further.
if [[ "${FULL_FIRMWARE}" == "1" ]]; then
  DISTRO_IMAGE_SIZE="${DISTRO_IMAGE_SIZE:-6G}"
else
  DISTRO_IMAGE_SIZE="${DISTRO_IMAGE_SIZE:-4G}"
fi

ARCH_FIRSTBOOT_PKGS=""
ARCH_FIRSTBOOT_SERVICES=""
ARCH_ROOTFS_TARBALL=""

# Lean image (default on): we boot our own mainline kernel and ship each board's
# firmware per-board, so the ALARM stock kernel, the initramfs generator and the
# desktop/x86 firmware blobs (amdgpu/nvidia/radeon/intel-GPU+wifi/cirrus-audio —
# ~4500 useless files on RK35xx/H618) are stripped. ARM-relevant Wi-Fi/BT firmware
# (mediatek/realtek/atheros/broadcom/qca) is kept for plug-in USB dongles. Set
# ARCH_SLIM=0 to keep the full stock ALARM userspace.
ARCH_SLIM="${ARCH_SLIM:-1}"
# Initialize the pacman keyring at build time (qemu chroot) so the image is ready
# to pacman on first login. Set 0 to defer keyring init to first boot instead.
ARCH_BUILD_KEYRING="${ARCH_BUILD_KEYRING:-1}"
# Remove the ENTIRE linux-firmware pool (default). We boot our own kernel and ship
# each board's firmware separately (Mali CSF + AIC8800, added after the strip), so
# linux-firmware is only useful for plug-in USB Wi-Fi/BT dongles — one
# `pacman -S linux-firmware` away. Set ARCH_STRIP_ALL_FW=0 to keep the ARM Wi-Fi/BT
# firmware and only drop the desktop/x86 blobs in ARCH_STRIP_FW_DIRS instead.
ARCH_STRIP_ALL_FW="${ARCH_STRIP_ALL_FW:-1}"
# Desktop/x86 firmware dirs dropped when ARCH_STRIP_ALL_FW=0 (the conservative mode).
ARCH_STRIP_FW_DIRS="${ARCH_STRIP_FW_DIRS:-amdgpu nvidia radeon i915 intel cirrus sdca}"
# Packages whose db records are purged on first boot (so pacman -Syu won't refetch).
# Includes the linux-firmware META (it depends on the split subpackages, so without
# removing it a -Syu would re-pull the stripped ones); the ARM-relevant subpackages
# stay installed as orphans (mediatek/realtek/atheros/broadcom/other/whence).
ARCH_PURGE_PKGS="${ARCH_PURGE_PKGS:-linux-aarch64 mkinitcpio mkinitcpio-busybox linux-firmware linux-firmware-amdgpu linux-firmware-nvidia linux-firmware-radeon linux-firmware-intel linux-firmware-cirrus}"
# FULL_FIRMWARE=1 overrides the slim firmware policy: keep the ENTIRE linux-firmware
# pool and its packages (still mask the stock ALARM kernel + mkinitcpio — we boot our
# own). The firmware byte-strip is additionally gated below.
if [[ "${FULL_FIRMWARE}" == "1" ]]; then
  ARCH_STRIP_ALL_FW=0
  ARCH_PURGE_PKGS="linux-aarch64 mkinitcpio mkinitcpio-busybox"
fi

distro_env_summary() { log "Distro: Arch Linux ARM (pacman + systemd), ${ARCH_ROOTFS_URL##*/}"; }
distro_default_fragments() { printf 'systemd\n'; }

# ------------------------------ Host payload ---------------------------------
distro_prepare() {
  section "Downloading Arch Linux ARM aarch64 rootfs"
  ARCH_ROOTFS_TARBALL="${DOWNLOAD_DIR}/$(basename "${ARCH_ROOTFS_URL}")"
  if [[ ! -s "${ARCH_ROOTFS_TARBALL}" ]]; then
    aria2_download "${ARCH_ROOTFS_URL}" "${ARCH_ROOTFS_TARBALL}.tmp"
    mv "${ARCH_ROOTFS_TARBALL}.tmp" "${ARCH_ROOTFS_TARBALL}"
  else
    log "ALARM tarball already exists: ${ARCH_ROOTFS_TARBALL}"
  fi
  have bsdtar || fatal "bsdtar (libarchive) required to extract the ALARM rootfs; install 'libarchive'."
}

# ------------------------------ Rootfs build ---------------------------------
distro_bootstrap_rootfs() {
  section "Extracting Arch Linux ARM aarch64 rootfs"
  [[ -s "${ARCH_ROOTFS_TARBALL}" ]] || fatal "ALARM tarball not ready."
  # bsdtar preserves the ALARM tarball's ownership/caps/xattrs (GNU tar mangles them).
  run_sudo bsdtar -xpf "${ARCH_ROOTFS_TARBALL}" -C "${MOUNTPOINT_ROOT}"
  run_sudo cp /usr/bin/qemu-aarch64-static "${MOUNTPOINT_ROOT}/usr/bin/qemu-aarch64-static"
  # ALARM ships its own linux-aarch64 kernel + initramfs in /boot; we boot our
  # mainline Image + dtbs + extlinux (no initramfs) instead. Drop the packaged boot
  # payload and the stale ALARM module tree...
  run_sudo rm -f "${MOUNTPOINT_ROOT}/boot/Image" "${MOUNTPOINT_ROOT}/boot/Image.gz" \
    "${MOUNTPOINT_ROOT}/boot/initramfs-linux.img" "${MOUNTPOINT_ROOT}/boot/initramfs-linux-fallback.img"
  run_sudo rm -rf "${MOUNTPOINT_ROOT}/boot/dtbs"
  run_sudo rm -rf "${MOUNTPOINT_ROOT}"/usr/lib/modules/*-ARCH

  # ...and MASK the kernel package so a first-boot `pacman -Syu` can't resurrect it
  # (which would reinstall its Image + run mkinitcpio into /boot, clobbering ours).
  # The package is also purged from the db in the first-boot oneshot below; this
  # IgnorePkg is the belt-and-braces so an early manual `pacman -Syu` is safe too.
  local pconf="${MOUNTPOINT_ROOT}/etc/pacman.conf"
  if grep -qE '^[#[:space:]]*IgnorePkg' "${pconf}" 2>/dev/null; then
    run_sudo sed -i 's|^[#[:space:]]*IgnorePkg.*|IgnorePkg = linux-aarch64|' "${pconf}"
  else
    run_sudo sed -i '/^\[options\]/a IgnorePkg = linux-aarch64' "${pconf}"
  fi
  log "Masked ALARM kernel: IgnorePkg = linux-aarch64; dropped /boot payload + *-ARCH modules."

  # Strip firmware (bytes; db records are purged at first boot). Our per-board
  # firmware (Mali CSF + AIC8800) is added AFTER this, so a full wipe is safe.
  if [[ "${FULL_FIRMWARE}" == "1" ]]; then
    log "FULL_FIRMWARE=1: keeping the entire linux-firmware pool (no firmware strip)."
  elif [[ "${ARCH_SLIM}" == "1" ]]; then
    if [[ "${ARCH_STRIP_ALL_FW}" == "1" ]]; then
      run_sudo rm -rf "${MOUNTPOINT_ROOT}/usr/lib/firmware"
      log "ARCH_SLIM: removed the entire linux-firmware pool (ARCH_STRIP_ALL_FW=1)."
    else
      local d strip
      IFS=' ' read -r -a strip <<< "${ARCH_STRIP_FW_DIRS}"   # global IFS has no space
      for d in "${strip[@]}"; do
        run_sudo rm -rf "${MOUNTPOINT_ROOT}/usr/lib/firmware/${d}"
      done
      run_sudo bash -c "rm -f '${MOUNTPOINT_ROOT}'/usr/lib/firmware/iwlwifi-*.ucode" 2>/dev/null || true
      log "ARCH_SLIM: stripped desktop firmware dirs [${ARCH_STRIP_FW_DIRS}] + iwlwifi blobs."
    fi
  fi

  _arch_init_keyring
}

# Initialize the pacman keyring at BUILD time (qemu-aarch64 chroot) so the image
# is ready to `pacman` on first login — no first-boot keyring race. Best-effort:
# the first-boot setup re-runs --init/--populate as an idempotent fallback. Set
# ARCH_BUILD_KEYRING=0 to skip (then the keyring is initialized on first boot).
_arch_init_keyring() {
  [[ "${ARCH_BUILD_KEYRING}" == "1" ]] || { log "ARCH_BUILD_KEYRING=0: keyring deferred to first boot."; return 0; }
  section "Initializing pacman keyring in rootfs (qemu chroot, best-effort)"
  local r="${MOUNTPOINT_ROOT}"
  [[ -x /usr/bin/qemu-aarch64-static ]] || { warn "qemu-aarch64-static missing; skipping build-time keyring init."; return 0; }
  # CRITICAL — bind /dev NON-recursively (--bind, not --rbind) and make it private:
  # a recursive bind copies the host's devpts/shm submounts, and unmounting them can
  # PROPAGATE back and tear down the host's /dev/pts → pty/sudo break system-wide.
  # A plain --bind exposes the device NODES gpg needs (urandom/null) without the
  # submounts; --make-private guarantees no umount ever propagates to the host. We
  # don't mount /sys (keyring doesn't need it).
  run_sudo mount -t proc proc "${r}/proc" 2>/dev/null || true
  run_sudo mount --bind /dev "${r}/dev" 2>/dev/null || true
  run_sudo mount --make-private "${r}/dev" 2>/dev/null || true
  run_sudo timeout 180 chroot "${r}" /usr/bin/pacman-key --init \
    || warn "build-time pacman-key --init failed; first boot will retry."
  run_sudo timeout 180 chroot "${r}" /usr/bin/pacman-key --populate archlinuxarm archlinux \
    || warn "build-time pacman-key --populate failed; first boot will retry."
  # pacman-key/gpg spawn gpg-agent (+ dirmngr/keyboxd) daemons whose homedir lives
  # inside the rootfs; left running they keep the mount busy. Kill them, then drop
  # the binds NON-recursively (never -R, never touches the host /dev/pts).
  run_sudo chroot "${r}" /usr/bin/gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null || true
  run_sudo pkill -f 'qemu-aarch64-static.*gpg' 2>/dev/null || true
  sleep 1
  run_sudo umount "${r}/dev" 2>/dev/null || run_sudo umount -l "${r}/dev" 2>/dev/null || true
  run_sudo umount "${r}/proc" 2>/dev/null || run_sudo umount -l "${r}/proc" 2>/dev/null || true
  run_sudo pkill -f 'qemu-aarch64-static' 2>/dev/null || true
  log "Keyring init done (or deferred to first boot)."
}

# Queue packages for the first-boot online install (returns 0 = queued).
distro_install_pkgs() {
  [[ -n "$1" ]] || return 0
  ARCH_FIRSTBOOT_PKGS+=" $1"
  log "queued for first-boot pacman: $1"
  return 0
}

# ALARM ships a working /etc/pacman.d/mirrorlist (mirror.archlinuxarm.org).
distro_write_repos() { :; }

distro_configure_time() {
  section "Configuring time sync (systemd-timesyncd) and timezone"
  # timesyncd is already enabled in the ALARM base; just point it at our NTP pool.
  local conf; conf="$(printf '%s' "${NTP_SERVERS}" | xargs)"
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/systemd"
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/systemd/timesyncd.conf" >/dev/null <<EOF
[Time]
NTP=${conf}
EOF
  log "timesyncd.conf written (NTP: ${conf})"
  # tzdata ships in the base, so timezone is just a symlink.
  if [[ -n "${TIMEZONE}" && -f "${MOUNTPOINT_ROOT}/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    run_sudo ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${MOUNTPOINT_ROOT}/etc/localtime"
    log "Timezone set to ${TIMEZONE}."
  fi
}

# --------------------------- Network / console -------------------------------
distro_configure_network() {
  # ALARM already ships /etc/systemd/network/{eth,en}.network (DHCP on all wired
  # NICs), which covers e20c/m28k dual-gigabit too — nothing to add for wired.
  log "Network: using ALARM's shipped systemd-networkd eth/en DHCP config."
}

distro_add_wifi_iface() {
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/systemd/network"
  # wlan DHCP once associated; harmless while unconfigured (stays down, no boot block).
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/systemd/network/25-wireless.network" >/dev/null <<'EOF'
[Match]
Name=wl*

[Network]
DHCP=yes
IgnoreCarrierLoss=3s
EOF
}

distro_configure_console() {
  section "Enabling systemd serial console (serial-getty@${SERIAL_CONSOLE})"
  systemd_enable_serial_getty
  # pam_securetty gates root login per-tty; ALARM's securetty lists ttyS0 but not
  # e.g. ttyS2 (ROCK 5C), so add our console if missing or root serial login fails.
  local st="${MOUNTPOINT_ROOT}/etc/securetty"
  if [[ -f "${st}" ]] && ! grep -qx "${SERIAL_CONSOLE}" "${st}"; then
    printf '%s\n' "${SERIAL_CONSOLE}" | run_sudo tee -a "${st}" >/dev/null
    log "Added ${SERIAL_CONSOLE} to /etc/securetty (root serial login)."
  fi
}

# ------------------------------ Services -------------------------------------
# sshd, systemd-networkd and systemd-timesyncd are already enabled in the ALARM
# base, so the base set is a no-op here.
distro_enable_base_services() { log "Base services (sshd/networkd/timesyncd) already enabled in ALARM base."; }

distro_enable_services() {
  # Enable now if the unit already exists; otherwise queue for first boot (after
  # its package is installed). Maps bare names → *.service.
  local svc unit list
  IFS=' ' read -r -a list <<< "$1"     # global IFS has no space
  for svc in "${list[@]}"; do
    unit="${svc}.service"
    if systemd_enable_unit "${unit}"; then
      log "Enabled service: ${unit}"
    else
      ARCH_FIRSTBOOT_SERVICES+=" ${unit}"
      log "queued service for first boot: ${unit}"
    fi
  done
}

distro_install_oneshot() { :; }   # Arch routes one-shots through distro_finalize.

distro_adapt_local_d() { systemd_adapt_local_d; }

distro_install_resize_service() {
  [[ "${AUTO_RESIZE}" == "1" ]] || { log "AUTO_RESIZE=0; skipping first-boot rootfs expansion."; return 0; }
  # No package needed: sfdisk (util-linux) + resize2fs (e2fsprogs) ship in the ALARM base.
  systemd_install_rootfs_grow
}

# --------------------------- First-boot oneshots -----------------------------
distro_finalize() {
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/usr/local/sbin" \
    "${MOUNTPOINT_ROOT}/etc/systemd/system/multi-user.target.wants"

  # Network setup: keyring (fallback) + pacman extras + service enables.
  section "Installing first-boot network setup oneshot (pacman extras + services)"
  local pkgs services purge
  pkgs="$(printf '%s' "${ARCH_FIRSTBOOT_PKGS}" | xargs -n1 2>/dev/null | sort -u | xargs)"
  services="$(printf '%s' "${ARCH_FIRSTBOOT_SERVICES}" | xargs -n1 2>/dev/null | sort -u | xargs)"
  purge="linux-aarch64"
  [[ "${ARCH_SLIM}" == "1" ]] && purge="${ARCH_PURGE_PKGS}"

  run_sudo tee "${MOUNTPOINT_ROOT}/usr/local/sbin/firstboot-setup" >/dev/null <<FBEOF
#!/bin/bash
# First-boot network setup: keyring (already done at build, idempotent fallback),
# purge the stock kernel/firmware from the db, install queued extras, enable queued
# services, then disable itself. Best-effort (needs network).
set -u
flag=/var/lib/misc/.firstboot-done
[ -f "\$flag" ] && exit 0
mkdir -p /var/lib/misc
STRIP_ALL_FW="${ARCH_STRIP_ALL_FW}"

# Keyring was initialized at build time; re-run only if it's somehow empty.
pacman-key --list-keys >/dev/null 2>&1 || { pacman-key --init || true; pacman-key --populate archlinuxarm archlinux || true; }

# Drop the stock kernel (+ initramfs/desktop firmware) records; files were already
# stripped at build time, so this just keeps -Syu from re-pulling them.
pacman -Rdd --noconfirm ${purge} 2>/dev/null || true
if [ "\$STRIP_ALL_FW" = "1" ]; then
  pacman -Rdd --noconfirm \$(pacman -Qq 2>/dev/null | grep -E '^linux-firmware') 2>/dev/null || true
fi

pacman -Sy --noconfirm || true
PKGS="${pkgs}"
[ -n "\$PKGS" ] && pacman -S --needed --noconfirm \$PKGS || true

SVCS="${services}"
for s in \$SVCS; do systemctl enable "\$s" 2>/dev/null || true; done

: > "\$flag"
systemctl disable firstboot-setup.service 2>/dev/null || true
exit 0
FBEOF
  run_sudo chmod +x "${MOUNTPOINT_ROOT}/usr/local/sbin/firstboot-setup"

  run_sudo tee "${MOUNTPOINT_ROOT}/usr/lib/systemd/system/firstboot-setup.service" >/dev/null <<'EOF'
[Unit]
Description=First-boot network setup (pacman extras, services)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/misc/.firstboot-done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot-setup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemd_enable_unit firstboot-setup.service
  log "First-boot queued: net pkgs=[${pkgs:-none}] services=[${services:-none}]"
}
