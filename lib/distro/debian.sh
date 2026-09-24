#!/usr/bin/env bash
# lib/distro/debian.sh — minimal Debian distro plugin (apt + systemd + ifupdown).
# Same distro_* contract as lib/distro/alpine.sh / archlinux.sh / eweos.sh.
#
# mmdebstrap bootstraps the rootfs straight into the freshly formatted root
# partition: the "apt" variant (Essential + apt) plus a short explicit package
# list, with no Recommends, no kernel and no initramfs. Its package set already
# includes the -updates and -security archives, so the image ships patched. The
# dpkg path filter (resources/debian/dpkg.cfg) governs the bootstrap itself and
# stays in the image for every later install; resources/debian/rootfs is laid
# over the empty target before the first package unpacks.
#
# Choices the plugin makes, each checked against a real trixie bootstrap:
#   - /etc/machine-id stays empty, the Debian image convention. systemd then never
#     treats a boot as the first one, so neither the interactive systemd-firstboot
#     wizard nor a preset-all (which would enable systemd-networkd next to
#     ifupdown) ever runs. SSH host keys are generated on the board because their
#     absence is the trigger (overlay drop-in for sshd-keygen.service).
#   - Wired ports are "allow-hotplug": udev raises each one through ifup@.service,
#     so DHCP never runs inside networking.service and an unplugged cable never
#     holds the boot. dhcpcd-base is trixie's DHCP client for ifupdown.
#   - Interfaces keep their kernel names (eth0, wlan0) like every other distro
#     here; the predictable names (end0, ...) remain as altnames.
#   - Every package is installed at build time; the first boot needs no network.
#
# The plugin tracks Debian stable releases (trixie onwards): each suite is paired
# with its -updates and -security archives.
#
# shellcheck disable=SC2034  # some vars are consumed by sourced engine modules.

# shellcheck source=common/systemd.sh
source "${LIB_DIR}/distro/common/systemd.sh"

DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"
DEBIAN_SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-https://security.debian.org/debian-security}"
DEBIAN_COMPONENTS="${DEBIAN_COMPONENTS:-main non-free-firmware}"
# Keyring mmdebstrap verifies the archive with on the build host. The image names
# its own copy (same path, from debian-archive-keyring) in its sources file.
DEBIAN_KEYRING="${DEBIAN_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
DEBIAN_TARGET_KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
# The whole userspace beyond Essential + apt. fdisk (sfdisk) and e2fsprogs
# (resize2fs) serve the first-boot grow; nothing here pulls in dbus.
DEBIAN_PACKAGES="${DEBIAN_PACKAGES:-systemd systemd-sysv udev kmod ifupdown dhcpcd-base iproute2 netbase openssh-server systemd-timesyncd fdisk e2fsprogs tzdata ca-certificates}"
DEBIAN_EXTRA_PACKAGES="${DEBIAN_EXTRA_PACKAGES:-}"
# FULL_FIRMWARE=1: the firmware pool for plug-in GPUs, Wi-Fi and BT dongles.
DEBIAN_FIRMWARE_PACKAGES="${DEBIAN_FIRMWARE_PACKAGES:-firmware-linux-free firmware-linux-nonfree firmware-realtek firmware-atheros firmware-brcm80211 firmware-mediatek firmware-iwlwifi firmware-libertas}"
# Periodic jobs that suit a long-lived apt-managed server; on a flashed SBC they
# only wake the storage. fstrim.timer stays: SD cards and eMMC benefit from it.
DEBIAN_MASKED_UNITS="${DEBIAN_MASKED_UNITS:-apt-daily.timer apt-daily-upgrade.timer dpkg-db-backup.timer e2scrub_all.timer e2scrub_reap.service}"

