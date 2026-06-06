#!/usr/bin/env bash
# lib/distro/eweos.sh — eweOS distro plugin (pacman + dinit + musl/busybox).
# Same distro_* contract as lib/distro/alpine.sh / archlinux.sh.
#
# eweOS = musl libc + busybox coreutils + pacman + dinit init, rolling, aarch64
# Tier-1. pacman SigLevel=Never → NO keyring dance (unlike Arch). Bootstrap is
# Alpine-style (extract the official aarch64 rootfs tarball) then Arch-style online
# pacman, run for aarch64 in a qemu-aarch64 chroot at BUILD time so the image is
# ready (no first-boot install wait). We do NOT use eweOS's Limine / tinyramfs /
# eweOS kernel — the vendor U-Boot + extlinux + our mainline kernel (no initramfs)
# boot chain is reused unchanged; eweOS is purely the userspace axis.
#
# dinit model (verified against the real rootfs):
#   - `system` waits-for.d /usr/lib/dinit.d/boot.d  → vendor defaults
#     (getty@tty1-6, acpid, ntpd) auto-run.
#   - `boot`   waits-for.d /etc/dinit.d/boot.d       → admin enables live here.
#   So "enable a service" = symlink its definition into /etc/dinit.d/boot.d/
#   (the offline equivalent of `dinitctl enable`). dinit searches /etc/dinit.d
#   before /usr/lib/dinit.d, so a file in /etc/dinit.d/<name> overrides a vendor one.
#
# shellcheck disable=SC2034  # some vars are consumed by sourced engine modules.

# Official aarch64 rootfs tarball (NJU mirrors images; the redirector/CN mirrors
# serve the pacman repo — repo name is "main", SigLevel=Never).
EWEOS_TARBALL_URL="${EWEOS_TARBALL_URL:-https://mirrors.nju.edu.cn/eweos-images/eweos-aarch64-tarball.tar.xz}"
EWEOS_MIRRORS=(
  "https://os-repo-auto.ewe.moe/eweos/\$repo/os/\$arch"
  "https://mirrors.wsyu.edu.cn/eweos/\$repo/os/\$arch"
  "https://mirrors.sdust.edu.cn/eweos/\$repo/os/\$arch"
)
# Installed at build time (qemu chroot) so the image is ready: sshd, resize2fs for
# the first-boot grow, sudo, tzdata. base/dinit/dinit-services/busybox/musl/
# util-linux already ship in the tarball.
EWEOS_ROOTFS_PACKAGES="${EWEOS_ROOTFS_PACKAGES:-openssh e2fsprogs sudo tzdata}"

# Userspace package names (eweOS flavour). NB eweOS [main] has no iw/wireless-tools
# (wpa_supplicant alone covers STA assoc) and no zfs/docker.
GPU_USERSPACE_PACKAGES="${GPU_USERSPACE_PACKAGES:-mesa}"
WIFI_USERSPACE_PACKAGES="${WIFI_USERSPACE_PACKAGES:-wpa_supplicant}"
DISTRO_PRETTY="${DISTRO_PRETTY:-eweOS}"
# Tarball base ~167 MB; +mesa/openssh extras. FULL_FIRMWARE adds the whole
# linux-firmware pool, so size up.
if [[ "${FULL_FIRMWARE}" == "1" ]]; then
  DISTRO_IMAGE_SIZE="${DISTRO_IMAGE_SIZE:-4G}"
else
  DISTRO_IMAGE_SIZE="${DISTRO_IMAGE_SIZE:-2G}"
fi

EWEOS_TARBALL=""

distro_env_summary() { log "Distro: eweOS (pacman + dinit, musl/busybox), repo ${EWEOS_MIRRORS[0]%%/eweos*}"; }
distro_default_fragments() { :; }   # dinit/busybox/musl need no extra kernel options (no systemd)

