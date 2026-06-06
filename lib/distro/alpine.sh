#!/usr/bin/env bash
# lib/distro/alpine.sh — Alpine Linux distro plugin (apk + OpenRC + ifupdown).
#
# Implements the distro_* contract the engine calls from lib/rootfs.sh /
# lib/pipeline.sh, exactly mirroring the lib/vendor/* pattern. The kernel, boot
# chain, image layout and board hooks are all distro-agnostic and reused as-is;
# this file owns only the userspace = package manager + init system + network.
#
# Contract (every distro plugin defines these):
#   distro_env_summary / distro_default_fragments
#   distro_prepare                      host-side payload + tooling
#   distro_bootstrap_rootfs             base rootfs into MOUNTPOINT_ROOT
#   distro_install_pkgs "p1 p2"         online, best-effort (nonzero on failure)
#   distro_write_repos / distro_set_timezone
#   distro_configure_network / distro_add_wifi_iface
#   distro_configure_console / distro_enable_base_services / distro_enable_services "..."
#   distro_install_oneshot NAME FILE    first-boot one-shot
#   distro_install_resize_service
#
# shellcheck disable=SC2034  # some vars are consumed by other sourced modules.

# Alpine aarch64 sys-mode rootfs: official uboot release tarball provides an
# offline apks/ repo; rootfs installed with apk.static, extras online.
ALPINE_RELEASE_BASE="${ALPINE_RELEASE_BASE:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64}"
ALPINE_UBOOT_URL="${ALPINE_UBOOT_URL:-latest}"
ALPINE_REPOSITORY_MAIN="${ALPINE_REPOSITORY_MAIN:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/main}"
ALPINE_REPOSITORY_COMMUNITY="${ALPINE_REPOSITORY_COMMUNITY:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/community}"
ALPINE_ROOTFS_PACKAGES="${ALPINE_ROOTFS_PACKAGES:-alpine-base ifupdown-ng dhcpcd dhcpcd-openrc e2fsprogs openssh openssh-server-common-openrc chrony chrony-openrc}"
APK_TOOLS_STATIC_REPO="${APK_TOOLS_STATIC_REPO:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64}"

# Userspace package names (Alpine flavour). Engine-generic vars resolved here.
GPU_USERSPACE_PACKAGES="${GPU_USERSPACE_PACKAGES:-mesa-dri-gallium mesa-egl mesa-gles mesa-gbm}"
WIFI_USERSPACE_PACKAGES="${WIFI_USERSPACE_PACKAGES:-wpa_supplicant wireless-tools iw bluez bluez-openrc}"

# Shown in the extlinux boot menu (MENU TITLE / LABEL).
DISTRO_PRETTY="${DISTRO_PRETTY:-Alpine Linux}"
# Alpine's apk.static rootfs is tiny; 1G is plenty (first-boot resize grows it).
# The full linux-firmware pool (FULL_FIRMWARE=1) is hundreds of MB, so size up.
if [[ "${FULL_FIRMWARE}" == "1" ]]; then
  DISTRO_IMAGE_SIZE="${DISTRO_IMAGE_SIZE:-3G}"
else
  DISTRO_IMAGE_SIZE="${DISTRO_IMAGE_SIZE:-1G}"
fi

distro_env_summary() { log "Distro: Alpine (apk + OpenRC), repos ${ALPINE_REPOSITORY_MAIN%/main}"; }
distro_default_fragments() { :; }   # Alpine/OpenRC needs no extra kernel options
distro_finalize() {
  # FULL_FIRMWARE=1: install the complete linux-firmware pool (Alpine ships none by
  # default). Best-effort — needs network; the image is still bootable without it.
  [[ "${FULL_FIRMWARE}" == "1" ]] || return 0
  section "Installing full linux-firmware (FULL_FIRMWARE=1)"
  distro_install_pkgs "linux-firmware" || warn "linux-firmware install failed (no network?); 'apk add linux-firmware' after boot."
}