# Headless by default: Debian's Mesa drags in libLLVM (~100 MB). Opt in with e.g.
# GPU_USERSPACE_PACKAGES="libgl1-mesa-dri libegl1 libgles2 libgbm1".
GPU_USERSPACE_PACKAGES="${GPU_USERSPACE_PACKAGES:-}"
# Bluetooth (bluez) needs dbus, so it is left out; add it here to opt in.
WIFI_USERSPACE_PACKAGES="${WIFI_USERSPACE_PACKAGES:-wpasupplicant iw}"
DISTRO_PRETTY="${DISTRO_PRETTY:-Debian}"
# The userspace is ~170 MB and the stripped distro-grade modules ~250 MB, but
# modules_install copies each module unstripped before stripping it (amdgpu alone
# is hundreds of MB), so 1G overflows. The image is sparse, xz-packed and grown
# on first boot, so the headroom costs nothing in the .img.xz.
if [[ "${FULL_FIRMWARE}" == "1" ]]; then
  DISTRO_IMAGE_SIZE="${DISTRO_IMAGE_SIZE:-3G}"
else
  DISTRO_IMAGE_SIZE="${DISTRO_IMAGE_SIZE:-2G}"
fi

DEBIAN_RESOURCES="${RESOURCES_DIR}/debian"
DEBIAN_SOURCES_FILE=""   # rendered by distro_prepare
DEBIAN_APT_UPDATED=0

distro_env_summary() { log "Distro: Debian ${DEBIAN_SUITE} (apt + systemd + ifupdown), mirror ${DEBIAN_MIRROR}"; }
distro_default_fragments() { printf 'systemd\n'; }

# ------------------------------ Helpers --------------------------------------
# The archive as a deb822 sources file, signed by KEYRING.
_debian_render_sources() {
  local keyring="$1"
  cat <<EOF
Types: deb
URIs: ${DEBIAN_MIRROR}
Suites: ${DEBIAN_SUITE} ${DEBIAN_SUITE}-updates
Components: ${DEBIAN_COMPONENTS}
Signed-By: ${keyring}

Types: deb
URIs: ${DEBIAN_SECURITY_MIRROR}
Suites: ${DEBIAN_SUITE}-security
Components: ${DEBIAN_COMPONENTS}
Signed-By: ${keyring}
EOF
}

# Run a command inside the rootfs in a private mount namespace. /proc, a
# NON-recursive /dev bind and the host's resolver live only as long as the
# command: nothing can outlive it or propagate back to the host, the host's devpts
# is never bound (see CLAUDE.md on --rbind), and the host's resolv.conf never
# lands in the image. Needs no qemu copy: foreign hosts use binfmt (F flag).
_debian_chroot() {
  # shellcheck disable=SC2016  # expanded by the inner shell, not here.
  run_sudo unshare --mount --propagation private -- /bin/sh -euc '
    root="$1"; shift
    mount -t proc proc "${root}/proc"
    mount --bind /dev "${root}/dev"
    touch "${root}/etc/resolv.conf"
    mount --bind /etc/resolv.conf "${root}/etc/resolv.conf"
    exec chroot "${root}" /usr/bin/env DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 "$@"
  ' sh "${MOUNTPOINT_ROOT}" "$@"
}

# ------------------------------ Host payload ---------------------------------
distro_prepare() {
  section "Preparing the Debian ${DEBIAN_SUITE} bootstrap"
  have mmdebstrap || fatal "DISTRO=debian needs mmdebstrap (Debian/Ubuntu: apt install mmdebstrap; Arch: AUR mmdebstrap)."
  [[ -r "${DEBIAN_KEYRING}" ]] || fatal "Debian archive keyring missing: ${DEBIAN_KEYRING} (install debian-archive-keyring)."
  DEBIAN_SOURCES_FILE="${BUILD_DIR}/debian.sources"
  _debian_render_sources "${DEBIAN_KEYRING}" > "${DEBIAN_SOURCES_FILE}"
  log "$(mmdebstrap --version); archive: ${DEBIAN_MIRROR} + ${DEBIAN_SECURITY_MIRROR}"
}