# --------------------------- qemu chroot helpers -----------------------------
# Run a command inside the rootfs under qemu-aarch64 (binfmt). Mounts proc + a
# NON-recursive --bind /dev made private (NEVER --rbind: a recursive bind copies
# the host's devpts/shm submounts whose unmount can propagate back and tear down
# the host's /dev/pts → pty/sudo break system-wide). Mounts are scoped to EACH
# call so nothing leaks across pipeline steps or on failure.
_ewe_chroot() {
  local r="${MOUNTPOINT_ROOT}" rc=0
  run_sudo cp -f /etc/resolv.conf "${r}/etc/resolv.conf" 2>/dev/null || true
  run_sudo mount -t proc proc "${r}/proc"
  run_sudo mount --bind /dev "${r}/dev"
  run_sudo mount --make-private "${r}/dev"
  run_sudo chroot "${r}" "$@" || rc=$?
  run_sudo umount "${r}/dev"  2>/dev/null || run_sudo umount -l "${r}/dev"  2>/dev/null || true
  run_sudo umount "${r}/proc" 2>/dev/null || run_sudo umount -l "${r}/proc" 2>/dev/null || true
  return "${rc}"
}
_ewe_pacman() { _ewe_chroot /usr/bin/pacman "$@"; }

# Enable a dinit service = symlink its definition into /etc/dinit.d/boot.d/ (the
# dir the `boot` bundle waits on). Resolves the def via dinit's search order.
_ewe_enable() {
  local svc="$1" def=""
  local d
  for d in /etc/dinit.d /usr/lib/dinit.d; do
    [[ -e "${MOUNTPOINT_ROOT}${d}/${svc}" ]] && { def="${d}/${svc}"; break; }
  done
  if [[ -n "${def}" ]]; then
    run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/dinit.d/boot.d"
    run_sudo ln -sf "${def}" "${MOUNTPOINT_ROOT}/etc/dinit.d/boot.d/${svc}"
    log "enabled dinit service: ${svc}"
  else
    warn "dinit service not found (won't autostart): ${svc}"
  fi
}

# ------------------------------ Host payload ---------------------------------
distro_prepare() {
  section "Downloading eweOS aarch64 rootfs tarball"
  EWEOS_TARBALL="${DOWNLOAD_DIR}/$(basename "${EWEOS_TARBALL_URL}")"
  if [[ ! -s "${EWEOS_TARBALL}" ]]; then
    aria2_download "${EWEOS_TARBALL_URL}" "${EWEOS_TARBALL}.tmp"
    mv "${EWEOS_TARBALL}.tmp" "${EWEOS_TARBALL}"
  else
    log "eweOS tarball already exists: ${EWEOS_TARBALL}"
  fi
  # Verify sha256 (best-effort: skip if the checksum file is unavailable).
  local sum; sum="${DOWNLOAD_DIR}/$(basename "${EWEOS_TARBALL_URL}").sha256"
  if aria2_download "${EWEOS_TARBALL_URL}.sha256" "${sum}.tmp" 2>/dev/null; then
    mv "${sum}.tmp" "${sum}"
    local want got
    want="$(awk '{print $1; exit}' "${sum}")"
    got="$(sha256sum "${EWEOS_TARBALL}" | awk '{print $1}')"
    [[ -n "${want}" && "${want}" == "${got}" ]] || fatal "eweOS tarball sha256 mismatch (want ${want}, got ${got})."
    log "eweOS tarball sha256 OK."
  else
    warn "Could not fetch eweOS tarball .sha256; skipping checksum verification."
  fi
}