# ------------------------------ Host payload ---------------------------------
_alpine_resolve_url() {
  section "Resolving Alpine uboot release tarball"
  if [[ "${ALPINE_UBOOT_URL}" != "latest" ]]; then
    RESOLVED_ALPINE_URL="${ALPINE_UBOOT_URL}"
    log "Using requested Alpine uboot tarball: ${RESOLVED_ALPINE_URL}"; return 0
  fi
  local html file index_file
  index_file="${DOWNLOAD_DIR}/alpine-aarch64-index.html"
  aria2_download "${ALPINE_RELEASE_BASE}/" "${index_file}.tmp"
  mv "${index_file}.tmp" "${index_file}"
  html="$(cat "${index_file}")"
  file="$(HTML="${html}" python3 - <<'PYEOF'
import os, re
files = re.findall(r'href="(alpine-uboot-[^"]+-aarch64\.tar\.gz)"', os.environ.get("HTML", ""))
if files:
    def key(name):
        m = re.search(r'alpine-uboot-(\d+)\.(\d+)\.(\d+)-', name)
        return tuple(map(int, m.groups())) if m else (0,0,0)
    print(sorted(set(files), key=key)[-1])
PYEOF
)"
  [[ -n "${file}" ]] || fatal "Could not resolve latest Alpine uboot tarball from ${ALPINE_RELEASE_BASE}."
  RESOLVED_ALPINE_URL="${ALPINE_RELEASE_BASE}/${file}"
  log "Latest Alpine aarch64 uboot tarball: ${RESOLVED_ALPINE_URL}"
}

_alpine_download_uboot() {
  section "Downloading Alpine uboot tarball"
  local file extract_dir
  file="${DOWNLOAD_DIR}/$(basename "${RESOLVED_ALPINE_URL}")"
  extract_dir="${BUILD_DIR}/alpine-uboot"
  if [[ ! -s "${file}" ]]; then
    aria2_download "${RESOLVED_ALPINE_URL}" "${file}.tmp"; mv "${file}.tmp" "${file}"
  else
    log "Alpine uboot tarball already exists: ${file}"
  fi
  rm -rf "${extract_dir}"; mkdir -p "${extract_dir}"
  run tar -C "${extract_dir}" -xzf "${file}"
  ALPINE_REPO_DIR="${extract_dir}/apks"
  [[ -f "${ALPINE_REPO_DIR}/aarch64/APKINDEX.tar.gz" ]] || fatal "Alpine local APK repository missing: ${ALPINE_REPO_DIR}/aarch64/APKINDEX.tar.gz"
  log "Alpine local APK repository: ${ALPINE_REPO_DIR}"
}

_alpine_install_apk_static() {
  section "Installing host apk.static"
  local apk_file version work="${BUILD_DIR}/apk-static"
  rm -rf "${work}"; mkdir -p "${work}"
  aria2_download "${APK_TOOLS_STATIC_REPO}/APKINDEX.tar.gz" "${work}/APKINDEX.tar.gz"
  run tar -C "${work}" -xzf "${work}/APKINDEX.tar.gz" APKINDEX
  version="$(awk 'BEGIN{RS=""} /\nP:apk-tools-static\n/ {for(i=1;i<=NF;i++) if($i ~ /^V:/) v=substr($i,3); if(v) print v; exit}' "${work}/APKINDEX")"
  [[ -n "${version}" ]] || fatal "Could not resolve apk-tools-static version from ${APK_TOOLS_STATIC_REPO}."
  apk_file="apk-tools-static-${version}.apk"
  aria2_download "${APK_TOOLS_STATIC_REPO}/${apk_file}" "${work}/${apk_file}"
  run tar -C "${work}" -xf "${work}/${apk_file}" || true
  APK_STATIC="${work}/sbin/apk.static"
  [[ -x "${APK_STATIC}" ]] || fatal "apk.static not found after extracting ${apk_file}"
  log "apk.static: ${APK_STATIC}"
}

distro_prepare() {
  _alpine_resolve_url
  _alpine_download_uboot
  _alpine_install_apk_static
}