# ------------------------------ Rootfs build ---------------------------------
distro_bootstrap_rootfs() {
  section "Bootstrapping Debian ${DEBIAN_SUITE} rootfs (mmdebstrap)"
  [[ -s "${DEBIAN_SOURCES_FILE}" ]] || fatal "Debian sources not rendered; distro_prepare did not run."
  local -a packages
  IFS=' ' read -r -a packages <<< "${DEBIAN_PACKAGES} ${DEBIAN_EXTRA_PACKAGES}"   # global IFS has no space
  local include overlay
  include="$(IFS=,; printf '%s' "${packages[*]}")"
  # The overlay takes its modes from the umask and root ownership, never from the
  # checkout it was copied from.
  # shellcheck disable=SC2016  # "$1" is the target path mmdebstrap hands the hook.
  printf -v overlay 'cp -rT --no-preserve=mode,ownership -- %q "$1"' "${DEBIAN_RESOURCES}/rootfs"

  # --mode=unshare runs every chroot step in mmdebstrap's own mount namespace,
  # also when started as root. The target may hold only the empty lost+found.
  run_sudo mmdebstrap --mode=unshare --variant=apt --architectures=arm64 \
    --dpkgopt="${DEBIAN_RESOURCES}/dpkg.cfg" --aptopt="${DEBIAN_RESOURCES}/apt.conf" \
    --include="${include}" --setup-hook="${overlay}" \
    "${DEBIAN_SUITE}" "${MOUNTPOINT_ROOT}" "${DEBIAN_SOURCES_FILE}"

  # Build-time installs and the running board read the same sources file.
  run_sudo rm -f "${MOUNTPOINT_ROOT}"/etc/apt/sources.list.d/*.sources "${MOUNTPOINT_ROOT}/etc/apt/sources.list"
  _debian_render_sources "${DEBIAN_TARGET_KEYRING}" \
    | run_sudo tee "${MOUNTPOINT_ROOT}/etc/apt/sources.list.d/debian.sources" >/dev/null
  log "Debian ${DEBIAN_SUITE}: $(run_sudo chroot "${MOUNTPOINT_ROOT}" dpkg-query -W -f='.' | wc -c) packages installed."
}

# Build-time install inside the target (returns nonzero on failure; callers warn).
distro_install_pkgs() {
  local -a pkgs
  IFS=' ' read -r -a pkgs <<< "$1"
  ((${#pkgs[@]} > 0)) || return 0
  if [[ "${DEBIAN_APT_UPDATED}" != "1" ]]; then
    _debian_chroot apt-get update || return 1
    DEBIAN_APT_UPDATED=1
  fi
  _debian_chroot apt-get install --yes "${pkgs[@]}"
}

# The sources file is written right after the bootstrap, because the build-time
# installs above already read it.
distro_write_repos() { :; }

distro_configure_time() {
  section "Configuring time sync (systemd-timesyncd) and timezone"
  # A drop-in, so the packaged timesyncd.conf stays pristine for upgrades.
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/systemd/timesyncd.conf.d"
  printf '[Time]\nNTP=%s\n' "${NTP_SERVERS}" \
    | run_sudo tee "${MOUNTPOINT_ROOT}/etc/systemd/timesyncd.conf.d/arm-packer.conf" >/dev/null
  log "timesyncd NTP: ${NTP_SERVERS}"
  [[ -n "${TIMEZONE}" ]] || return 0
  if [[ -f "${MOUNTPOINT_ROOT}/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    run_sudo ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${MOUNTPOINT_ROOT}/etc/localtime"
    log "Timezone set to ${TIMEZONE}."
  else
    warn "Zoneinfo for ${TIMEZONE} not found; leaving UTC."
  fi
}

# --------------------------- Network / console -------------------------------
distro_configure_network() {
  section "Configuring ifupdown (${BOARD_NICS} wired port(s), DHCP)"
  local i
  {
    printf '# Wired ports come up as udev announces them (allow-hotplug), so DHCP\n'
    printf '# never delays the boot and an unplugged cable costs nothing.\n'
    printf 'source /etc/network/interfaces.d/*\n\nauto lo\niface lo inet loopback\n'
    for (( i = 0; i < BOARD_NICS; i++ )); do
      printf '\nallow-hotplug eth%d\niface eth%d inet dhcp\n' "${i}" "${i}"
    done
  } | run_sudo tee "${MOUNTPOINT_ROOT}/etc/network/interfaces" >/dev/null

  run_sudo tee "${MOUNTPOINT_ROOT}/etc/hosts" >/dev/null <<EOF
127.0.0.1	localhost
127.0.1.1	${IMAGE_HOSTNAME}
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF
}

distro_add_wifi_iface() {
  # wpasupplicant's ifupdown hook starts wpa_supplicant for the interface itself.
  grep -q 'iface wlan0' "${MOUNTPOINT_ROOT}/etc/network/interfaces" 2>/dev/null && return 0
  run_sudo tee -a "${MOUNTPOINT_ROOT}/etc/network/interfaces" >/dev/null <<'EOF'

# Wi-Fi: fill in /etc/wpa_supplicant/wpa_supplicant.conf, then `ifup wlan0`
# (or change the line below to "allow-hotplug wlan0" to join at boot).
iface wlan0 inet dhcp
	wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF
}

distro_configure_console() {
  section "Enabling systemd serial console (serial-getty@${SERIAL_CONSOLE})"
  systemd_enable_serial_getty
}

# ------------------------------ Services -------------------------------------
# Package maintainer scripts enable ssh, networking and timesyncd; re-linking them
# is idempotent and states the image's contract. The masked units never run.
distro_enable_base_services() {
  section "Pinning the Debian service set"
  systemd_enable_unit ssh.service || fatal "ssh.service missing from the Debian rootfs."
  systemd_enable_unit networking.service || fatal "networking.service missing from the Debian rootfs."
  systemd_enable_unit systemd-timesyncd.service sysinit.target || fatal "systemd-timesyncd.service missing from the Debian rootfs."
  local -a masked
  IFS=' ' read -r -a masked <<< "${DEBIAN_MASKED_UNITS}"
  systemd_mask_units "${masked[@]}"
  log "Masked: ${DEBIAN_MASKED_UNITS}"
}

distro_enable_services() {
  local -a list
  IFS=' ' read -r -a list <<< "$1"     # global IFS has no space
  local svc
  for svc in "${list[@]}"; do
    case "${svc}" in
      wpa_supplicant)
        log "wpa_supplicant: started per interface by ifupdown (wpa-conf); no daemon to enable." ;;
      *)
        if systemd_enable_unit "${svc}.service"; then
          log "Enabled service: ${svc}.service"
        else
          warn "Service not installed (will not autostart): ${svc}.service"
        fi ;;
    esac
  done
}

distro_install_oneshot() { :; }   # nothing in the Debian flow needs one.

distro_adapt_local_d() { systemd_adapt_local_d; }

distro_install_resize_service() {
  [[ "${AUTO_RESIZE}" == "1" ]] || { log "AUTO_RESIZE=0; skipping first-boot rootfs expansion."; return 0; }
  systemd_install_rootfs_grow
}

# ------------------------------ Wrap-up --------------------------------------
distro_finalize() {
  if [[ "${FULL_FIRMWARE}" == "1" ]]; then
    section "Installing the Debian firmware pool (FULL_FIRMWARE=1)"
    distro_install_pkgs "${DEBIAN_FIRMWARE_PACKAGES}" \
      || warn "Firmware install failed; 'apt install ${DEBIAN_FIRMWARE_PACKAGES}' after boot."
  fi

  section "Sealing the Debian rootfs"
  local r="${MOUNTPOINT_ROOT}"
  # Per-board identity is created on the board, never baked into the image.
  run_sudo rm -f "${r}"/etc/ssh/ssh_host_*
  run_sudo truncate -s 0 "${r}/etc/machine-id"
  run_sudo rm -f "${r}/var/lib/dbus/machine-id"
  # The build host's resolver must not leak; dhcpcd rewrites the file on the board.
  run_sudo rm -f "${r}/etc/resolv.conf"
  run_sudo install -m 0644 /dev/null "${r}/etc/resolv.conf"
  # Package indexes and downloaded .debs are rebuilt on demand by apt.
  run_sudo find "${r}/var/lib/apt/lists" "${r}/var/cache/apt" -type f -delete
  log "Host keys, machine-id, resolver and apt caches cleared."
}