# ------------------------------ Rootfs build ---------------------------------
distro_bootstrap_rootfs() {
  section "Extracting eweOS aarch64 rootfs"
  [[ -s "${EWEOS_TARBALL}" ]] || fatal "eweOS tarball not ready."
  [[ -x /usr/bin/qemu-aarch64-static ]] || fatal "qemu-aarch64-static missing; install qemu-user-static(-binfmt)."
  # bsdtar preserves caps/xattrs; fall back to GNU tar (also fine as root).
  if have bsdtar; then
    run_sudo bsdtar -xpf "${EWEOS_TARBALL}" -C "${MOUNTPOINT_ROOT}"
  else
    run_sudo tar --numeric-owner -xpJf "${EWEOS_TARBALL}" -C "${MOUNTPOINT_ROOT}"
  fi
  run_sudo cp /usr/bin/qemu-aarch64-static "${MOUNTPOINT_ROOT}/usr/bin/qemu-aarch64-static"

  # Online: sync + upgrade (rolling) + install build-time essentials. Uses the
  # tarball's own mirrorlist (os-repo-auto) here; distro_write_repos rewrites it
  # to our preferred mirrors afterwards. SigLevel=Never → no keyring needed.
  section "Bootstrapping eweOS packages (qemu chroot pacman)"
  local extras; IFS=' ' read -r -a extras <<< "${EWEOS_ROOTFS_PACKAGES}"
  _ewe_pacman -Syu --needed --noconfirm "${extras[@]}" \
    || fatal "eweOS base package install failed (network? mirror down?)."
  # Pre-generate sshd host keys so sshd starts cleanly on first boot.
  _ewe_chroot /usr/bin/ssh-keygen -A 2>/dev/null \
    || warn "ssh-keygen -A failed in chroot; sshd will generate keys on first start."
}