# ------------------------------ Rootfs build ---------------------------------
distro_bootstrap_rootfs() {
  section "Installing Alpine sys-mode rootfs with apk.static"
  [[ -n "${ALPINE_REPO_DIR}" && -d "${ALPINE_REPO_DIR}" ]] || fatal "ALPINE_REPO_DIR is not ready."
  [[ -x "${APK_STATIC}" ]] || fatal "apk.static is not ready."
  [[ -x /usr/bin/qemu-aarch64-static ]] || fatal "qemu-aarch64-static missing; install qemu-user-static-binfmt."
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/usr/bin"
  run_sudo cp /usr/bin/qemu-aarch64-static "${MOUNTPOINT_ROOT}/usr/bin/qemu-aarch64-static"
  run_sudo "${APK_STATIC}" --root "${MOUNTPOINT_ROOT}" --arch aarch64 --initdb --no-network \
    --repository "${ALPINE_REPO_DIR}" --allow-untrusted add alpine-keys
  local rootfs_packages
  IFS=' ' read -r -a rootfs_packages <<< "${ALPINE_ROOTFS_PACKAGES}"
  ((${#rootfs_packages[@]} > 0)) || fatal "ALPINE_ROOTFS_PACKAGES is empty."
  run_sudo "${APK_STATIC}" --root "${MOUNTPOINT_ROOT}" --arch aarch64 --no-network \
    --repository "${ALPINE_REPO_DIR}" add "${rootfs_packages[@]}"
}

# Online package install (best-effort). Returns nonzero on failure; callers warn.
distro_install_pkgs() {
  local pkgs; IFS=' ' read -r -a pkgs <<< "$1"
  ((${#pkgs[@]} > 0)) || return 0
  run_sudo "${APK_STATIC}" --root "${MOUNTPOINT_ROOT}" --arch aarch64 \
    --repository "${ALPINE_REPOSITORY_MAIN}" --repository "${ALPINE_REPOSITORY_COMMUNITY}" \
    --update-cache add "${pkgs[@]}"
}

distro_write_repos() {
  run_sudo tee "${MOUNTPOINT_ROOT}/etc/apk/repositories" >/dev/null <<EOF
${ALPINE_REPOSITORY_MAIN}
${ALPINE_REPOSITORY_COMMUNITY}
EOF
}

distro_configure_time() {
  section "Configuring time sync (chrony) and timezone"
  # No RTC on these boards → chrony with unlimited makestep. chronyd is enabled in
  # distro_enable_base_services.
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/chrony" "${MOUNTPOINT_ROOT}/var/lib/chrony"
  local servers=() conf="" s
  IFS=' ' read -r -a servers <<< "${NTP_SERVERS}"
  ((${#servers[@]} > 0)) || servers=(ntp.aliyun.com)
  for s in "${servers[@]}"; do conf+="server ${s} iburst"$'\n'; done
  conf+="initstepslew 10 ${servers[0]}"$'\n'
  conf+="driftfile /var/lib/chrony/chrony.drift"$'\n'
  conf+="rtcsync"$'\n'"makestep 1.0 -1"$'\n'"cmdport 0"$'\n'
  printf '%s' "${conf}" | run_sudo tee "${MOUNTPOINT_ROOT}/etc/chrony/chrony.conf" >/dev/null
  log "chrony.conf written (servers: ${NTP_SERVERS})"
  distro_set_timezone
}

distro_set_timezone() {
  [[ -n "${TIMEZONE}" ]] || return 0
  if distro_install_pkgs tzdata; then
    if [[ -f "${MOUNTPOINT_ROOT}/usr/share/zoneinfo/${TIMEZONE}" ]]; then
      run_sudo cp "${MOUNTPOINT_ROOT}/usr/share/zoneinfo/${TIMEZONE}" "${MOUNTPOINT_ROOT}/etc/localtime"
      printf '%s\n' "${TIMEZONE}" | run_sudo tee "${MOUNTPOINT_ROOT}/etc/timezone" >/dev/null
      run_sudo "${APK_STATIC}" --root "${MOUNTPOINT_ROOT}" --arch aarch64 del tzdata || true
      log "Timezone set to ${TIMEZONE}."
    else
      warn "Zoneinfo for ${TIMEZONE} not found; leaving UTC."
    fi
  else
    warn "Online tzdata install failed (no network?); timezone stays UTC."
  fi
}

# --------------------------- Network / console -------------------------------
distro_configure_network() {
  # Base lo + eth0 (ifupdown) from the fixed resource, then one DHCP stanza per
  # additional wired NIC (eth1..eth{N-1}) for BOARD_NICS>1 — all DHCP, no role
  # split. Covers dual-gig (BOARD_NICS=2) and H88K's three NICs alike.
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/network"
  run_sudo cp "${RESOURCES_DIR}/rootfs/etc/network/interfaces" "${MOUNTPOINT_ROOT}/etc/network/interfaces"
  local i
  for (( i = 1; i < BOARD_NICS; i++ )); do
    printf '\nauto eth%d\niface eth%d inet dhcp\n' "${i}" "${i}" \
      | run_sudo tee -a "${MOUNTPOINT_ROOT}/etc/network/interfaces" >/dev/null
  done
}

distro_add_wifi_iface() {
  # wlan0 DHCP stanza (no "auto" — Wi-Fi is template-only out of the box).
  if ! grep -q 'iface wlan0' "${MOUNTPOINT_ROOT}/etc/network/interfaces" 2>/dev/null; then
    run_sudo tee -a "${MOUNTPOINT_ROOT}/etc/network/interfaces" >/dev/null <<'EOF'

# Wi-Fi (AIC8800). Configure /etc/wpa_supplicant/wpa_supplicant.conf, then:
#   ifup wlan0   (or add "auto wlan0" here to bring it up at boot)
iface wlan0 inet dhcp
EOF
  fi
}

distro_configure_console() {
  section "Configuring Alpine inittab serial console"
  local inittab="${MOUNTPOINT_ROOT}/etc/inittab"
  if [[ ! -f "${inittab}" ]]; then
    warn "${inittab} missing; creating a minimal BusyBox/OpenRC inittab."
    run_sudo tee "${inittab}" >/dev/null <<EOF
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
${SERIAL_CONSOLE}::respawn:/sbin/getty -L ${SERIAL_CONSOLE} ${SERIAL_BAUD} vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF
    return 0
  fi
  run_sudo sed -i -E "/^${SERIAL_CONSOLE}:/d" "${inittab}"
  if [[ "${SERIAL_CONSOLE}" != "ttyFIQ0" ]]; then
    run_sudo sed -i -E '/^ttyFIQ0:/d' "${inittab}" || true
  fi
  printf '%s\n' "${SERIAL_CONSOLE}::respawn:/sbin/getty -L ${SERIAL_CONSOLE} ${SERIAL_BAUD} vt100" | run_sudo tee -a "${inittab}" >/dev/null
}

# ------------------------------ Services -------------------------------------
distro_enable_base_services() {
  section "Enabling basic OpenRC services"
  local default_dir="${MOUNTPOINT_ROOT}/etc/runlevels/default"
  local boot_dir="${MOUNTPOINT_ROOT}/etc/runlevels/boot"
  run_sudo mkdir -p "${default_dir}" "${boot_dir}"
  local svc
  for svc in devfs dmesg mdev hwdrivers modules sysctl hostname bootmisc syslog; do
    [[ -e "${MOUNTPOINT_ROOT}/etc/init.d/${svc}" ]] && run_sudo ln -sf "/etc/init.d/${svc}" "${boot_dir}/${svc}" || true
  done
  for svc in networking dhcpcd sshd chronyd local; do
    if [[ -e "${MOUNTPOINT_ROOT}/etc/init.d/${svc}" ]]; then
      run_sudo ln -sf "/etc/init.d/${svc}" "${default_dir}/${svc}" || true
    else
      warn "OpenRC service missing in generated rootfs: ${svc}"
    fi
  done
  # No battery-backed RTC: the default hwclock boot service fails; use swclock.
  run_sudo rm -f "${boot_dir}/hwclock"
  [[ -e "${MOUNTPOINT_ROOT}/etc/init.d/swclock" ]] && run_sudo ln -sf "/etc/init.d/swclock" "${boot_dir}/swclock" || true
}

distro_enable_services() {
  local default_dir="${MOUNTPOINT_ROOT}/etc/runlevels/default" svc list
  run_sudo mkdir -p "${default_dir}"
  IFS=' ' read -r -a list <<< "$1"     # global IFS has no space
  for svc in "${list[@]}"; do
    if [[ -e "${MOUNTPOINT_ROOT}/etc/init.d/${svc}" ]]; then
      run_sudo ln -sf "/etc/init.d/${svc}" "${default_dir}/${svc}" || true
      log "Enabled service: ${svc}"
    else
      warn "Service not present (will not autostart): ${svc}"
    fi
  done
}

# --------------------------- First-boot one-shots ----------------------------
# Install a one-shot script run on first boot. Alpine: drop into /etc/local.d/
# (the OpenRC 'local' service, enabled in the base set, runs *.start).
distro_install_oneshot() {
  local name="$1" file="$2"
  run_sudo mkdir -p "${MOUNTPOINT_ROOT}/etc/local.d"
  run_sudo cp "${file}" "${MOUNTPOINT_ROOT}/etc/local.d/${name}.start"
  run_sudo chmod +x "${MOUNTPOINT_ROOT}/etc/local.d/${name}.start"
}

# OpenRC's 'local' service already runs every /etc/local.d/*.start at boot, so a
# board's files/ overlay LED/etc scripts work as-is — nothing to adapt.
distro_adapt_local_d() { :; }

distro_install_resize_service() {
  [[ "${AUTO_RESIZE}" == "1" ]] || { log "AUTO_RESIZE=0; skipping first-boot rootfs expansion."; return 0; }
  section "Installing first-boot rootfs auto-expand service"
  # growpart (cloud-utils-growpart) + resize2fs (e2fsprogs-extra on Alpine, NOT base).
  if ! distro_install_pkgs "cloud-utils-growpart e2fsprogs-extra"; then
    warn "Online growpart/e2fsprogs-extra install failed (no network?). First-boot resize will no-op until you 'apk add cloud-utils-growpart e2fsprogs-extra'."
  fi
  distro_install_oneshot 10-resize-rootfs "${RESOURCES_DIR}/rootfs/etc/local.d/10-resize-rootfs.start"
  log "First-boot auto-expand installed (/etc/local.d/10-resize-rootfs.start)."
}