# Online package install (best-effort; nonzero on failure, callers warn).
distro_install_pkgs() {
  local pkgs; IFS=' ' read -r -a pkgs <<< "$1"
  ((${#pkgs[@]} > 0)) || return 0
  _ewe_pacman -Sy --needed --noconfirm "${pkgs[@]}"
}

distro_write_repos() {
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/pacman.d"
  { local m; for m in "${EWEOS_MIRRORS[@]}"; do printf 'Server = %s\n' "${m}"; done; } \
    | run_sudo tee "${MOUNTPOINT_ROOT}/etc/pacman.d/mirrorlist" >/dev/null
  log "Wrote eweOS mirrorlist (${#EWEOS_MIRRORS[@]} mirrors)."
}

# ------------------------------ Time / tz ------------------------------------
distro_configure_time() {
  section "Configuring time sync (busybox ntpd) + timezone"
  # No battery RTC on these boards. busybox ntpd with our peers; this file shadows
  # the stock /usr/lib/dinit.d/ntpd (already pulled by `system` under the name ntpd).
  local s args=""; local servers=()
  IFS=' ' read -r -a servers <<< "${NTP_SERVERS}"
  ((${#servers[@]} > 0)) || servers=(ntp.aliyun.com)
  for s in "${servers[@]}"; do args+=" -p ${s}"; done
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/dinit.d"
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/dinit.d/ntpd" >/dev/null <<EOF
type = process
command = /usr/bin/ntpd -n${args}
restart = true
depends-on: rc.target
depends-on: network.target
before: login.target
EOF
  log "ntpd (busybox) servers:${args}"
  distro_set_timezone
}

distro_set_timezone() {
  [[ -n "${TIMEZONE}" ]] || return 0
  if [[ -f "${MOUNTPOINT_ROOT}/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    run_sudo ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${MOUNTPOINT_ROOT}/etc/localtime"
    log "Timezone → ${TIMEZONE}"
  else
    warn "zoneinfo for ${TIMEZONE} missing (tzdata not installed?); leaving UTC."
  fi
}

# --------------------------- Network / console -------------------------------
distro_configure_network() {
  # Generic all-DHCP, no role split: a dinit scripted service brings up every real
  # wired NIC and backgrounds busybox udhcpc on it — robust across NIC naming
  # (eth*/end*/enp*s*) and BOARD_NICS count. Wireless is skipped here (see
  # distro_add_wifi_iface).
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/usr/local/sbin" "${MOUNTPOINT_ROOT}/etc/dinit.d"
  run_sudo tee "${MOUNTPOINT_ROOT}/usr/local/sbin/eweos-netup" >/dev/null <<'EOF'
#!/bin/sh
# Bring up + DHCP every wired NIC (skip lo, virtual ifaces, and wireless).
for n in /sys/class/net/*; do
	i=${n##*/}
	[ "$i" = lo ] && continue
	[ -e "$n/device" ] || continue
	[ -e "$n/wireless" ] || [ -e "$n/phy80211" ] && continue
	ip link set "$i" up 2>/dev/null || continue
	udhcpc -i "$i" -b -t 6 -T 2 -A 5 2>/dev/null || true
done
exit 0
EOF
  run_sudo chmod +x "${MOUNTPOINT_ROOT}/usr/local/sbin/eweos-netup"
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/dinit.d/eweos-net" >/dev/null <<'EOF'
type = scripted
command = /usr/local/sbin/eweos-netup
depends-on: rc.target
EOF
  log "Wired DHCP via eweos-net (all NICs, BOARD_NICS=${BOARD_NICS})."
}

distro_add_wifi_iface() {
  # Template only (not enabled): configure wpa_supplicant.conf then
  # `dinitctl enable wlan` (or symlink into /etc/dinit.d/boot.d). wpa_supplicant
  # comes from WIFI_USERSPACE_PACKAGES (installed by the board's userspace hook).
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/wpa_supplicant" "${MOUNTPOINT_ROOT}/etc/dinit.d"
  if [[ -f "${RESOURCES_DIR}/rootfs/etc/wpa_supplicant/wpa_supplicant.conf" \
        && ! -f "${MOUNTPOINT_ROOT}/etc/wpa_supplicant/wpa_supplicant.conf" ]]; then
    run_sudo cp "${RESOURCES_DIR}/rootfs/etc/wpa_supplicant/wpa_supplicant.conf" \
      "${MOUNTPOINT_ROOT}/etc/wpa_supplicant/wpa_supplicant.conf"
  fi
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/dinit.d/wlan" >/dev/null <<'EOF'
# Wi-Fi (AIC8800): set /etc/wpa_supplicant/wpa_supplicant.conf, then enable:
#   ln -s /etc/dinit.d/wlan /etc/dinit.d/boot.d/wlan   (or: dinitctl enable wlan)
type = scripted
command = /bin/sh -c 'wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf && udhcpc -i wlan0 -b'
depends-on: rc.target
EOF
}

distro_configure_console() {
  section "Configuring eweOS dinit serial console (agetty @ ${SERIAL_BAUD})"
  # eweOS's stock getty@ template hardcodes 115200; our serial runs at SERIAL_BAUD
  # (e.g. 1500000), so install a dedicated agetty service at the right baud and
  # enable it. The kernel console=${SERIAL_CONSOLE},${SERIAL_BAUD} is set in
  # extlinux.conf (engine). Vendor getty@tty1-6 (HDMI/VT) stay auto-enabled.
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/dinit.d"
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/dinit.d/serial-getty" >/dev/null <<EOF
type = process
command = /sbin/agetty ${SERIAL_CONSOLE} ${SERIAL_BAUD} vt100
restart = true
termsignal = HUP
smooth-recovery = true
depends-on: rc.target
before: login.target
EOF
  _ewe_enable serial-getty
}

# ------------------------------ Services -------------------------------------
distro_enable_base_services() {
  section "Enabling base dinit services"
  # syslogd + our wired-net + sshd + serial-getty + hostname. ntpd is shadowed via
  # /etc/dinit.d/ntpd and auto-pulled by `system`; getty@tty1-6/acpid are vendor
  # defaults (auto). sshd ships with openssh (installed in bootstrap).
  local svc
  for svc in syslogd eweos-net sshd early-hostname; do
    _ewe_enable "${svc}"
  done
}

distro_enable_services() {
  local svc list
  IFS=' ' read -r -a list <<< "$1"     # global IFS has no space
  for svc in "${list[@]}"; do _ewe_enable "${svc}"; done
}

# --------------------------- First-boot one-shots ----------------------------
# Install a one-shot script as an enabled dinit scripted service (runs once at
# boot; the script self-guards re-runs). Used by board overlays + resize.
distro_install_oneshot() {
  local name="$1" file="$2"
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/usr/local/sbin" "${MOUNTPOINT_ROOT}/etc/dinit.d"
  run_sudo cp "${file}" "${MOUNTPOINT_ROOT}/usr/local/sbin/${name}"
  run_sudo chmod +x "${MOUNTPOINT_ROOT}/usr/local/sbin/${name}"
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/dinit.d/${name}" >/dev/null <<EOF
type = scripted
command = /usr/local/sbin/${name}
depends-on: rc.target
EOF
  _ewe_enable "${name}"
}

# Adapt OpenRC /etc/local.d/*.start boot scripts (overlaid by a board's files/,
# e.g. the M28K LED triggers) into enabled dinit scripted services.
distro_adapt_local_d() {
  local d="${MOUNTPOINT_ROOT}/etc/local.d" f base name
  [[ -d "${d}" ]] || return 0
  shopt -s nullglob
  for f in "${d}"/*.start; do
    base="$(basename "${f}")"
    name="localcompat-${base%.start}"
    run_sudo tee "${MOUNTPOINT_ROOT}/etc/dinit.d/${name}" >/dev/null <<EOF
type = scripted
command = /etc/local.d/${base}
depends-on: rc.target
EOF
    _ewe_enable "${name}"
    log "local.d → dinit oneshot: ${name} (${base})"
  done
  shopt -u nullglob
}

distro_install_resize_service() {
  [[ "${AUTO_RESIZE}" == "1" ]] || { log "AUTO_RESIZE=0; skipping first-boot rootfs expansion."; return 0; }
  section "Installing first-boot rootfs grow (dinit oneshot; sfdisk + resize2fs, no network)"
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/usr/local/sbin" "${MOUNTPOINT_ROOT}/etc/dinit.d"
  run_sudo tee "${MOUNTPOINT_ROOT}/usr/local/sbin/grow-rootfs" >/dev/null <<'GROW'
#!/bin/sh
# Grow the root partition to fill the disk + online-resize ext4, then self-disable.
# sfdisk (util-linux, in base) + resize2fs (e2fsprogs, installed at build). No net.
set -u
flag=/var/lib/misc/.rootfs-grown
[ -f "$flag" ] && exit 0
mkdir -p /var/lib/misc
mm=$(awk '$5=="/"{print $3; exit}' /proc/self/mountinfo 2>/dev/null)
[ -n "$mm" ] || exit 0
sys=/sys/dev/block/$mm
[ -f "$sys/partition" ] || exit 0
partno=$(cat "$sys/partition")
part=/dev/$(sed -n 's/^DEVNAME=//p' "$sys/uevent")
disk=/dev/$(basename "$(dirname "$(readlink -f "$sys")")")
[ -b "$part" ] && [ -b "$disk" ] && [ -n "$partno" ] || exit 0
echo ', +' | sfdisk -N "$partno" --no-reread --force "$disk" >/dev/null 2>&1 || true
partx -u "$disk" >/dev/null 2>&1 || partprobe "$disk" >/dev/null 2>&1 || true
resize2fs "$part" >/dev/null 2>&1 || true
: > "$flag"
logger -t grow-rootfs "rootfs ($part) grown to fill $disk" 2>/dev/null || true
exit 0
GROW
  run_sudo chmod +x "${MOUNTPOINT_ROOT}/usr/local/sbin/grow-rootfs"
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/dinit.d/firstboot-grow" >/dev/null <<'EOF'
type = scripted
command = /usr/local/sbin/grow-rootfs
depends-on: rc.target
EOF
  _ewe_enable firstboot-grow
  log "First-boot auto-expand enabled (dinit firstboot-grow)."
}

distro_finalize() {
  # FULL_FIRMWARE=1: install the whole linux-firmware pool (single eweOS package).
  [[ "${FULL_FIRMWARE}" == "1" ]] || return 0
  section "Installing full linux-firmware (FULL_FIRMWARE=1)"
  distro_install_pkgs "linux-firmware" \
    || warn "linux-firmware install failed (network?); 'pacman -S linux-firmware' after boot."
}
